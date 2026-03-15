import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var uiController: AppUIController?

    private var logger: Logger?
    private var localStore: LocalStore?
    private var syncCoordinator: SyncCoordinator?
    private var sourceManager: SourceManager?
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
    private var syncDisplay = "Synced 0/0"
    private var syncProgressDisplay: Int?
    private var queuePendingDisplay = 0
    private var mailStatusDisplay = "Accounts 0/0 | Synced 0/0"
    private var calendarStatusDisplay = "Sources 0/0 | Synced 0/0"
    private var messagesStatusDisplay = "Sources 0/0 | Synced 0/0"
    private var dataProofDisplay = "Totals: Mail 0/0 | Calendar 0/0 | Messages 0/0"
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

    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        uiController = AppUIController()

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
                accountId: ConfigStore.normalizeAccountId(prefs.accountId ?? fileConfig.accountId),
                openaiApiKey: prefs.openaiApiKey ?? fileConfig.openaiApiKey
            )
            self.config = config
            localStore.seedSyncMetricsIfNeeded(accountId: config.accountId)
            let defaults = UserDefaults.standard
            if defaults.object(forKey: Preferences.Keys.syncActivated) == nil {
                defaults.set(true, forKey: Preferences.Keys.syncActivated)
            }
            syncActivated = defaults.bool(forKey: Preferences.Keys.syncActivated)
            logger.info("sync activated preference loaded: \(syncActivated)")

            let contactsReader = ContactsReader(localStore: localStore, logger: logger)
            self.contactsReader = contactsReader
            contactsReader.start()

            let extractor = EntityExtractor(apiKey: config.openaiApiKey, contactsReader: contactsReader, logger: logger)
            let mailProcessor = MailProcessor(localStore: localStore, extractor: extractor)
            let mailWatcher = MailWatcher(configStore: configStore, logger: logger)
            let calendarWatcher = CalendarWatcher(config: config, logger: logger)
            let webSocketPublisher = WebSocketPublisher(config: config, logger: logger)
            let sourceManager = SourceManager(
                config: config,
                localStore: localStore,
                mailWatcher: mailWatcher,
                calendarWatcher: calendarWatcher,
                mailProcessor: mailProcessor,
                webSocketPublisher: webSocketPublisher,
                logger: logger
            )
            let coordinator = SyncCoordinator(
                config: config,
                localStore: localStore,
                webSocketPublisher: webSocketPublisher,
                sourceManager: sourceManager,
                logger: logger
            )

            self.syncCoordinator = coordinator
            self.sourceManager = sourceManager
            self.mailWatcher = mailWatcher
            self.calendarWatcher = calendarWatcher
            self.webSocketPublisher = webSocketPublisher
            if let uiController {
                uiController.observeSources(sourceManager) { [weak self] in
                    self?.updateMenu()
                }

                uiController.setupMenuBar(
                    sourceManager: sourceManager,
                    setSyncEnabled: { [weak self] enabled in self?.setSyncEnabled(enabled) },
                    openDashboard: { [weak self] in self?.openDashboard() },
                    preferences: { [weak self] in self?.openPreferences() }
                )
            }

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
                    sourceManager: sourceManager,
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
            refreshDataProofDisplay()
            updateMenu()

            configureLoginItemRegistration(logger: logger)
        } catch {
            fputs("BlawbyAgent startup failed: \(error.localizedDescription)\n", stderr)
        }
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
    }

    @MainActor
    private func applySyncSnapshot(_ snapshot: SyncStatusSnapshot) {
        if !syncActivated {
            syncDisplay = "Off"
            syncProgressDisplay = nil
            updateMenu()
            return
        }

        if let lastSync = snapshot.lastSyncAt {
            lastSyncDisplay = iso.string(from: lastSync)
        }

        queuePendingDisplay = snapshot.pendingPayloads
        let connectedAccounts = mailAccountNames.count
        let availableAccounts = max(knownMailAccountNames.count, connectedAccounts)
        let bootstrapActive = snapshot.bootstrapStatus.contains("mail backfill active")
        let bootstrapPercent = max(0, min(100, snapshot.mailBootstrapPercent))
        let connectedCalendars = calendarSourceNames.count
        let availableCalendars = max(knownCalendarSourceNames.count, connectedCalendars)
        let connectedMessageSources = messagesSourceConnected ? 1 : 0
        let availableMessageSources = messagesSourceAvailable ? 1 : 0

        guard let localStore, let config else {
            syncDisplay = "Syncing"
            syncProgressDisplay = nil
            updateMenu()
            return
        }

        let mailMetrics = localStore.syncMetrics(accountId: config.accountId, source: "mail")
        let calendarMetrics = localStore.syncMetrics(accountId: config.accountId, source: "calendar")
        let messagesMetrics = localStore.syncMetrics(accountId: config.accountId, source: "messages")

        let mailProgress = syncProgress(from: mailMetrics)
        let calendarProgress = syncProgress(from: calendarMetrics)
        let messagesProgress = syncProgress(from: messagesMetrics)

        let totalSynced = mailProgress.synced + calendarProgress.synced + messagesProgress.synced
        let totalAvailable = mailProgress.total + calendarProgress.total + messagesProgress.total
        let computedPercent = totalAvailable > 0 ? Int((Double(totalSynced) / Double(totalAvailable) * 100.0).rounded()) : 0

        syncDisplay = "Synced \(totalSynced)/\(totalAvailable)"
        syncProgressDisplay = bootstrapActive ? max(computedPercent, bootstrapPercent) : computedPercent

        mailStatusDisplay = "Accounts \(connectedAccounts)/\(availableAccounts) | Synced \(mailProgress.synced)/\(mailProgress.total)"
        calendarStatusDisplay = "Sources \(connectedCalendars)/\(availableCalendars) | Synced \(calendarProgress.synced)/\(calendarProgress.total)"
        messagesStatusDisplay = "Sources \(connectedMessageSources)/\(availableMessageSources) | Synced \(messagesProgress.synced)/\(messagesProgress.total)"

        mailProcessedToday = mailProgress.synced
        calendarSynced = calendarProgress.synced
        refreshDataProofDisplay()
        updateMenu()
    }

    @MainActor
    private func refreshDataProofDisplay() {
        guard let localStore, let config else {
            dataProofDisplay = "Data: unavailable"
            return
        }
        let mailMetrics = localStore.syncMetrics(accountId: config.accountId, source: "mail")
        let calendarMetrics = localStore.syncMetrics(accountId: config.accountId, source: "calendar")
        let messagesMetrics = localStore.syncMetrics(accountId: config.accountId, source: "messages")
        let mail = syncProgress(from: mailMetrics)
        let calendar = syncProgress(from: calendarMetrics)
        let messages = syncProgress(from: messagesMetrics)
        let last = [
            mailMetrics.lastActivityAt,
            calendarMetrics.lastActivityAt,
            messagesMetrics.lastActivityAt
        ]
            .compactMap { $0 }
            .max()
            .map { iso.string(from: $0) } ?? "-"
        dataProofDisplay = "Totals: Mail \(mail.synced)/\(mail.total) | Calendar \(calendar.synced)/\(calendar.total) | Messages \(messages.synced)/\(messages.total) | Last \(last)"
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
        logger?.info("sync activated preference updated: \(syncActivated)")

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
            let sourceManager = sourceManager,
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
            sourceManager: sourceManager,
            mailWatcher: mailWatcher,
            calendarWatcher: calendarWatcher,
            logger: logger,
            config: config,
            localStore: localStore,
            webSocketPublisher: webSocketPublisher
        )
        updateMenu()
    }

    @MainActor
    private func startSyncRuntime(
        coordinator: SyncCoordinator,
        sourceManager: SourceManager,
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
        sourceManager.start()

        mailWatcher.startObserving { [weak self] in
            Task {
                guard let self else { return }
                guard self.syncActivated else { return }
                await MainActor.run {
                    sourceManager.markSourcesChanged(sourceType: "mail")
                }
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
                await MainActor.run {
                    sourceManager.markSourcesChanged(sourceType: "calendar")
                }
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
                    self.calendarStatusDisplay = "Sources 0/\(max(self.knownCalendarSourceNames.count, 0)) | Synced 0/0"
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

    @MainActor
    private func stopSyncRuntime() {
        guard syncRuntimeStarted else { return }
        syncRuntimeStarted = false

        bootstrapTask?.cancel()
        bootstrapTask = nil
        mailWatcher?.stopObserving()
        calendarWatcher?.stopObserving()
        messagesReader?.stop()
        messagesSourceConnected = false
        sourceManager?.stop()
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

    private func syncProgress(from metrics: SyncMetrics) -> (synced: Int, total: Int) {
        let synced = max(0, metrics.sent)
        let total = max(metrics.discovered, metrics.processed, metrics.sent + metrics.queued + metrics.failed)
        return (synced, max(total, synced))
    }

}
