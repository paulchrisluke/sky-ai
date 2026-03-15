import Foundation

enum Preferences {
    static var openAIAPIKey: String? {
        if let stored = UserDefaults.standard.string(forKey: "OPENAI_API_KEY"), !stored.isEmpty {
            return stored
        }
        if let envValue = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !envValue.isEmpty {
            return envValue
        }
        return nil
    }
}
