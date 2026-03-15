import Foundation

struct Config: Codable {
    let workerUrl: String
    let apiKey: String
    let workspaceId: String
    let accountId: String
    let openaiApiKey: String?
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
    private var cached: Config

    init(baseDirectory: URL) throws {
        self.fileURL = baseDirectory.appendingPathComponent("config.json")
        self.decoder = JSONDecoder()

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ConfigError.missing(fileURL)
        }

        let data = try Data(contentsOf: fileURL)
        do {
            let raw = try decoder.decode(Config.self, from: data)
            // Normalize accountId
            self.cached = Config(
                workerUrl: raw.workerUrl,
                apiKey: raw.apiKey,
                workspaceId: raw.workspaceId,
                accountId: ConfigStore.normalizeAccountId(raw.accountId),
                openaiApiKey: raw.openaiApiKey
            )
        } catch {
            throw ConfigError.invalid(error.localizedDescription)
        }
    }

    static func normalizeAccountId(_ id: String) -> String {
        if id.contains("_") && !id.contains("@") {
            let lower = id.lowercased()
            let suffixes = ["_com", "_net", "_org", "_me", "_mac", "_earth", "_co_uk", "_gov", "_edu", "_io"]
            for suffix in suffixes {
                if lower.hasSuffix(suffix) {
                    let parts = id.components(separatedBy: "_")
                    if parts.count >= 3 {
                        if suffix == "_co_uk" && parts.count >= 4 {
                            let user = parts.prefix(parts.count - 3).joined(separator: "_")
                            return "\(user)@\(parts[parts.count-3]).co.uk"
                        } else if suffix != "_co_uk" {
                            let tld = parts.last!
                            let domain = parts[parts.count - 2]
                            let user = parts.prefix(parts.count - 2).joined(separator: "_")
                            return "\(user)@\(domain).\(tld)"
                        }
                    }
                }
            }
        }
        return id
    }

    func load() -> Config {
        queue.sync { cached }
    }
}
