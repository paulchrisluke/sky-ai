import Foundation

final class SyncCoordinator {
    private let stateQueue = DispatchQueue(label: "com.blawby.agent.sync.state")
    private var mailSyncRunning = false
    private var calendarSyncRunning = false

    private let config: Config
    private let localStore: LocalStore
    private let webSocketPublisher: WebSocketPublisher
    private let mailWatcher: MailWatcher
    private let mailProcessor: MailProcessor
    private let calendarWatcher: CalendarWatcher
    private let logger: Logger

    init(
        config: Config,
        localStore: LocalStore,
        webSocketPublisher: WebSocketPublisher,
        mailWatcher: MailWatcher,
        mailProcessor: MailProcessor,
        calendarWatcher: CalendarWatcher,
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

    func runMailSync() async {
        guard beginMailSync() else {
            logger.warning("[sync] mail skipped: previous run still in progress")
            return
        }
        defer { endMailSync() }

        let newMessages = mailWatcher.fetchNewMessages()
        if newMessages.isEmpty {
            logger.info("[sync] mail: processed=0 entities=0 sent=true")
            return
        }

        do {
            let entities = try await mailProcessor.process(messages: newMessages, workspaceId: config.workspaceId)
            if entities.isEmpty {
                logger.info("[sync] mail: processed=\(newMessages.count) entities=0 sent=true")
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

            do {
                try await webSocketPublisher.send(type: "entities", payload: json)
                for messageId in Set(entities.map({ $0.messageId })) {
                    localStore.markMessageSent(messageId)
                }
                logger.info("[sync] mail: processed=\(newMessages.count) entities=\(entities.count) sent=true")
            } catch {
                _ = localStore.enqueuePayload(type: "entities", json: json)
                logger.info("[sync] mail: processed=\(newMessages.count) entities=\(entities.count) sent=queued")
            }
        } catch {
            logger.error("[sync] mail failed: \(error.localizedDescription)")
        }
    }

    func runCalendarSync() async {
        guard beginCalendarSync() else {
            logger.warning("[sync] calendar skipped: previous run still in progress")
            return
        }
        defer { endCalendarSync() }

        do {
            let payloads = try await calendarWatcher.fetchUnsentPayloads()
            if payloads.isEmpty {
                logger.info("[sync] calendar: events=0 sent=true")
                return
            }

            var eventsCount = 0
            var queued = false
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
            }

            logger.info("[sync] calendar: events=\(eventsCount) sent=\(queued ? "queued" : "true")")
        } catch {
            logger.error("[sync] calendar failed: \(error.localizedDescription)")
        }
    }

    func drainOutboundQueue() async {
        let pending = localStore.dequeuePendingPayloads(limit: 10)
        if pending.isEmpty {
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
    }

    private func beginMailSync() -> Bool {
        stateQueue.sync {
            if mailSyncRunning {
                return false
            }
            mailSyncRunning = true
            return true
        }
    }

    private func endMailSync() {
        stateQueue.sync {
            mailSyncRunning = false
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
}

private struct EntitiesPayload: Codable {
    let type: String
    let workspaceId: String
    let accountId: String
    let entities: [ExtractedEntity]
}
