import Foundation

func resolveBlawbyHome() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".blawby", isDirectory: true)
}

let baseDir = resolveBlawbyHome()

do {
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let logger = try Logger(baseDirectory: baseDir)
    let localStore = try LocalStore(baseDirectory: baseDir)
    let configStore = try ConfigStore(baseDirectory: baseDir)
    let config = configStore.load()
    let preferences = Preferences.load(config: config)
    let entityExtractor = EntityExtractor(apiKey: preferences.openaiApiKey, logger: logger)
    let mailProcessor = MailProcessor(localStore: localStore, extractor: entityExtractor)
    let mailWatcher = MailWatcher(configStore: configStore, localStore: localStore, logger: logger)
    let calendarWatcher = CalendarWatcher(config: config, localStore: localStore, logger: logger)

    logger.info("starting BlawbyAgent")

    let webSocketPublisher = WebSocketPublisher(config: config, logger: logger)
    let syncCoordinator = SyncCoordinator(
        config: config,
        localStore: localStore,
        webSocketPublisher: webSocketPublisher,
        mailWatcher: mailWatcher,
        mailProcessor: mailProcessor,
        calendarWatcher: calendarWatcher,
        logger: logger
    )

    webSocketPublisher.onConnected = {
        Task { await syncCoordinator.drainOutboundQueue() }
    }
    webSocketPublisher.connect()

    Task { await syncCoordinator.runMailSync() }
    Task { await syncCoordinator.runCalendarSync() }

    let mailTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    mailTimer.schedule(deadline: .now() + 120, repeating: 120)
    mailTimer.setEventHandler {
        Task { await syncCoordinator.runMailSync() }
    }
    mailTimer.resume()

    let calendarTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    calendarTimer.schedule(deadline: .now() + 900, repeating: 900)
    calendarTimer.setEventHandler {
        Task { await syncCoordinator.runCalendarSync() }
    }
    calendarTimer.resume()

    RunLoop.main.run()
} catch {
    fputs("BlawbyAgent startup failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
