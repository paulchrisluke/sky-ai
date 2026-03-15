import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var menuBar: MenuBarController?
    private var preferencesWindow: PreferencesWindowController?

    private var logger: Logger?
    private var localStore: LocalStore?
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
    private var connectionDisplay = "Connecting"
    private var syncDisplay = "Idle"
    private var syncProgressDisplay: Int?
    private var queuePendingDisplay = 0
    private var mailStatusDisplay = "Waiting for Mail access"
    private var calendarStatusDisplay = "Waiting for Calendar access"
    private var messagesStatusDisplay = "Waiting for Messages access"
    private var mailAccountNames: [String] = []
    private var knownMailAccountNames: [String] = []
    private var calendarSourceNames: [String] = []
    private var knownCalendarSourceNames: [String] = []
    private var messagesSourceAvailable = false
    private var messagesSourceConnected = false
    private var messagesTotal = 0
    private var messageBatchCount = 0
    private var syncActivated = false
    private var syncRuntimeStarted = false
    private var bootstrapTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        do {
            let baseDir = resolveBlawbyHome()
            try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
            let logger = try Logger(baseDirectory: baseDir)
            self.logger = logger

            let localStore = try LocalStore(baseDirectory: baseDir)
            self.localStore = localStore
            knownMailAccountNames = localStore.knownMailAccounts()
            knownCalendarSourceNames = localStore.knownCalendarSources()
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
            syncActivated = UserDefaults.standard.bool(forKey: Preferences.Keys.syncActivated)

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
                setSyncEnabled: { [weak self] enabled in self?.setSyncEnabled(enabled) },
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
            if syncActivated {
                startSyncRuntime(
                    coordinator: coordinator,
                    mailWatcher: mailWatcher,
                    calendarWatcher: calendarWatcher,
                    logger: logger,
                    config: config,
                    localStore: localStore,
                    webSocketPublisher: webSocketPublisher
                )
            } else {
                connectionDisplay = "Paused"
                syncDisplay = "Off"
            }
            updateMenu()

            configureLoginItemRegistration(logger: logger)
        } catch {
            fputs("BlawbyAgent startup failed: \(error.localizedDescription)\n", stderr)
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
            syncProgress: syncProgressDisplay,
            mailStatus: mailStatusDisplay,
            calendarStatus: calendarStatusDisplay,
            messagesStatus: messagesStatusDisplay,
            connectedMailAccounts: mailAccountNames,
            knownMailAccounts: knownMailAccountNames,
            connectedCalendarSources: calendarSourceNames,
            knownCalendarSources: knownCalendarSourceNames,
            messagesSourceConnected: messagesSourceConnected,
            messagesSourceAvailable: messagesSourceAvailable,
            syncActivated: syncActivated
        )
    }

    @MainActor
    private func applySyncSnapshot(_ snapshot: SyncStatusSnapshot) {
        if let lastSync = snapshot.lastSyncAt {
            lastSyncDisplay = iso.string(from: lastSync)
        }

        queuePendingDisplay = snapshot.pendingPayloads
        let connectedAccounts = mailAccountNames.count
        let availableAccounts = max(knownMailAccountNames.count, connectedAccounts)
        let mailSyncState: String
        if snapshot.mailBootstrapWindowTotal > 0 {
            let pct = Int((Double(snapshot.mailBootstrapWindowDone) / Double(snapshot.mailBootstrapWindowTotal)) * 100.0)
            let bounded = max(0, min(100, pct))
            syncProgressDisplay = bounded
            mailSyncState = bounded >= 100 ? "Synced" : "Syncing"
        } else {
            syncProgressDisplay = 100
            mailSyncState = "Synced"
        }
        let anyActive = snapshot.mailSyncRunning || snapshot.calendarSyncRunning || (syncProgressDisplay ?? 100) < 100
        syncDisplay = anyActive ? "Syncing" : "Synced"

        mailStatusDisplay = "Accounts \(connectedAccounts)/\(availableAccounts) | \(mailSyncState) | Processed \(snapshot.mailProcessedTotal)"
        if queuePendingDisplay > 0 {
            mailStatusDisplay += " | Queue \(queuePendingDisplay)"
        }
        let connectedCalendars = calendarSourceNames.count
        let availableCalendars = max(knownCalendarSourceNames.count, connectedCalendars)
        calendarStatusDisplay = "Sources \(connectedCalendars)/\(availableCalendars) | \(syncDisplay) | Events \(snapshot.calendarEventsTotal)"

        let connectedMessageSources = messagesSourceConnected ? 1 : 0
        let availableMessageSources = messagesSourceAvailable ? 1 : 0
        messagesStatusDisplay = "Sources \(connectedMessageSources)/\(availableMessageSources) | \(syncDisplay) | Total \(messagesTotal)"
        mailProcessedToday = snapshot.mailProcessedTotal
        calendarSynced = snapshot.calendarEventsTotal
        updateMenu()
    }

    @MainActor
    private func applyConnectionState(_ state: WebSocketConnectionState) {
        if !syncActivated {
            connectionDisplay = "Paused"
            syncProgressDisplay = nil
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
        if syncActivated == enabled {
            return
        }
        syncActivated = enabled
        UserDefaults.standard.set(syncActivated, forKey: Preferences.Keys.syncActivated)

        if !syncActivated {
            stopSyncRuntime()
            connectionDisplay = "Paused"
            syncDisplay = "Off"
            syncProgressDisplay = nil
            updateMenu()
            return
        }

        guard
            let coordinator = syncCoordinator,
            let mailWatcher = mailWatcher,
            let calendarWatcher = calendarWatcher,
            let localStore = localStore,
            let logger = logger,
            let config = config,
            let webSocketPublisher = webSocketPublisher
        else {
            return
        }
        startSyncRuntime(
            coordinator: coordinator,
            mailWatcher: mailWatcher,
            calendarWatcher: calendarWatcher,
            logger: logger,
            config: config,
            localStore: localStore,
            webSocketPublisher: webSocketPublisher
        )
        updateMenu()
    }

    private func startSyncRuntime(
        coordinator: SyncCoordinator,
        mailWatcher: MailWatcher,
        calendarWatcher: CalendarWatcher,
        logger: Logger,
        config: Config,
        localStore: LocalStore,
        webSocketPublisher: WebSocketPublisher
    ) {
        guard !syncRuntimeStarted else { return }
        syncRuntimeStarted = true
        messagesSourceAvailable = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Library/Messages/chat.db")
        messagesSourceConnected = messagesSourceAvailable

        webSocketPublisher.connect()

        mailWatcher.startObserving { [weak self] in
            Task {
                guard let self else { return }
                guard self.syncActivated else { return }
                await self.syncCoordinator?.runMailSync()
                await MainActor.run {
                    self.mailProcessedToday += 1
                    self.updateMenu()
                }
            }
        }

        calendarWatcher.startObserving { [weak self] in
            Task {
                guard let self else { return }
                guard self.syncActivated else { return }
                await self.syncCoordinator?.runCalendarSync()
                await MainActor.run {
                    self.calendarSynced += 1
                    self.updateMenu()
                }
            }
        }

        let messagesReader = MessagesReader(
            localStore: localStore,
            logger: logger,
            accountId: config.accountId,
            workspaceId: config.workspaceId
        )
        self.messagesReader = messagesReader
        messagesReader.start(onChange: { [weak self] payload in
            Task {
                guard let self else { return }
                guard self.syncActivated else { return }
                await self.syncCoordinator?.publishRawPayload(type: "message", json: payload)
                await MainActor.run {
                    self.updateMenu()
                }
            }
        }, onProgress: { [weak self] progress in
            Task { @MainActor in
                guard let self else { return }
                self.messagesTotal += progress.messages
                self.messageBatchCount += progress.batches
                let connectedMessageSources = self.messagesSourceConnected ? 1 : 0
                let availableMessageSources = self.messagesSourceAvailable ? 1 : 0
                self.messagesStatusDisplay = "Sources \(connectedMessageSources)/\(availableMessageSources) | \(self.syncDisplay) | Total \(self.messagesTotal)"
                self.updateMenu()
            }
        })

        Task {
            let names = await mailWatcher.accountNames()
            await MainActor.run {
                self.mailAccountNames = names
                self.localStore?.upsertMailAccounts(names)
                self.knownMailAccountNames = self.localStore?.knownMailAccounts() ?? names
                self.updateMenu()
            }
        }

        Task {
            do {
                let names = try await calendarWatcher.calendarSourceNames()
                await MainActor.run {
                    self.calendarSourceNames = names
                    self.localStore?.upsertCalendarSources(names)
                    self.knownCalendarSourceNames = self.localStore?.knownCalendarSources() ?? names
                    self.updateMenu()
                }
            } catch {
                await MainActor.run {
                    self.calendarSourceNames = []
                    self.calendarStatusDisplay = "Sources 0/\(max(self.knownCalendarSourceNames.count, 0)) | Access denied"
                    self.updateMenu()
                }
            }
        }

        bootstrapTask = Task.detached {
            await coordinator.runInitialBootstrapSyncIfNeeded()
            await coordinator.runMailSync()
            await coordinator.runCalendarSync()
        }
    }

    private func stopSyncRuntime() {
        guard syncRuntimeStarted else { return }
        syncRuntimeStarted = false

        bootstrapTask?.cancel()
        bootstrapTask = nil
        mailWatcher?.stopObserving()
        calendarWatcher?.stopObserving()
        messagesReader?.stop()
        messagesSourceConnected = false
        webSocketPublisher?.disconnect()
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
