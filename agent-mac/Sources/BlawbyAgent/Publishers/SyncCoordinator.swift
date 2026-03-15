import Foundation

struct SyncStatusSnapshot {
    let mailSyncRunning: Bool
    let mailSyncQueued: Bool
    let mailMode: String?
    let calendarSyncRunning: Bool
    let bootstrapStatus: String
    let lastMailProcessed: Int
    let lastMailEntities: Int
    let lastMailDelivery: String
    let mailDiscoveredTotal: Int
    let mailProcessedTotal: Int
    let mailSentTotal: Int
    let mailQueuedTotal: Int
    let mailBootstrapWindowDone: Int
    let mailBootstrapWindowTotal: Int
    let lastCalendarEvents: Int
    let lastCalendarDelivery: String
    let calendarCalendarsProcessed: Int
    let calendarCalendarsTotal: Int
    let calendarEventsTotal: Int
    let pendingPayloads: Int
    let lastSyncAt: Date?
}

protocol WebSocketPublishing {
    func send(type: String, payload: String) async throws
}

protocol MailWatching {
    func fetchNewMessages() async -> [RawMessage]
    func fetchMessagesSince(_ since: Date, limit: Int) async -> [RawMessage]
    func fetchMessagesBetween(_ start: Date, _ end: Date, limit: Int) async -> [RawMessage]
}

protocol MailProcessing {
    func process(messages: [RawMessage], workspaceId: String) async throws -> MailProcessingResult
}

protocol CalendarWatching {
    func fetchUnsentPayloads(backfill: Bool) async throws -> [CalendarPayload]
    func markPayloadEventsSent(_ payload: CalendarPayload)
}

final class SyncCoordinator: @unchecked Sendable {
    private let bootstrapMailDays = 3650
    private let bootstrapMailChunkDays = 30
    private let bootstrapMailChunkLimit = 1500

    private let stateQueue = DispatchQueue(label: "com.blawby.agent.sync.state")
    private var mailSyncRunning = false
    private var pendingMailSync = false
    private var mailMode: String?
    private var calendarSyncRunning = false
    private var bootstrapStatus = "waiting"
    private var lastMailProcessed = 0
    private var lastMailEntities = 0
    private var lastMailDelivery = "n/a"
    private var mailDiscoveredTotal = 0
    private var mailProcessedTotal = 0
    private var mailSentTotal = 0
    private var mailQueuedTotal = 0
    private var mailBootstrapWindowDone = 0
    private var mailBootstrapWindowTotal = 0
    private var lastCalendarEvents = 0
    private var lastCalendarDelivery = "n/a"
    private var calendarCalendarsProcessed = 0
    private var calendarCalendarsTotal = 0
    private var calendarEventsTotal = 0
    private var lastSyncAt: Date?
    private var bootstrapInProgress = false
    private var onStatusChanged: (@Sendable (SyncStatusSnapshot) -> Void)?

    private let config: Config
    private let localStore: LocalStore
    private let webSocketPublisher: any WebSocketPublishing
    private let mailWatcher: any MailWatching
    private let mailProcessor: any MailProcessing
    private let calendarWatcher: any CalendarWatching
    private let logger: Logger

    init(
        config: Config,
        localStore: LocalStore,
        webSocketPublisher: any WebSocketPublishing,
        mailWatcher: any MailWatching,
        mailProcessor: any MailProcessing,
        calendarWatcher: any CalendarWatching,
        logger: Logger
    ) {
        self.config = config
        self.localStore = localStore
        self.webSocketPublisher = webSocketPublisher
        self.mailWatcher = mailWatcher
        self.mailProcessor = mailProcessor
        self.calendarWatcher = calendarWatcher
        self.logger = logger
    }

    func setOnStatusChanged(_ handler: (@Sendable (SyncStatusSnapshot) -> Void)?) {
        stateQueue.sync {
            onStatusChanged = handler
        }
        publishStatus()
    }

    func runMailSync() async {
        guard beginMailSync(mode: "sync") else {
            logger.info("[sync] mail coalesced: run already in progress")
            publishStatus()
            return
        }
        publishStatus()

        while true {
            let startedAt = Date()
            await runMailSyncPass()
            let duration = Int(Date().timeIntervalSince(startedAt))

            if completeMailSyncPass() {
                logger.info("[sync] mail coalesced: running queued pass after \(duration)s")
                continue
            }
            break
        }
        stateQueue.sync {
            lastSyncAt = Date()
        }
        publishStatus()
    }

    func runMailBackfill(days: Int, limit: Int = 1000) async {
        guard beginMailSync(mode: "backfill") else {
            logger.info("[sync] mail backfill coalesced: run already in progress")
            publishStatus()
            return
        }
        publishStatus()

        let seconds = max(1, days) * 24 * 60 * 60
        let cutoff = Date(timeIntervalSinceNow: -Double(seconds))
        let backfillMessages = await mailWatcher.fetchMessagesSince(cutoff, limit: max(1, limit))
        await processMailMessages(backfillMessages, mode: "backfill")

        while completeMailSyncPass() {
            await runMailSyncPass()
        }
        stateQueue.sync {
            lastSyncAt = Date()
        }
        publishStatus()
    }

    func runCalendarSync() async {
        await runCalendarSync(backfill: false)
    }

    func runCalendarBackfill() async {
        await runCalendarSync(backfill: true)
    }

    func runInitialBootstrapSyncIfNeeded() async {
        let needsCalendar = !localStore.isBootstrapCompleted(accountId: config.accountId, key: "calendar")
        let needsMail = !localStore.isBootstrapCompleted(accountId: config.accountId, key: "mail")
        if !needsCalendar && !needsMail {
            stateQueue.sync {
                bootstrapStatus = "completed"
                bootstrapInProgress = false
            }
            publishStatus()
            return
        }

        stateQueue.sync {
            bootstrapInProgress = true
            bootstrapStatus = "syncing"
        }
        publishStatus()

        await withTaskGroup(of: Void.self) { group in
            if needsCalendar {
                group.addTask { [self] in
                    logger.info("[sync] bootstrap calendar backfill starting")
                    await runCalendarBackfill()
                    localStore.markBootstrapCompleted(accountId: config.accountId, key: "calendar")
                    logger.info("[sync] bootstrap calendar backfill completed")
                }
            }
            if needsMail {
                group.addTask { [self] in
                    await runBootstrapMailBackfill()
                }
            }
            await group.waitForAll()
        }

        stateQueue.sync {
            bootstrapInProgress = false
            bootstrapStatus = "completed"
        }
        publishStatus()
    }

    private func runBootstrapMailBackfill() async {
        let now = Date()
        guard let horizon = Calendar.current.date(byAdding: .day, value: -bootstrapMailDays, to: now) else {
            logger.error("[sync] bootstrap mail backfill failed: invalid horizon date")
            return
        }

        var cursorEnd = localStore.bootstrapCursorDate(accountId: config.accountId, key: "mail") ?? now
        stateQueue.sync {
            let remainingDays = max(1, Int(ceil(cursorEnd.timeIntervalSince(horizon) / 86_400)))
            mailBootstrapWindowTotal = max(1, Int(ceil(Double(remainingDays) / Double(bootstrapMailChunkDays))))
            mailBootstrapWindowDone = 0
        }
        stateQueue.sync {
            bootstrapStatus = "mail backfill active 0%"
        }
        publishStatus()
        logger.info("[sync] bootstrap mail backfill starting horizon=\(horizon) cursorEnd=\(cursorEnd)")

        while cursorEnd > horizon {
            if Task.isCancelled {
                logger.info("[sync] bootstrap mail backfill cancelled")
                return
            }
            guard let chunkStart = Calendar.current.date(byAdding: .day, value: -bootstrapMailChunkDays, to: cursorEnd) else {
                logger.error("[sync] bootstrap mail backfill failed: invalid chunk date")
                return
            }
            let windowStart = max(horizon, chunkStart)
            let windowEnd = cursorEnd
            let total = now.timeIntervalSince(horizon)
            let complete = now.timeIntervalSince(windowEnd)
            let pct = total > 0 ? Int(max(0, min(100, (complete / total) * 100))) : 0
            stateQueue.sync {
                bootstrapStatus = "mail backfill active \(pct)%"
            }
            publishStatus()
            logger.info("[sync] bootstrap mail window start=\(windowStart) end=\(windowEnd)")

            // Drain each 30-day window in paged slices before advancing the global cursor.
            var windowCursorEnd = windowEnd
            while windowCursorEnd > windowStart {
                if Task.isCancelled {
                    logger.info("[sync] bootstrap mail backfill cancelled")
                    return
                }
                guard beginMailSync(mode: "backfill") else {
                    logger.info("[sync] bootstrap mail backfill paused: mail sync already active")
                    publishStatus()
                    return
                }
                publishStatus()

                let currentWindowCursorEnd = windowCursorEnd
                let windowMessages = await mailWatcher.fetchMessagesBetween(windowStart, currentWindowCursorEnd, limit: bootstrapMailChunkLimit)
                await processMailMessages(windowMessages, mode: "backfill")

                while completeMailSyncPass() {
                    await runMailSyncPass()
                }
                stateQueue.sync {
                    lastSyncAt = Date()
                }
                publishStatus()

                if windowMessages.isEmpty {
                    break
                }

                if windowMessages.count < bootstrapMailChunkLimit {
                    break
                }

                guard let oldestMessageDate = windowMessages.map(\.date).min() else {
                    break
                }
                let nextCursorEnd = oldestMessageDate.addingTimeInterval(-1)
                if nextCursorEnd >= windowCursorEnd {
                    logger.error("[sync] bootstrap mail backfill failed: non-advancing window cursor")
                    return
                }
                windowCursorEnd = max(windowStart, nextCursorEnd)
                logger.info("[sync] bootstrap mail window saturated; continuing start=\(windowStart) end=\(windowCursorEnd)")
            }

            localStore.setBootstrapCursorDate(accountId: config.accountId, key: "mail", date: windowStart)
            cursorEnd = windowStart
            stateQueue.sync {
                mailBootstrapWindowDone = min(mailBootstrapWindowTotal, mailBootstrapWindowDone + 1)
            }
        }

        localStore.markBootstrapCompleted(accountId: config.accountId, key: "mail")
        localStore.clearBootstrapCursor(accountId: config.accountId, key: "mail")
        stateQueue.sync {
            bootstrapStatus = "mail backfill completed"
            mailBootstrapWindowDone = mailBootstrapWindowTotal
        }
        publishStatus()
        logger.info("[sync] bootstrap mail backfill completed")
    }

    private func runCalendarSync(backfill: Bool) async {
        guard beginCalendarSync() else {
            logger.warning("[sync] calendar skipped: previous run still in progress")
            publishStatus()
            return
        }
        publishStatus()
        defer {
            endCalendarSync()
            stateQueue.sync {
                lastSyncAt = Date()
            }
            publishStatus()
        }

        do {
            let payloads = try await calendarWatcher.fetchUnsentPayloads(backfill: backfill)
            if payloads.isEmpty {
                logger.info("[sync] calendar \(backfill ? "backfill" : "sync"): events=0 sent=true")
                stateQueue.sync {
                    lastCalendarEvents = 0
                    lastCalendarDelivery = "sent"
                    calendarCalendarsProcessed = 0
                    calendarCalendarsTotal = 0
                }
                publishStatus()
                return
            }

            var eventsCount = 0
            var queued = false
            var processedCalendars = 0
            stateQueue.sync {
                calendarCalendarsTotal = payloads.count
                calendarCalendarsProcessed = 0
            }
            publishStatus()
            for payload in payloads {
                eventsCount += payload.events.count
                let payloadData = try JSONEncoder().encode(payload)
                guard let json = String(data: payloadData, encoding: .utf8) else {
                    throw NSError(domain: "SyncCoordinator", code: 2, userInfo: [NSLocalizedDescriptionKey: "calendar payload encode failed"])
                }

                do {
                    try await webSocketPublisher.send(type: "calendar", payload: json)
                    calendarWatcher.markPayloadEventsSent(payload)
                } catch {
                    _ = localStore.enqueuePayload(type: "calendar", json: json)
                    queued = true
                }
                processedCalendars += 1
                stateQueue.sync {
                    calendarCalendarsProcessed = processedCalendars
                }
                publishStatus()
            }

            stateQueue.sync {
                lastCalendarEvents = eventsCount
                lastCalendarDelivery = queued ? "queued" : "sent"
                calendarEventsTotal += eventsCount
            }
            publishStatus()
            logger.info("[sync] calendar \(backfill ? "backfill" : "sync"): events=\(eventsCount) sent=\(queued ? "queued" : "true")")
        } catch {
            stateQueue.sync {
                lastCalendarEvents = 0
                lastCalendarDelivery = "failed"
            }
            publishStatus()
            logger.error("[sync] calendar \(backfill ? "backfill" : "sync") failed: \(error.localizedDescription)")
        }
    }

    func drainOutboundQueue() async {
        let pending = localStore.dequeuePendingPayloads(limit: 10)
        if pending.isEmpty {
            publishStatus()
            return
        }

        for item in pending {
            do {
                try await webSocketPublisher.send(type: item.type, payload: item.json)
                localStore.markPayloadSent(item.id)
            } catch {
                localStore.incrementPayloadAttempts(item.id)
                let attempts = localStore.payloadAttempts(item.id)
                if attempts > 5 {
                    localStore.markPayloadSent(item.id)
                }
            }
        }
        publishStatus()
    }

    func publishRawPayload(type: String, json: String) async {
        let deferMessages = stateQueue.sync { bootstrapInProgress }
        if deferMessages && type == "message" {
            _ = localStore.enqueuePayload(type: type, json: json)
            publishStatus()
            return
        }

        do {
            try await webSocketPublisher.send(type: type, payload: json)
        } catch {
            _ = localStore.enqueuePayload(type: type, json: json)
        }
        publishStatus()
    }

    private func beginMailSync(mode: String) -> Bool {
        stateQueue.sync {
            if mailSyncRunning {
                pendingMailSync = true
                return false
            }
            mailSyncRunning = true
            mailMode = mode
            return true
        }
    }

    private func completeMailSyncPass() -> Bool {
        stateQueue.sync {
            if pendingMailSync {
                pendingMailSync = false
                mailMode = "sync"
                return true
            }
            mailSyncRunning = false
            mailMode = nil
            return false
        }
    }

    private func beginCalendarSync() -> Bool {
        stateQueue.sync {
            if calendarSyncRunning {
                return false
            }
            calendarSyncRunning = true
            return true
        }
    }

    private func endCalendarSync() {
        stateQueue.sync {
            calendarSyncRunning = false
        }
    }

    private func runMailSyncPass() async {
        let newMessages = await mailWatcher.fetchNewMessages()
        await processMailMessages(newMessages, mode: "sync")
    }

    private func processMailMessages(_ newMessages: [RawMessage], mode: String) async {
        if newMessages.isEmpty {
            stateQueue.sync {
                lastMailProcessed = 0
                lastMailEntities = 0
                lastMailDelivery = "sent"
            }
            publishStatus()
            logger.info("[sync] mail \(mode): processed=0 entities=0 sent=true")
            return
        }

        stateQueue.sync {
            mailDiscoveredTotal += newMessages.count
        }

        do {
            let processed = try await mailProcessor.process(messages: newMessages, workspaceId: config.workspaceId)
            let entities = processed.entities
            let rawMessages = processed.rawMessages
            if entities.isEmpty {
                stateQueue.sync {
                    lastMailProcessed = newMessages.count
                    lastMailEntities = 0
                    lastMailDelivery = "sent"
                    mailProcessedTotal += newMessages.count
                    mailSentTotal += newMessages.count
                }
                publishStatus()
                logger.info("[sync] mail \(mode): processed=\(newMessages.count) entities=0 sent=true")
                return
            }

            let payloadWithScope = EntitiesPayload(
                type: "entities",
                workspaceId: config.workspaceId,
                accountId: config.accountId,
                entities: entities
            )
            let payloadData = try JSONEncoder().encode(payloadWithScope)
            guard let json = String(data: payloadData, encoding: .utf8) else {
                throw NSError(domain: "SyncCoordinator", code: 1, userInfo: [NSLocalizedDescriptionKey: "entities payload encode failed"])
            }

            let chunksPayload = ChunksPayload(
                type: "chunks",
                workspaceId: config.workspaceId,
                accountId: config.accountId,
                messages: rawMessages.map {
                    ChunksPayload.Message(
                        messageId: $0.messageId,
                        subject: $0.subject,
                        bodyText: $0.bodyText,
                        fromEmail: $0.from,
                        toEmails: $0.to,
                        mailbox: $0.mailbox,
                        sentAt: iso8601WithFractionalSeconds($0.date)
                    )
                }
            )
            let chunksData = try JSONEncoder().encode(chunksPayload)
            guard let chunksJson = String(data: chunksData, encoding: .utf8) else {
                throw NSError(domain: "SyncCoordinator", code: 3, userInfo: [NSLocalizedDescriptionKey: "chunks payload encode failed"])
            }

            do {
                try await webSocketPublisher.send(type: "entities", payload: json)
                try await webSocketPublisher.send(type: "chunks", payload: chunksJson)

                for messageId in Set(entities.map({ $0.messageId })) {
                    localStore.markMessageSent(messageId)
                }
                let sentMessageCount = Set(entities.map({ $0.messageId })).count
                stateQueue.sync {
                    lastMailProcessed = newMessages.count
                    lastMailEntities = entities.count
                    lastMailDelivery = "sent"
                    mailProcessedTotal += newMessages.count
                    mailSentTotal += sentMessageCount
                }
                publishStatus()
                logger.info("[sync] mail \(mode): processed=\(newMessages.count) entities=\(entities.count) sent=true")
            } catch {
                _ = localStore.enqueuePayload(type: "entities", json: json)
                _ = localStore.enqueuePayload(type: "chunks", json: chunksJson)
                let queuedMessageCount = Set(entities.map({ $0.messageId })).count
                stateQueue.sync {
                    lastMailProcessed = newMessages.count
                    lastMailEntities = entities.count
                    lastMailDelivery = "queued"
                    mailProcessedTotal += newMessages.count
                    mailQueuedTotal += queuedMessageCount
                }
                publishStatus()
                logger.info("[sync] mail \(mode): processed=\(newMessages.count) entities=\(entities.count) sent=queued")
            }
        } catch {
            stateQueue.sync {
                lastMailProcessed = newMessages.count
                lastMailEntities = 0
                lastMailDelivery = "failed"
            }
            publishStatus()
            logger.error("[sync] mail \(mode) failed: \(error.localizedDescription)")
        }
    }

    private func iso8601WithFractionalSeconds(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private func publishStatus() {
        let payload = stateQueue.sync {
            (
                onStatusChanged,
                SyncStatusSnapshot(
                mailSyncRunning: mailSyncRunning,
                mailSyncQueued: pendingMailSync,
                mailMode: mailMode,
                calendarSyncRunning: calendarSyncRunning,
                bootstrapStatus: bootstrapStatus,
                lastMailProcessed: lastMailProcessed,
                lastMailEntities: lastMailEntities,
                lastMailDelivery: lastMailDelivery,
                mailDiscoveredTotal: mailDiscoveredTotal,
                mailProcessedTotal: mailProcessedTotal,
                mailSentTotal: mailSentTotal,
                mailQueuedTotal: mailQueuedTotal,
                mailBootstrapWindowDone: mailBootstrapWindowDone,
                mailBootstrapWindowTotal: mailBootstrapWindowTotal,
                lastCalendarEvents: lastCalendarEvents,
                lastCalendarDelivery: lastCalendarDelivery,
                calendarCalendarsProcessed: calendarCalendarsProcessed,
                calendarCalendarsTotal: calendarCalendarsTotal,
                calendarEventsTotal: calendarEventsTotal,
                pendingPayloads: localStore.pendingPayloadCount(),
                lastSyncAt: lastSyncAt
                )
            )
        }
        payload.0?(payload.1)
    }
}

extension WebSocketPublisher: WebSocketPublishing {}
extension MailWatcher: MailWatching {}
extension MailProcessor: MailProcessing {}
extension CalendarWatcher: CalendarWatching {}

private struct EntitiesPayload: Codable {
    let type: String
    let workspaceId: String
    let accountId: String
    let entities: [ExtractedEntity]
}

private struct ChunksPayload: Codable {
    struct Message: Codable {
        let messageId: String
        let subject: String
        let bodyText: String
        let fromEmail: String
        let toEmails: [String]
        let mailbox: String
        let sentAt: String
    }

    let type: String
    let workspaceId: String
    let accountId: String
    let messages: [Message]
}
