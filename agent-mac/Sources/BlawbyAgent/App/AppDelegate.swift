import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    private var uiController: AppUIController?
    private var runtimeController: SyncRuntimeController?

    private var logger: Logger?
    private var localStore: LocalStore?
    private var syncCoordinator: SyncCoordinator?
    private var sourceManager: SourceManager?
    private var contactsReader: ContactsReader?
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
            let runtimeDeps = SyncRuntimeController.Dependencies(
                syncCoordinator: coordinator,
                sourceManager: sourceManager,
                mailWatcher: mailWatcher,
                calendarWatcher: calendarWatcher,
                logger: logger,
                config: config,
                localStore: localStore,
                webSocketPublisher: webSocketPublisher,
                isSyncEnabled: { [weak self] in
                    self?.syncActivated == true
                }
            )
            let runtimeController = SyncRuntimeController(dependencies: runtimeDeps)
            runtimeController.onMenuRefresh = { [weak self] in
                self?.updateMenu()
            }
            runtimeController.onMailChange = { [weak self] in
                guard let self else { return }
                self.mailProcessedToday += 1
            }
            runtimeController.onCalendarChange = { [weak self] in
                guard let self else { return }
                self.calendarSynced += 1
            }
            runtimeController.onMessagesAvailabilityChanged = { [weak self] available, connected in
                guard let self else { return }
                self.messagesSourceAvailable = available
                self.messagesSourceConnected = connected
            }
            runtimeController.onMailAccountNamesChanged = { [weak self] names in
                guard let self else { return }
                self.mailAccountNames = names
                self.knownMailAccountNames = names
            }
            runtimeController.onCalendarSourceNamesChanged = { [weak self] names in
                guard let self else { return }
                self.calendarSourceNames = names
                self.knownCalendarSourceNames = names
            }
            runtimeController.onCalendarSourceDiscoveryFailed = { [weak self] in
                guard let self else { return }
                self.calendarSourceNames = []
                self.calendarStatusDisplay = "Sources 0/\(max(self.knownCalendarSourceNames.count, 0)) | Synced 0/0"
            }
            runtimeController.onMessagesProgress = { [weak self] progress in
                guard let self else { return }
                self.messagesTotal += progress.messages
                self.messageBatchCount += progress.batches
            }
            self.runtimeController = runtimeController

            if syncActivated {
                runtimeController.start()
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
            runtimeController?.stop()
            connectionDisplay = "Paused"
            syncDisplay = "Off"
            syncProgressDisplay = nil
            updateMenu()
            return
        }

        runtimeController?.start()
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

    private func syncProgress(from metrics: SyncMetrics) -> (synced: Int, total: Int) {
        let synced = max(0, metrics.sent)
        let total = max(metrics.discovered, metrics.processed, metrics.sent + metrics.queued + metrics.failed)
        return (synced, max(total, synced))
    }

}
