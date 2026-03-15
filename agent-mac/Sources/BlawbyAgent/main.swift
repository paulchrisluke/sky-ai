import Foundation

func resolveBlawbyHome() -> URL {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return home.appendingPathComponent(".blawby", isDirectory: true)
}

let baseDir = resolveBlawbyHome()

do {
    try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
    let logger = try Logger(baseDirectory: baseDir)
    let configStore = try ConfigStore(baseDirectory: baseDir)
    let config = configStore.load()

    logger.info("starting BlawbyAgent")

    let webSocket = AgentWebSocketClient(config: config, logger: logger)

    let calendarWatcher = CalendarWatcher(config: config, logger: logger) { payload in
        webSocket.enqueue(payload)
    }

    let mailWatcher = MailWatcher(configStore: configStore, logger: logger) { payload in
        webSocket.enqueue(payload)
    }

    webSocket.connect()
    calendarWatcher.start()
    mailWatcher.start()

    RunLoop.main.run()
} catch {
    fputs("BlawbyAgent startup failed: \(error.localizedDescription)\n", stderr)
    exit(1)
}
