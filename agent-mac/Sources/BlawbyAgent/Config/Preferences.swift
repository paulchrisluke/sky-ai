import Foundation

struct Preferences {
    let openaiApiKey: String?

    static func load(config: Config) -> Preferences {
        if let stored = UserDefaults.standard.string(forKey: "openaiApiKey"), !stored.isEmpty {
            return Preferences(openaiApiKey: stored)
        }
        if let fromConfig = config.openaiApiKey, !fromConfig.isEmpty {
            return Preferences(openaiApiKey: fromConfig)
        }
        if let envValue = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envValue.isEmpty {
            return Preferences(openaiApiKey: envValue)
        }
        return Preferences(openaiApiKey: nil)
    }
}
