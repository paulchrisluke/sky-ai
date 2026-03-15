@preconcurrency import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppSession: ObservableObject {
    @Published private(set) var sourceManager: SourceManager?
    @Published private(set) var config: Config?
    @Published private(set) var startupError: String?

    let menuState = MenuBarState()

    private var logger: Logger?
    private var syncCoordinator: SyncCoordinator?
    private var runtimeController: SyncRuntimeController?
    private var contactsReader: ContactsReader?
    private let iso = ISO8601DateFormatter()
    private nonisolated(unsafe) var terminationObserver: NSObjectProtocol?

    init() {
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        bootstrap()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.shutdown()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    func toggleSync() {
        setSyncEnabled(!menuState.syncActivated)
    }

    func setSyncEnabled(_ enabled: Bool) {
        guard menuState.syncActivated != enabled else { return }
        menuState.syncActivated = enabled
        UserDefaults.standard.set(enabled, forKey: Preferences.Keys.syncActivated)
        logger?.info("sync activated preference updated: \(enabled)")

        if enabled {
            runtimeController?.start()
        } else {
            runtimeController?.stop()
            menuState.connection = "Paused"
        }
    }

    func saveConnectionSettings(
        workerUrl: String,
        workspaceId: String,
        accountId: String,
        apiKey: String,
        openaiApiKey: String
    ) throws {
        let defaults = UserDefaults.standard
        defaults.set(workerUrl, forKey: Preferences.Keys.workerUrl)
        defaults.set(workspaceId, forKey: Preferences.Keys.workspaceId)
        defaults.set(accountId, forKey: Preferences.Keys.accountId)

        let keychain = KeychainStore()
        let trimmedAPI = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedAPI.isEmpty {
            try keychain.delete(Preferences.Keys.keychainAPIKey)
        } else {
            try keychain.write(trimmedAPI, account: Preferences.Keys.keychainAPIKey)
        }

        let trimmedOpenAI = openaiApiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOpenAI.isEmpty {
            try keychain.delete(Preferences.Keys.keychainOpenAI)
        } else {
            try keychain.write(trimmedOpenAI, account: Preferences.Keys.keychainOpenAI)
        }

        guard let current = config else { return }
        config = Config(
            workerUrl: workerUrl,
            apiKey: trimmedAPI.isEmpty ? current.apiKey : trimmedAPI,
            workspaceId: workspaceId,
            accountId: ConfigStore.normalizeAccountId(accountId),
            openaiApiKey: trimmedOpenAI.isEmpty ? nil : trimmedOpenAI
        )
    }

    func shutdown() {
        runtimeController?.stop()
    }

    private func bootstrap() {
        NSApp.setActivationPolicy(.accessory)

        do {
            let startup = try AppStartupComposer().compose()
            logger = startup.logger
            sourceManager = startup.sourceManager
            syncCoordinator = startup.syncCoordinator
            contactsReader = startup.contactsReader
            config = startup.config

            menuState.syncActivated = startup.syncActivated
            menuState.connection = startup.syncActivated ? "Connecting" : "Paused"

            startup.syncCoordinator.setOnStatusChanged { [weak self] snapshot in
                Task { @MainActor in
                    if let lastSync = snapshot.lastSyncAt {
                        self?.menuState.lastSync = self?.iso.string(from: lastSync) ?? "-"
                    }
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

            let runtime = SyncRuntimeController(
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
                        self?.menuState.syncActivated == true
                    }
                )
            )
            runtimeController = runtime

            contactsReader?.start()
            if menuState.syncActivated {
                runtime.start()
            }
            configureLoginItemRegistration(logger: startup.logger)
        } catch {
            startupError = error.localizedDescription
        }
    }

    private func applyConnectionState(_ state: WebSocketConnectionState) {
        if !menuState.syncActivated {
            menuState.connection = "Paused"
            return
        }

        switch state {
        case .disconnected:
            menuState.connection = "Disconnected"
        case .connecting:
            menuState.connection = "Connecting"
        case .connected:
            menuState.connection = "Connected"
        case .reconnecting(let delaySeconds):
            menuState.connection = "Reconnecting in \(delaySeconds)s"
        }
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
