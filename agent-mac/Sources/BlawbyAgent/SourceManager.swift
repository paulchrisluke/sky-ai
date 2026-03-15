import Foundation
import Combine

@preconcurrency protocol SourceManaging: AnyObject {
    func start()
    func stop()
    func refreshSources() async
    func enabledSourceIds(sourceType: String) -> [String]
    func setEnabled(_ id: String, enabled: Bool) async
    func markSourceChanged(_ id: String)
    func markSourcesChanged(sourceType: String)
    func syncSource(_ id: String) async
}

final class SourceManager: ObservableObject, SourceManaging, @unchecked Sendable {
    @Published private(set) var sources: [ConnectedSource] = []

    private let config: Config
    private let localStore: LocalStore
    private let mailWatcher: MailWatcher
    private let calendarWatcher: CalendarWatcher
    private let mailProcessor: any MailProcessing
    private let webSocketPublisher: any WebSocketPublishing
    private let logger: Logger

    private var loopTask: Task<Void, Never>?
    private var running = false
    private var dirtySourceIds: Set<String> = []

    private let perSourceBatchSize = 50
    private let interSourceDelayNanoseconds: UInt64 = 500_000_000

    init(
        config: Config,
        localStore: LocalStore,
        mailWatcher: MailWatcher,
        calendarWatcher: CalendarWatcher,
        mailProcessor: any MailProcessing,
        webSocketPublisher: any WebSocketPublishing,
        logger: Logger
    ) {
        self.config = config
        self.localStore = localStore
        self.mailWatcher = mailWatcher
        self.calendarWatcher = calendarWatcher
        self.mailProcessor = mailProcessor
        self.webSocketPublisher = webSocketPublisher
        self.logger = logger
        self.sources = localStore.connectedSources()
    }

    func start() {
        guard loopTask == nil else {
            return
        }
        running = true
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.bootstrapAndRunLoop()
        }
    }

    func stop() {
        running = false
        loopTask?.cancel()
        loopTask = nil
    }

    @MainActor
    func refreshSources() async {
        sources = localStore.connectedSources()
    }

    func enabledSourceIds(sourceType: String) -> [String] {
        localStore.connectedSources()
            .filter { $0.enabled && $0.sourceType == sourceType }
            .map(\.id)
            .sorted()
    }

    func discoverSources() async {
        await discoverMailSources()
        await discoverCalendarSources()
        discoverMessagesSource()
        await refreshSources()
    }

    func setEnabled(_ id: String, enabled: Bool) async {
        localStore.setConnectedSourceEnabled(id: id, enabled: enabled)
        await refreshSources()
    }

    func markSourceChanged(_ id: String) {
        dirtySourceIds.insert(id)
    }

    func markSourcesChanged(sourceType: String) {
        let ids = enabledSourceIds(sourceType: sourceType)
        for id in ids {
            dirtySourceIds.insert(id)
        }
    }

    func syncSource(_ id: String) async {
        guard let source = localStore.connectedSource(id: id) else {
            return
        }
        if !source.enabled {
            return
        }

        do {
            switch source.sourceType {
            case "mail":
                try await syncMailSource(source)
            case "calendar":
                try await syncCalendarSource(source)
            case "messages":
                localStore.updateConnectedSourceSync(
                    id: source.id,
                    syncCursor: source.syncCursor,
                    totalEstimated: source.totalEstimated,
                    totalSynced: source.totalSynced,
                    status: "current",
                    lastError: nil
                )
            default:
                throw NSError(domain: "SourceManager", code: 1, userInfo: [NSLocalizedDescriptionKey: "unsupported source type: \(source.sourceType)"])
            }
        } catch {
            localStore.updateConnectedSourceSync(
                id: source.id,
                syncCursor: source.syncCursor,
                totalEstimated: source.totalEstimated,
                totalSynced: source.totalSynced,
                status: "error",
                lastError: error.localizedDescription
            )
            logger.error("source sync failed id=\(source.id): \(error.localizedDescription)")
        }

        await refreshSources()
    }

    private func bootstrapAndRunLoop() async {
        await discoverSources()

        while running && !Task.isCancelled {
            let nextIds = nextSourceIdsForCycle()
            for id in nextIds {
                if !running || Task.isCancelled {
                    break
                }
                await syncSource(id)
                try? await Task.sleep(nanoseconds: interSourceDelayNanoseconds)
            }
            if nextIds.isEmpty {
                try? await Task.sleep(nanoseconds: interSourceDelayNanoseconds)
            }
        }
    }

    private func nextSourceIdsForCycle() -> [String] {
        if !dirtySourceIds.isEmpty {
            let ids = Array(dirtySourceIds).sorted()
            dirtySourceIds.removeAll()
            return ids
        }
        return localStore.connectedSources()
            .filter { $0.enabled }
            .map { $0.id }
    }

    private func discoverMailSources() async {
        let discovered = await mailWatcher.discoverSources()
        for source in discovered {
            let existing = localStore.connectedSource(id: source.id)
            
            // Get message count to populate total_estimated
            let messageCount = await mailWatcher.messageCount(accountId: source.accountId, mailbox: source.mailbox)
            
            localStore.upsertConnectedSource(
                id: source.id,
                sourceType: "mail",
                accountId: source.accountId,
                sourceName: source.sourceName,
                enabled: existing?.enabled ?? true,
                syncCursor: existing?.syncCursor,
                totalEstimated: existing?.totalEstimated ?? messageCount,
                totalSynced: existing?.totalSynced ?? 0,
                status: existing?.status ?? "idle",
                lastError: existing?.lastError
            )
        }
    }

    private func discoverCalendarSources() async {
        do {
            let sources = try await calendarWatcher.discoverSources()
            for source in sources {
                let id = "calendar:\(source.id)"
                let existing = localStore.connectedSource(id: id)
                
                // Get event count for the past year to populate total_estimated
                let oneYearAgo = Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? Date()
                let events = try await calendarWatcher.fetchEvents(calendarId: source.id, since: oneYearAgo, until: Date())
                
                localStore.upsertConnectedSource(
                    id: id,
                    sourceType: "calendar",
                    accountId: config.accountId,
                    sourceName: source.sourceName,
                    enabled: existing?.enabled ?? true,
                    syncCursor: existing?.syncCursor,
                    totalEstimated: existing?.totalEstimated ?? events.count,
                    totalSynced: existing?.totalSynced ?? 0,
                    status: existing?.status ?? "idle",
                    lastError: existing?.lastError
                )
            }
        } catch {
            logger.error("calendar source discovery failed: \(error.localizedDescription)")
        }
    }

    private func discoverMessagesSource() {
        let path = NSHomeDirectory() + "/Library/Messages/chat.db"
        guard FileManager.default.fileExists(atPath: path) else {
            return
        }
        let id = "messages:\(config.accountId)"
        let existing = localStore.connectedSource(id: id)
        localStore.upsertConnectedSource(
            id: id,
            sourceType: "messages",
            accountId: config.accountId,
            sourceName: "Messages",
            enabled: existing?.enabled ?? true,
            syncCursor: existing?.syncCursor,
            totalEstimated: existing?.totalEstimated ?? 0,
            totalSynced: existing?.totalSynced ?? 0,
            status: existing?.status ?? "idle",
            lastError: existing?.lastError
        )
    }

    private func syncMailSource(_ source: ConnectedSource) async throws {
        guard let parsed = parseMailSourceId(source.id) else {
            throw NSError(domain: "SourceManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid mail source id: \(source.id)"])
        }

        var cursor = source.syncCursor
        if cursor == nil {
            guard let oldest = await mailWatcher.oldestMessageDate(accountId: parsed.accountId, mailbox: parsed.mailbox) else {
                localStore.updateConnectedSourceSync(
                    id: source.id,
                    syncCursor: nil,
                    totalEstimated: 0,
                    totalSynced: source.totalSynced,
                    status: "current",
                    lastError: nil
                )
                return
            }
            cursor = oldest
        }

        let estimated: Int
        if source.totalEstimated <= 0 {
            estimated = await mailWatcher.messageCount(accountId: parsed.accountId, mailbox: parsed.mailbox)
        } else {
            estimated = source.totalEstimated
        }

        localStore.updateConnectedSourceSync(
            id: source.id,
            syncCursor: cursor,
            totalEstimated: estimated,
            totalSynced: source.totalSynced,
            status: "syncing",
            lastError: nil
        )

        guard let activeCursor = cursor else {
            return
        }

        let batch = await mailWatcher.fetchMessages(
            accountId: parsed.accountId,
            mailbox: parsed.mailbox,
            since: activeCursor,
            limit: perSourceBatchSize
        )

        if batch.isEmpty {
            localStore.updateConnectedSourceSync(
                id: source.id,
                syncCursor: activeCursor,
                totalEstimated: estimated,
                totalSynced: source.totalSynced,
                status: "current",
                lastError: nil
            )
            return
        }

        let processing = try await mailProcessor.process(messages: batch, workspaceId: config.workspaceId)
        try await publishMailPayloads(result: processing, accountId: parsed.accountId)

        let newestDate = batch.map(\.date).max() ?? activeCursor
        let newSyncedTotal = source.totalSynced + processing.rawMessages.count

        localStore.updateConnectedSourceSync(
            id: source.id,
            syncCursor: newestDate,
            totalEstimated: estimated,
            totalSynced: newSyncedTotal,
            status: "syncing",
            lastError: nil
        )
    }

    private func syncCalendarSource(_ source: ConnectedSource) async throws {
        guard let calendarId = parseCalendarSourceId(source.id) else {
            throw NSError(domain: "SourceManager", code: 4, userInfo: [NSLocalizedDescriptionKey: "invalid calendar source id: \(source.id)"])
        }
        localStore.updateConnectedSourceSync(
            id: source.id,
            syncCursor: source.syncCursor,
            totalEstimated: source.totalEstimated,
            totalSynced: source.totalSynced,
            status: "syncing",
            lastError: nil
        )

        let start = source.syncCursor ?? Date(timeIntervalSince1970: 0)
        let end = Date()
        let events = try await calendarWatcher.fetchEvents(calendarId: calendarId, since: start, until: end)
        if events.isEmpty {
            localStore.updateConnectedSourceSync(
                id: source.id,
                syncCursor: source.syncCursor,
                totalEstimated: source.totalEstimated,
                totalSynced: source.totalSynced,
                status: "current",
                lastError: nil
            )
            return
        }

        var sentCount = 0
        var newestDate = source.syncCursor
        let payload = CalendarPayload(
            type: "calendar",
            workspaceId: config.workspaceId,
            accountId: config.accountId,
            calendarId: calendarId,
            calendarName: source.sourceName,
            sourceProvider: "calendar_mac",
            events: events.map(\.payload)
        )
        let json = try encodeJSON(payload)
        try await webSocketPublisher.send(type: "calendar", payload: json)
        sentCount += payload.events.count

        let payloadNewest = payload.events.compactMap { ISO8601DateFormatter().date(from: $0.endAt) }.max()
        if let payloadNewest {
            if let current = newestDate {
                if payloadNewest > current {
                    newestDate = payloadNewest
                }
            } else {
                newestDate = payloadNewest
            }
        }

        localStore.updateConnectedSourceSync(
            id: source.id,
            syncCursor: newestDate,
            totalEstimated: source.totalEstimated,
            totalSynced: source.totalSynced + sentCount,
            status: "syncing",
            lastError: nil
        )
    }

    private func publishMailPayloads(result: MailProcessingResult, accountId: String) async throws {
        let rawMessages = result.rawMessages
        let entities = result.entities

        if rawMessages.isEmpty {
            return
        }

        if entities.isEmpty {
            for message in rawMessages {
                localStore.markMessageSent(message.messageId)
            }
            return
        }

        let entitiesPayload = SourceEntitiesPayload(
            type: "entities",
            workspaceId: config.workspaceId,
            accountId: accountId,
            entities: entities
        )
        let chunksPayload = SourceChunksPayload(
            type: "chunks",
            workspaceId: config.workspaceId,
            accountId: accountId,
            messages: rawMessages.map {
                SourceChunksPayload.Message(
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

        try await webSocketPublisher.send(type: "entities", payload: try encodeJSON(entitiesPayload))
        try await webSocketPublisher.send(type: "chunks", payload: try encodeJSON(chunksPayload))

        for messageId in Set(rawMessages.map(\.messageId)) {
            localStore.markMessageSent(messageId)
        }
    }

    private func parseMailSourceId(_ id: String) -> (accountId: String, mailbox: String)? {
        guard id.hasPrefix("mail:") else {
            return nil
        }
        let raw = String(id.dropFirst("mail:".count))
        let parts = raw.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }
        let accountId = String(parts[0])
        let mailbox = String(parts[1])
        if accountId.isEmpty || mailbox.isEmpty {
            return nil
        }
        return (accountId, mailbox)
    }

    private func parseCalendarSourceId(_ id: String) -> String? {
        guard id.hasPrefix("calendar:") else {
            return nil
        }
        let raw = String(id.dropFirst("calendar:".count))
        return raw.isEmpty ? nil : raw
    }

    private func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        guard let json = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "SourceManager", code: 3, userInfo: [NSLocalizedDescriptionKey: "payload encode failed"])
        }
        return json
    }

    private func iso8601WithFractionalSeconds(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}

private struct SourceEntitiesPayload: Codable {
    let type: String
    let workspaceId: String
    let accountId: String
    let entities: [ExtractedEntity]
}

private struct SourceChunksPayload: Codable {
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
