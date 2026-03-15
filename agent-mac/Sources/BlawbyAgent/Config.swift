import Foundation

struct Config: Codable {
    let workerUrl: String
    let apiKey: String
    let workspaceId: String
    let accountId: String
    var lastSeenDate: Date?
}

enum ConfigError: Error, LocalizedError {
    case missing(URL)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .missing(url):
            return "Missing config at \(url.path). Create ~/.blawby/config.json first."
        case let .invalid(reason):
            return "Invalid config.json: \(reason)"
        }
    }
}

final class ConfigStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "com.blawby.agent.config")
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder
    private var cached: Config

    init(baseDirectory: URL) throws {
        self.fileURL = baseDirectory.appendingPathComponent("config.json")
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ConfigError.missing(fileURL)
        }

        let data = try Data(contentsOf: fileURL)
        do {
            self.cached = try decoder.decode(Config.self, from: data)
        } catch {
            throw ConfigError.invalid(error.localizedDescription)
        }
    }

    func load() -> Config {
        queue.sync { cached }
    }

    func updateLastSeenDate(_ date: Date) throws {
        try queue.sync {
            cached.lastSeenDate = date
            let data = try encoder.encode(cached)
            let dir = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        }
    }
}
