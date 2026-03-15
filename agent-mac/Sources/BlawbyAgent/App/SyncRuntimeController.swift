import Foundation

@MainActor
final class SyncRuntimeController {
    struct Dependencies {
        let syncCoordinator: SyncCoordinator
        let sourceManager: SourceManager
        let mailWatcher: MailWatcher
        let calendarWatcher: CalendarWatcher
        let logger: Logger
        let config: Config
        let localStore: LocalStore
        let webSocketPublisher: WebSocketPublisher
        let isSyncEnabled: @MainActor () -> Bool
    }

    private let deps: Dependencies
    private var messagesReader: MessagesReader?
    private var bootstrapTask: Task<Void, Never>?
    private var started = false

    var onMenuRefresh: (@MainActor () -> Void)?

    init(dependencies: Dependencies) {
        self.deps = dependencies
    }

    func start() {
        guard !started else { return }
        started = true

        deps.webSocketPublisher.connect()
        deps.sourceManager.start()

        deps.mailWatcher.startObserving { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.deps.isSyncEnabled() else { return }
                self.deps.sourceManager.markSourcesChanged(sourceType: "mail")
                await self.deps.syncCoordinator.runMailSync()
                self.onMenuRefresh?()
            }
        }

        deps.calendarWatcher.startObserving { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                guard self.deps.isSyncEnabled() else { return }
                self.deps.sourceManager.markSourcesChanged(sourceType: "calendar")
                await self.deps.syncCoordinator.runCalendarSync()
                self.onMenuRefresh?()
            }
        }

        let reader = MessagesReader(
            localStore: deps.localStore,
            logger: deps.logger,
            accountId: deps.config.accountId,
            workspaceId: deps.config.workspaceId
        )
        messagesReader = reader

        reader.start(
            onChange: { [weak self] payload in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.deps.isSyncEnabled() else { return }
                    await self.deps.syncCoordinator.publishRawPayload(type: "message", json: payload)
                    self.onMenuRefresh?()
                }
            },
            onProgress: { [weak self] progress in
                _ = progress
                Task { @MainActor in
                    self?.onMenuRefresh?()
                }
            }
        )

        Task {
            _ = await deps.mailWatcher.accountNames()
            await MainActor.run { onMenuRefresh?() }
        }

        Task {
            do {
                _ = try await deps.calendarWatcher.calendarSourceNames()
                await MainActor.run { onMenuRefresh?() }
            } catch {
                await MainActor.run { onMenuRefresh?() }
            }
        }

        bootstrapTask = Task.detached { [syncCoordinator = deps.syncCoordinator] in
            await syncCoordinator.runInitialBootstrapSyncIfNeeded()
            await syncCoordinator.runMailSync()
            await syncCoordinator.runCalendarSync()
        }
    }

    func stop() {
        guard started else { return }
        started = false

        bootstrapTask?.cancel()
        bootstrapTask = nil
        deps.mailWatcher.stopObserving()
        deps.calendarWatcher.stopObserving()
        messagesReader?.stop()
        messagesReader = nil
        deps.sourceManager.stop()
        deps.webSocketPublisher.disconnect()
    }
}
