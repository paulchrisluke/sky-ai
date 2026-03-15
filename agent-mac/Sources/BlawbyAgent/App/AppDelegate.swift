import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var uiController: AppUIController?
    private var runtimeController: SyncRuntimeController?
    private var commandController: AppCommandController?

    private var logger: Logger?
    private var syncCoordinator: SyncCoordinator?
    private var sourceManager: SourceManager?
    private var contactsReader: ContactsReader?
    private var config: Config?

    private let iso = ISO8601DateFormatter()
    private var lastSyncDisplay = "-"
    private var connectionDisplay = "Connecting"
    private var syncActivated = false

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        uiController = AppUIController()

        do {
            let startup = try AppStartupComposer().compose()
            logger = startup.logger
            syncCoordinator = startup.syncCoordinator
            sourceManager = startup.sourceManager
            contactsReader = startup.contactsReader
            config = startup.config
            syncActivated = startup.syncActivated

            contactsReader?.start()

            if let uiController {
                uiController.observeSources(startup.sourceManager) { [weak self] in
                    self?.updateMenu()
                }
                uiController.setupMenuBar(
                    sourceManager: startup.sourceManager,
                    setSyncEnabled: { [weak self] enabled in self?.setSyncEnabled(enabled) },
                    openDashboard: { [weak self] in self?.openDashboard() },
                    preferences: { [weak self] in self?.openPreferences() }
                )
            }

            commandController = AppCommandController(
                openDashboard: { [weak self] in self?.openDashboard() },
                openPreferences: { [weak self] in self?.openPreferences() },
                toggleSync: { [weak self] in
                    guard let self else { return }
                    self.setSyncEnabled(!self.syncActivated)
                },
                isSyncEnabled: { [weak self] in
                    self?.syncActivated == true
                }
            )
            commandController?.installMainMenu()
            commandController?.refresh()

            startup.syncCoordinator.setOnStatusChanged { [weak self] snapshot in
                Task { @MainActor in
                    self?.applySyncSnapshot(snapshot)
                }
            }
            startup.webSocketPublisher.setOnConnected { [weak self] in
                Task { @MainActor in
                    await self?.syncCoordinator?.drainOutboundQueue()
                }
            }
            startup.webSocketPublisher.setOnConnectionStateChanged { [weak self] state in
                Task { @MainActor in
                    self?.applyConnectionState(state)
                }
            }

            runtimeController = SyncRuntimeController(
                dependencies: .init(
                    syncCoordinator: startup.syncCoordinator,
                    sourceManager: startup.sourceManager,
                    mailWatcher: startup.mailWatcher,
                    calendarWatcher: startup.calendarWatcher,
                    logger: startup.logger,
                    config: startup.config,
                    localStore: startup.localStore,
                    webSocketPublisher: startup.webSocketPublisher,
                    isSyncEnabled: { [weak self] in
                        self?.syncActivated == true
                    }
                )
            )
            runtimeController?.onMenuRefresh = { [weak self] in
                self?.updateMenu()
            }

            if syncActivated {
                runtimeController?.start()
            } else {
                connectionDisplay = "Paused"
            }
            updateMenu()
            configureLoginItemRegistration(logger: startup.logger)
        } catch {
            fputs("BlawbyAgent startup failed: \(error.localizedDescription)\n", stderr)
        }
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        runtimeController?.stop()
    }

    @MainActor
    private func openPreferences() {
        guard let config, let sourceManager else { return }
        uiController?.openPreferences(config: config, sourceManager: sourceManager)
    }

    @MainActor
    private func openDashboard() {
        guard let sourceManager else { return }
        uiController?.openDashboard(sourceManager: sourceManager)
    }

    @MainActor
    private func updateMenu() {
        let sources = sourceManager?.sources ?? []
        uiController?.updateMenu(
            lastSync: lastSyncDisplay,
            connection: connectionDisplay,
            syncActivated: syncActivated,
            sources: sources
        )
        commandController?.refresh()
    }

    @MainActor
    private func applySyncSnapshot(_ snapshot: SyncStatusSnapshot) {
        guard syncActivated else {
            updateMenu()
            return
        }
        if let lastSync = snapshot.lastSyncAt {
            lastSyncDisplay = iso.string(from: lastSync)
        }
        updateMenu()
    }

    @MainActor
    private func applyConnectionState(_ state: WebSocketConnectionState) {
        if !syncActivated {
            connectionDisplay = "Paused"
            updateMenu()
            return
        }

        switch state {
        case .disconnected:
            connectionDisplay = "Disconnected"
        case .connecting:
            connectionDisplay = "Connecting"
        case .connected:
            connectionDisplay = "Connected"
        case .reconnecting(let delaySeconds):
            connectionDisplay = "Reconnecting in \(delaySeconds)s"
        }
        updateMenu()
    }

    @MainActor
    private func setSyncEnabled(_ enabled: Bool) {
        guard syncActivated != enabled else { return }
        syncActivated = enabled
        UserDefaults.standard.set(syncActivated, forKey: Preferences.Keys.syncActivated)
        logger?.info("sync activated preference updated: \(syncActivated)")

        if syncActivated {
            runtimeController?.start()
        } else {
            runtimeController?.stop()
            connectionDisplay = "Paused"
        }
        updateMenu()
    }

    private func configureLoginItemRegistration(logger: Logger) {
        let bundlePath = Bundle.main.bundleURL.path
        let isApplicationsInstall = bundlePath.hasPrefix("/Applications/")

        if isApplicationsInstall {
            do {
                try SMAppService.mainApp.register()
                logger.info("login item registered via SMAppService")
            } catch {
                logger.warning("SMAppService register failed: \(error.localizedDescription)")
            }
            return
        }

        do {
            try SMAppService.mainApp.unregister()
            logger.info("login item unregistered for non-/Applications run")
        } catch {
            logger.warning("SMAppService unregister skipped: \(error.localizedDescription)")
        }
        logger.info("login item registration skipped (bundle path: \(bundlePath))")
    }
}
