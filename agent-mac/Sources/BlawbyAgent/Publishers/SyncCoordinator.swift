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
    let mailBootstrapPercent: Int
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

final class SyncCoordinator: @unchecked Sendable {
    private let stateQueue = DispatchQueue(label: "com.blawby.agent.sync.state")
    private var mailSyncRunning = false
    private var calendarSyncRunning = false
    private var mailMode: String?
    private var bootstrapStatus = "waiting"
    private var lastSyncAt: Date?
    private var onStatusChanged: (@Sendable (SyncStatusSnapshot) -> Void)?

    private let config: Config
    private let localStore: LocalStore
    private let webSocketPublisher: any WebSocketPublishing
    private let sourceManager: any SourceManaging
    private let logger: Logger

    init(
        config: Config,
        localStore: LocalStore,
        webSocketPublisher: any WebSocketPublishing,
        sourceManager: any SourceManaging,
        logger: Logger
    ) {
        self.config = config
        self.localStore = localStore
        self.webSocketPublisher = webSocketPublisher
        self.sourceManager = sourceManager
        self.logger = logger
    }

    func setOnStatusChanged(_ handler: (@Sendable (SyncStatusSnapshot) -> Void)?) {
        stateQueue.sync {
            onStatusChanged = handler
        }
        publishStatus()
    }

    func runMailSync() async {
        stateQueue.sync {
            mailSyncRunning = true
            mailMode = "sync"
        }
        publishStatus()

        let ids = await MainActor.run { () -> [String] in
            sourceManager.markSourcesChanged(sourceType: "mail")
            return sourceManager.enabledSourceIds(sourceType: "mail")
        }
        for id in ids {
            await sourceManager.syncSource(id)
        }

        stateQueue.sync {
            mailSyncRunning = false
            mailMode = nil
            lastSyncAt = Date()
        }
        publishStatus()
    }

    func runMailBackfill(days: Int, limit: Int = 1000) async {
        _ = days
        _ = limit
        await runMailSync()
    }

    func runCalendarSync() async {
        stateQueue.sync {
            calendarSyncRunning = true
        }
        publishStatus()

        let ids = await MainActor.run { () -> [String] in
            sourceManager.markSourcesChanged(sourceType: "calendar")
            return sourceManager.enabledSourceIds(sourceType: "calendar")
        }
        for id in ids {
            await sourceManager.syncSource(id)
        }

        stateQueue.sync {
            calendarSyncRunning = false
            lastSyncAt = Date()
        }
        publishStatus()
    }

    func runCalendarBackfill() async {
        await runCalendarSync()
    }

    func runInitialBootstrapSyncIfNeeded() async {
        stateQueue.sync {
            bootstrapStatus = "syncing"
        }
        publishStatus()

        await MainActor.run {
            sourceManager.start()
        }
        await runMailSync()
        await runCalendarSync()

        stateQueue.sync {
            bootstrapStatus = "completed"
            lastSyncAt = Date()
        }
        publishStatus()
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
        do {
            try await webSocketPublisher.send(type: type, payload: json)
            localStore.incrementSyncMetrics(accountId: config.accountId, source: "messages", discovered: 1, processed: 1, sent: 1)
        } catch {
            _ = localStore.enqueuePayload(type: type, json: json)
            localStore.incrementSyncMetrics(accountId: config.accountId, source: "messages", discovered: 1, processed: 1, queued: 1)
        }
        publishStatus()
    }

    private func publishStatus() {
        let mailMetrics = localStore.syncMetrics(accountId: config.accountId, source: "mail")
        let calendarMetrics = localStore.syncMetrics(accountId: config.accountId, source: "calendar")
        let connected = localStore.connectedSources()
        let calendarEnabled = connected.filter { $0.sourceType == "calendar" && $0.enabled }

        let payload = stateQueue.sync {
            (
                onStatusChanged,
                SyncStatusSnapshot(
                    mailSyncRunning: mailSyncRunning,
                    mailSyncQueued: false,
                    mailMode: mailMode,
                    calendarSyncRunning: calendarSyncRunning,
                    bootstrapStatus: bootstrapStatus,
                    lastMailProcessed: 0,
                    lastMailEntities: 0,
                    lastMailDelivery: "n/a",
                    mailDiscoveredTotal: mailMetrics.discovered,
                    mailProcessedTotal: mailMetrics.processed,
                    mailSentTotal: mailMetrics.sent,
                    mailQueuedTotal: mailMetrics.queued,
                    mailBootstrapWindowDone: bootstrapStatus == "completed" ? 1 : 0,
                    mailBootstrapWindowTotal: 1,
                    mailBootstrapPercent: bootstrapStatus == "completed" ? 100 : 0,
                    lastCalendarEvents: 0,
                    lastCalendarDelivery: "n/a",
                    calendarCalendarsProcessed: calendarEnabled.count,
                    calendarCalendarsTotal: calendarEnabled.count,
                    calendarEventsTotal: calendarMetrics.sent,
                    pendingPayloads: localStore.pendingPayloadCount(),
                    lastSyncAt: lastSyncAt
                )
            )
        }
        payload.0?(payload.1)
    }
}

extension WebSocketPublisher: WebSocketPublishing {}
