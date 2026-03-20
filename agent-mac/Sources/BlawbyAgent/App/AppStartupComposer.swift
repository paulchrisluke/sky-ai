import Foundation

struct AppStartupContext {
    let logger: Logger
    let localStore: LocalStore
    let config: Config
    let contactsReader: ContactsReader
    let mailWatcher: MailWatcher
    let calendarWatcher: CalendarWatcher
    let webSocketPublisher: WebSocketPublisher
    let sourceManager: SourceManager
    let syncCoordinator: SyncCoordinator
    let syncActivated: Bool
}

final class AppStartupComposer {
    func compose() throws -> AppStartupContext {
        let baseDir = resolveBlawbyHome()
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        let logger = try Logger(baseDirectory: baseDir)
        let localStore = try LocalStore(dbPath: baseDir.appendingPathComponent("blawby.db").path)
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
        localStore.seedSyncMetricsIfNeeded(accountId: config.accountId)

        let defaults = UserDefaults.standard
        if defaults.object(forKey: Preferences.Keys.syncActivated) == nil {
            defaults.set(true, forKey: Preferences.Keys.syncActivated)
        }
        let syncActivated = defaults.bool(forKey: Preferences.Keys.syncActivated)
        logger.info("sync activated preference loaded: \(syncActivated)")

        let contactsReader = ContactsReader(localStore: localStore, logger: logger)
        let extractor = EntityExtractor(apiKey: config.openaiApiKey, contactsReader: contactsReader, logger: logger)
        let mailProcessor = MailProcessor(extractor: extractor, logger: logger)
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
        let syncCoordinator = SyncCoordinator(
            config: config,
            localStore: localStore,
            webSocketPublisher: webSocketPublisher,
            sourceManager: sourceManager,
            logger: logger
        )

        return AppStartupContext(
            logger: logger,
            localStore: localStore,
            config: config,
            contactsReader: contactsReader,
            mailWatcher: mailWatcher,
            calendarWatcher: calendarWatcher,
            webSocketPublisher: webSocketPublisher,
            sourceManager: sourceManager,
            syncCoordinator: syncCoordinator,
            syncActivated: syncActivated
        )
    }
}
