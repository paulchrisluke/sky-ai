import Foundation

final class Logger: @unchecked Sendable {
    private let logURL: URL
    private let queue = DispatchQueue(label: "com.blawby.agent.logger")
    private let formatter: ISO8601DateFormatter

    init(baseDirectory: URL) throws {
        let logsDir = baseDirectory.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
        self.logURL = logsDir.appendingPathComponent("agent.log")
        self.formatter = ISO8601DateFormatter()
        self.formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func info(_ message: String) {
        write(level: "INFO", message: message)
    }

    func error(_ message: String) {
        write(level: "ERROR", message: message)
    }

    func warning(_ message: String) {
        write(level: "WARN", message: message)
    }

    private func write(level: String, message: String) {
        let timestamp = formatter.string(from: Date())
        let line = "[\(timestamp)] [\(level)] \(message)\n"
        let logURL = self.logURL
        print(line, terminator: "")

        queue.async { [logURL] in
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            guard let data = line.data(using: .utf8) else { return }
            do {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } catch {
                fputs("Logger write failed: \(error)\n", stderr)
            }
        }
    }
}
