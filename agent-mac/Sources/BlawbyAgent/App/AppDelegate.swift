import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
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
                preferences: { [weak self] in self?.openPreferences() }
            )

            webSocketPublisher.onConnected = { [weak self] in
                guard let self else { return }
                Task { await self.syncCoordinator?.drainOutboundQueue() }
            }
            webSocketPublisher.connect()

            mailWatcher.startObserving { [weak self] in
                guard let self else { return }
                Task {
                    await self.syncCoordinator?.runMailSync()
                    self.mailProcessedToday += 1
                    self.updateMenu()
                }
            }

            calendarWatcher.startObserving { [weak self] in
                guard let self else { return }
                Task {
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
                guard let self else { return }
                Task {
                    await self.syncCoordinator?.publishRawPayload(type: "message", json: payload)
                    self.updateMenu()
                }
            }

            Task { await coordinator.runMailSync() }
            Task { await coordinator.runCalendarSync() }
            updateMenu()

            do {
                try SMAppService.mainApp.register()
            } catch {
                logger.warning("SMAppService register failed: \(error.localizedDescription)")
            }
        } catch {
            fputs("BlawbyAgent startup failed: \(error.localizedDescription)\n", stderr)
        }
    }

    private func syncNow() {
        guard let syncCoordinator else { return }
        Task {
            await syncCoordinator.runMailSync()
            await syncCoordinator.runCalendarSync()
            await syncCoordinator.drainOutboundQueue()
            updateMenu()
        }
    }

    private func openPreferences() {
        guard let config else { return }
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController(config: config)
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func updateMenu() {
        let ts = iso.string(from: Date())
        menuBar?.update(lastSync: ts, mailProcessed: mailProcessedToday, calendarSynced: calendarSynced)
    }
}
