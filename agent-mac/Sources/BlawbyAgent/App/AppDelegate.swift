import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var menuBar: MenuBarController?
    private var preferencesWindow: PreferencesWindowController?

    private var logger: Logger?
    private var syncCoordinator: SyncCoordinator?
    private var mailWatcher: MailWatcher?
    private var calendarWatcher: CalendarWatcher?
    private var messagesReader: MessagesReader?
    private var contactsReader: ContactsReader?
    private var webSocketPublisher: WebSocketPublisher?
    private var config: Config?

    private var mailProcessedToday = 0
    private var calendarSynced = 0
    private let iso = ISO8601DateFormatter()
    private var lastSyncDisplay = "-"
    private var connectionDisplay = "connecting"
    private var syncDisplay = "idle"
    private var queuePendingDisplay = 0
    private var mailStatusDisplay = "n/a"
    private var calendarStatusDisplay = "n/a"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        do {
            let baseDir = resolveBlawbyHome()
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let logger = try Logger(baseDirectory: baseDir)
            self.logger = logger

            let localStore = try LocalStore(baseDirectory: baseDir)
            let configStore = try ConfigStore(baseDirectory: baseDir)
            let fileConfig = configStore.load()
            let prefs = try Preferences.load(config: fileConfig)
            let config = Config(
                workerUrl: prefs.workerUrl ?? fileConfig.workerUrl,
                apiKey: prefs.apiKey ?? fileConfig.apiKey,
                workspaceId: prefs.workspaceId ?? fileConfig.workspaceId,
                accountId: prefs.accountId ?? fileConfig.accountId,
                openaiApiKey: prefs.openaiApiKey ?? fileConfig.openaiApiKey
            )
            self.config = config

            let contactsReader = ContactsReader(localStore: localStore, logger: logger)
            self.contactsReader = contactsReader
            contactsReader.start()

            let extractor = EntityExtractor(apiKey: config.openaiApiKey, contactsReader: contactsReader, logger: logger)
            let mailProcessor = MailProcessor(localStore: localStore, extractor: extractor)
            let mailWatcher = MailWatcher(configStore: configStore, localStore: localStore, logger: logger)
            let calendarWatcher = CalendarWatcher(config: config, localStore: localStore, logger: logger)
            let webSocketPublisher = WebSocketPublisher(config: config, logger: logger)
            let coordinator = SyncCoordinator(
                config: config,
                localStore: localStore,
                webSocketPublisher: webSocketPublisher,
                mailWatcher: mailWatcher,
                mailProcessor: mailProcessor,
                calendarWatcher: calendarWatcher,
                logger: logger
            )

            self.syncCoordinator = coordinator
            self.mailWatcher = mailWatcher
            self.calendarWatcher = calendarWatcher
            self.webSocketPublisher = webSocketPublisher

            menuBar = MenuBarController(
                syncNow: { [weak self] in self?.syncNow() },
                backfill: { [weak self] in self?.backfillNow() },
                preferences: { [weak self] in self?.openPreferences() }
            )

            coordinator.setOnStatusChanged { [weak self] snapshot in
                Task { @MainActor in
                    self?.applySyncSnapshot(snapshot)
                }
            }

            webSocketPublisher.setOnConnected { [weak self] in
                Task { @MainActor in
                    await self?.syncCoordinator?.drainOutboundQueue()
                }
            }
            webSocketPublisher.setOnConnectionStateChanged { [weak self] state in
                Task { @MainActor in
                    self?.applyConnectionState(state)
                }
            }
            webSocketPublisher.connect()

            mailWatcher.startObserving { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    await self.syncCoordinator?.runMailSync()
                    self.mailProcessedToday += 1
                    self.updateMenu()
                }
            }

            calendarWatcher.startObserving { [weak self] in
                Task { @MainActor in
                    guard let self else { return }
                    await self.syncCoordinator?.runCalendarSync()
                    self.calendarSynced += 1
                    self.updateMenu()
                }
            }

            let messagesReader = MessagesReader(
                localStore: localStore,
                logger: logger,
                accountId: config.accountId,
                workspaceId: config.workspaceId
            )
            self.messagesReader = messagesReader
            messagesReader.start { [weak self] payload in
                Task { @MainActor in
                    guard let self else { return }
                    await self.syncCoordinator?.publishRawPayload(type: "message", json: payload)
                    self.updateMenu()
                }
            }

            Task {
                await coordinator.runInitialBootstrapSyncIfNeeded()
                await coordinator.runMailSync()
                await coordinator.runCalendarSync()
            }
            updateMenu()

            configureLoginItemRegistration(logger: logger)
        } catch {
            fputs("BlawbyAgent startup failed: \(error.localizedDescription)\n", stderr)
        }
    }

    @MainActor
    private func syncNow() {
        guard let syncCoordinator else { return }
        Task {
            await syncCoordinator.runMailSync()
            await syncCoordinator.runCalendarSync()
            await syncCoordinator.drainOutboundQueue()
            updateMenu()
        }
    }

    @MainActor
    private func backfillNow() {
        guard let syncCoordinator else { return }
        Task {
            await syncCoordinator.runMailBackfill(days: 90, limit: 1200)
            await syncCoordinator.drainOutboundQueue()
            updateMenu()
        }
    }

    @MainActor
    private func openPreferences() {
        guard let config else { return }
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController(config: config)
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @MainActor
    private func updateMenu() {
        menuBar?.update(
            lastSync: lastSyncDisplay,
            mailProcessed: mailProcessedToday,
            calendarSynced: calendarSynced,
            connection: connectionDisplay,
            syncState: syncDisplay,
            queuePending: queuePendingDisplay,
            mailStatus: mailStatusDisplay,
            calendarStatus: calendarStatusDisplay
        )
    }

    @MainActor
    private func applySyncSnapshot(_ snapshot: SyncStatusSnapshot) {
        if let lastSync = snapshot.lastSyncAt {
            lastSyncDisplay = iso.string(from: lastSync)
        }

        if snapshot.mailSyncRunning && snapshot.mailSyncQueued {
            let mode = snapshot.mailMode ?? "sync"
            syncDisplay = "active (\(mode), queued)"
        } else if snapshot.mailSyncRunning {
            let mode = snapshot.mailMode ?? "sync"
            syncDisplay = "active (\(mode))"
        } else if snapshot.calendarSyncRunning {
            syncDisplay = "active (calendar)"
        } else {
            syncDisplay = "inactive"
        }

        queuePendingDisplay = snapshot.pendingPayloads
        mailStatusDisplay = "processed=\(snapshot.lastMailProcessed), entities=\(snapshot.lastMailEntities), delivery=\(snapshot.lastMailDelivery)"
        calendarStatusDisplay = "events=\(snapshot.lastCalendarEvents), delivery=\(snapshot.lastCalendarDelivery)"
        updateMenu()
    }

    @MainActor
    private func applyConnectionState(_ state: WebSocketConnectionState) {
        switch state {
        case .disconnected:
            connectionDisplay = "disconnected"
        case .connecting:
            connectionDisplay = "connecting"
        case .connected:
            connectionDisplay = "connected"
        case .reconnecting(let delaySeconds):
            connectionDisplay = "reconnecting in \(delaySeconds)s"
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

        // Prevent debug/dev runs from accumulating duplicate Open at Login entries.
        do {
            try SMAppService.mainApp.unregister()
            logger.info("login item unregistered for non-/Applications run")
        } catch {
            logger.warning("SMAppService unregister skipped: \(error.localizedDescription)")
        }
        logger.info("login item registration skipped (bundle path: \(bundlePath))")
    }
}
