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
    private var syncingIds: Set<String> = []

    private let perSourceBatchSize = 100
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
        checkFullDiskAccess()
        await discoverMailSources()
        await discoverCalendarSources()
        discoverMessagesSource()
        await refreshSources()
    }

    private func checkFullDiskAccess() {
        let mailRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mail/V10")
        let isFDA = FileManager.default.isReadableFile(atPath: mailRoot.path)
        if isFDA {
            logger.info("SourceManager: Full Disk Access GRANTED (V10 is readable)")
        } else {
            logger.warning("SourceManager: Full Disk Access MISSING! Mail sync will be slow. Grant FDA to BlawbyAgent in System Settings > Privacy & Security.")
        }
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
        await syncSource(id, maxBatches: Int.max)
    }

    func syncSource(_ id: String, maxBatches: Int) async {
        logger.info("syncSource: called for \(id)")
        let shouldSync = await MainActor.run {
            if syncingIds.contains(id) {
                logger.info("syncSource: skipping \(id) - already syncing")
                return false
            }
            syncingIds.insert(id)
            return true
        }
        
        guard shouldSync else { return }

        defer {
            Task { @MainActor in
                syncingIds.remove(id)
            }
        }

        guard let source = localStore.connectedSource(id: id) else {
            logger.info("syncSource: skipping \(id) - source not found")
            return
        }
        if !source.enabled {
            logger.info("syncSource: skipping \(id) - source disabled")
            return
        }

        do {
            switch source.sourceType {
            case "mail":
                try await syncMailSource(source, maxBatches: maxBatches)
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
        // Start discovery in background, don't block the sync loop
        Task.detached(priority: .background) { [weak self] in
            guard let self = self else { return }
            await self.discoverSources()
        }

        while running && !Task.isCancelled {
            let nextIds = nextSourceIdsForCycle()
            logger.info("sync cycle: processing \(nextIds.count) sources: \(nextIds.joined(separator: ", "))")
            for id in nextIds {
                if !running || Task.isCancelled {
                    break
                }
                logger.info("sync cycle: attempting to sync source: \(id)")
                await syncSource(id, maxBatches: 1)
                try? await Task.sleep(nanoseconds: interSourceDelayNanoseconds)
            }
            if nextIds.isEmpty {
                try? await Task.sleep(nanoseconds: interSourceDelayNanoseconds)
            }
        }
    }

    private func nextSourceIdsForCycle() -> [String] {
        let allSources = localStore.connectedSources()
        logger.info("cycle candidates: \(allSources.filter { $0.enabled }.map { "\($0.id)=\($0.status)" }.joined(separator: ", "))")
        
        let baselineIds = allSources
            .filter { source in
                guard source.enabled else { return false }
                
                if source.status == "syncing" || source.status == "pending" {
                    return true
                }
                
                // Allow anything that is idle, not just if estimated > 0.
                if source.status == "idle" {
                    return true
                }
                
                return false
            }
            .map { $0.id }
        
        logger.info("sync baseline: total=\(baselineIds.count), first=\(baselineIds.first ?? "none"), contains gmail=\(baselineIds.contains { $0.contains("paulchrisluke@gmail.com") })")
        
        // Prioritize Gmail sources first
        let gmailSources = baselineIds.filter { $0.contains("paulchrisluke@gmail.com") }
        let otherSources = baselineIds.filter { !$0.contains("paulchrisluke@gmail.com") }
        let prioritizedIds = gmailSources + otherSources
        logger.info("sync prioritization: gmail sources=\(gmailSources.count), other sources=\(otherSources.count), gmail first=\(gmailSources.first ?? "none")")
        
        if dirtySourceIds.isEmpty {
            logger.info("sync returning prioritized: count=\(prioritizedIds.count)")
            return prioritizedIds
        }
        
        let dirtyIds = dirtySourceIds
        logger.info("sync dirty sources detected: dirty=\(dirtyIds.count), prioritized=\(prioritizedIds.count)")
        logger.info("sync dirty sources: \(dirtyIds.joined(separator: ", "))")
        dirtySourceIds.removeAll()
        
        // Combine dirty and prioritized sources, but maintain Gmail priority
        let combinedSources = Array(Set(prioritizedIds).union(dirtyIds))
        let gmailAllSources = combinedSources.filter { $0.contains("paulchrisluke@gmail.com") }
        let otherAllSources = combinedSources.filter { !$0.contains("paulchrisluke@gmail.com") }
        let finalPrioritizedIds = gmailAllSources + otherAllSources
        
        logger.info("sync final prioritized: gmail=\(gmailAllSources.count), total=\(finalPrioritizedIds.count), gmail first=\(finalPrioritizedIds.first ?? "none")")
        return finalPrioritizedIds
    }

    private func isVirtualMailbox(_ name: String) -> Bool {
        let virtual = ["[Gmail]/Important", "[Gmail]/Starred", 
                       "[Gmail]/Spam", "[Gmail]/Trash", "[Gmail]/Sent Mail", "[Gmail]/Drafts",
                       "Junk", "Deleted Messages"]
        return virtual.contains(name)
    }

    private func discoverMailSources() async {
        let discovered = await mailWatcher.discoverSources()
        for source in discovered {
            logger.info("processing discovered source: \(source.id) mailbox='\(source.mailbox)' name='\(source.sourceName)'")
            if isVirtualMailbox(source.mailbox) {
                logger.info("skipping virtual mailbox: \(source.mailbox)")
                continue
            }
            
            let existing = localStore.connectedSource(id: source.id)
            
            // Rename All Mail to INBOX for Gmail accounts
            let displayName = source.sourceName == "All Mail" && source.accountId.contains("gmail") ? "INBOX" : source.sourceName
            let finalSourceId = source.sourceName == "All Mail" && source.accountId.contains("gmail") ? "mail:\(source.accountId):INBOX" : source.id
            if source.sourceName == "All Mail" && source.accountId.contains("gmail") {
                logger.info("renaming Gmail All Mail to INBOX for \(source.accountId), updating source ID from \(source.id) to \(finalSourceId)")
            }
            
            // Get message count to populate total_estimated
            let messageCount = await mailWatcher.messageCount(accountId: source.accountId, mailbox: source.mailbox)
            
            let updatedEstimated: Int
            if let existing = existing, existing.totalSynced > 0, existing.totalEstimated > 0 {
                updatedEstimated = existing.totalEstimated
            } else {
                updatedEstimated = messageCount
            }
            
            localStore.upsertConnectedSource(
                id: finalSourceId,
                sourceType: "mail",
                accountId: source.accountId,
                sourceName: displayName,
                enabled: existing?.enabled ?? true,
                syncCursor: existing?.syncCursor,
                totalEstimated: updatedEstimated,
                totalSynced: existing?.totalSynced ?? 0,
                status: existing?.status ?? "pending",
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
                
                let updatedEstimated: Int
                if let existing = existing, existing.totalSynced > 0, existing.totalEstimated > 0 {
                    updatedEstimated = existing.totalEstimated
                } else {
                    updatedEstimated = events.count
                }
                
                localStore.upsertConnectedSource(
                    id: id,
                    sourceType: "calendar",
                    accountId: config.accountId,
                    sourceName: source.sourceName,
                    enabled: existing?.enabled ?? true,
                    syncCursor: existing?.syncCursor,
                    totalEstimated: updatedEstimated,
                    totalSynced: existing?.totalSynced ?? 0,
                    status: existing?.status ?? "pending",
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
            status: existing?.status ?? "pending",
            lastError: existing?.lastError
        )
    }

    private func syncMailSource(_ source: ConnectedSource, maxBatches: Int = Int.max) async throws {
        guard let parsed = try parseMailSourceId(source.id) else {
            throw NSError(domain: "SourceManager", code: 2, userInfo: [NSLocalizedDescriptionKey: "invalid mail source id: \(source.id)"])
        }
        logger.info("syncing mail source: \(source.sourceName) (estimated \(source.totalEstimated)) - parsed: \(parsed.accountId):\(parsed.mailbox)")
        
        let estimated: Int
        if source.totalEstimated <= 0 {
            estimated = await mailWatcher.messageCount(accountId: parsed.accountId, mailbox: parsed.mailbox)
        } else {
            estimated = source.totalEstimated
        }

        localStore.updateConnectedSourceSync(
            id: source.id,
            syncCursor: source.syncCursor,
            totalEstimated: estimated,
            totalSynced: source.totalSynced,
            status: "syncing",
            lastError: nil
        )
        logger.info("syncing mail source: \(source.sourceName) (estimated \(estimated))")

        var cursor = source.syncCursor
        if cursor == nil {
            cursor = Date(timeIntervalSince1970: 0)
        }
        
        var currentCursor = cursor!
        var batchesProcessed = 0
        var totalProcessed = 0
        
        while batchesProcessed < maxBatches {
            let batch = await mailWatcher.fetchMessages(
                accountId: parsed.accountId,
                mailbox: parsed.mailbox,
                since: currentCursor,
                limit: perSourceBatchSize
            )
            logger.info("fetched \(batch.count) messages for \(source.sourceName) since \(currentCursor)")

            if batch.isEmpty {
                let finalStatus = (source.totalSynced + totalProcessed >= estimated && estimated > 0) ? "current" : "pending"
                logger.info("batch empty for \(source.sourceName), final status: \(finalStatus)")
                localStore.updateConnectedSourceSync(
                    id: source.id,
                    syncCursor: currentCursor,
                    totalEstimated: estimated,
                    totalSynced: source.totalSynced + totalProcessed,
                    status: finalStatus,
                    lastError: nil
                )
                break
            }

            logger.info("processing batch of \(batch.count) messages for \(source.sourceName)")
            let isBackfill = source.totalSynced < estimated
            
            // Get chunks immediately (fast path) - skip entity extraction to avoid blocking
            logger.info("calling mailProcessor.process with \(batch.count) messages (chunks only)")
            let chunksProcessing = try await mailProcessor.process(messages: batch, workspaceId: config.workspaceId, skipExtraction: true)
            logger.info("chunks processing complete for \(chunksProcessing.rawMessages.count) messages for \(source.sourceName)")
            
            // Send chunks immediately
            if !chunksProcessing.rawMessages.isEmpty {
                let chunksPayload = SourceChunksPayload(
                    type: "chunks",
                    workspaceId: config.workspaceId,
                    accountId: parsed.accountId,
                    messages: chunksProcessing.rawMessages.map {
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
                logger.info("chunks payload sample: subject='\(chunksPayload.messages.first?.subject ?? "nil")' bodyLen=\(chunksPayload.messages.first?.bodyText.count ?? 0)")
                try await webSocketPublisher.send(type: "chunks", payload: try encodeJSON(chunksPayload))
                logger.info("published chunks for \(chunksProcessing.rawMessages.count) messages for \(source.sourceName)")
            }
            
            // Entity extraction runs in background, doesn't block cursor advancement
            Task.detached(priority: .background) { [weak self] in
                guard let self = self else { return }
                logger.info("background entity extraction starting for \(batch.count) messages")
                do {
                    let entitiesProcessing = try await self.mailProcessor.process(messages: batch, workspaceId: self.config.workspaceId, skipExtraction: false)
                    if !entitiesProcessing.entities.isEmpty {
                        let entitiesPayload = SourceEntitiesPayload(
                            type: "entities",
                            workspaceId: self.config.workspaceId,
                            accountId: parsed.accountId,
                            entities: entitiesProcessing.entities
                        )
                        try await self.webSocketPublisher.send(type: "entities", payload: self.encodeJSON(entitiesPayload))
                        logger.info("published entities for \(entitiesProcessing.entities.count) entities for \(parsed.accountId)")
                    } else {
                        logger.info("no entities extracted from \(batch.count) messages for \(parsed.accountId)")
                    }
                } catch {
                    logger.error("background entity extraction failed: \(error.localizedDescription)")
                }
            }

            let batchNewestDate = batch.map(\.date).max() ?? currentCursor
            // Keep cursor strictly increasing to avoid boundary loops on repeated timestamp matches.
            let newestDateInBatch = max(batchNewestDate, currentCursor).addingTimeInterval(0.001)
            
            // Never advance cursor beyond current time
            let safeCursor = min(newestDateInBatch, Date())
            // Only advance cursor if new date is actually newer than current cursor  
            let newestDate = safeCursor > currentCursor ? safeCursor : currentCursor
            
            // Update cursor for next batch
            currentCursor = newestDate
            totalProcessed += chunksProcessing.rawMessages.count

            localStore.updateConnectedSourceSync(
                id: source.id,
                syncCursor: currentCursor,
                totalEstimated: estimated,
                totalSynced: source.totalSynced + totalProcessed,
                status: (source.totalSynced + totalProcessed >= estimated) ? "current" : "syncing",
                lastError: nil
            )
            
            batchesProcessed += 1
            logger.info("completed batch \(batchesProcessed)/\(maxBatches) for \(source.sourceName), total processed: \(totalProcessed)")
        }
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
                syncCursor: end,
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

        let nextEstimated = max(source.totalEstimated, source.totalSynced + sentCount)
        localStore.updateConnectedSourceSync(
            id: source.id,
            syncCursor: newestDate,
            totalEstimated: nextEstimated,
            totalSynced: source.totalSynced + sentCount,
            status: "current",
            lastError: nil
        )
    }

    private func publishMailPayloads(result: MailProcessingResult, accountId: String) async throws {
        let rawMessages = result.rawMessages
        let entities = result.entities

        if rawMessages.isEmpty {
            return
        }

        if !entities.isEmpty {
            let entitiesPayload = SourceEntitiesPayload(
                type: "entities",
                workspaceId: config.workspaceId,
                accountId: accountId,
                entities: entities
            )
            try await webSocketPublisher.send(type: "entities", payload: try encodeJSON(entitiesPayload))
        }

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

        logger.info("chunks payload sample: subject='\(chunksPayload.messages.first?.subject ?? "nil")' bodyLen=\(chunksPayload.messages.first?.bodyText.count ?? 0)")
        try await webSocketPublisher.send(type: "chunks", payload: try encodeJSON(chunksPayload))
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
