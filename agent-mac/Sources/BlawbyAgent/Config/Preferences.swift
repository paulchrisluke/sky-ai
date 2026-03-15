import Foundation

struct Preferences {
    enum Keys {
        static let workerUrl = "workerUrl"
        static let workspaceId = "workspaceId"
        static let accountId = "accountId"
        static let syncActivated = "syncActivated"
        static let legacyApiKey = "apiKey"
        static let legacyOpenAI = "openaiApiKey"
        static let keychainAPIKey = "workerApiKey"
        static let keychainOpenAI = "openaiApiKey"
    }

    let workerUrl: String?
    let apiKey: String?
    let workspaceId: String?
    let accountId: String?
    let openaiApiKey: String?

    static func load(config: Config) throws -> Preferences {
        let defaults = UserDefaults.standard
        let keychain = KeychainStore()

        // Migrate existing secrets from UserDefaults to Keychain.
        if let legacyAPI = defaults.string(forKey: Keys.legacyApiKey), !legacyAPI.isEmpty {
            try keychain.write(legacyAPI, account: Keys.keychainAPIKey)
            defaults.removeObject(forKey: Keys.legacyApiKey)
        }
        if let legacyOpenAI = defaults.string(forKey: Keys.legacyOpenAI), !legacyOpenAI.isEmpty {
            try keychain.write(legacyOpenAI, account: Keys.keychainOpenAI)
            defaults.removeObject(forKey: Keys.legacyOpenAI)
        }

        let workerUrl = defaults.string(forKey: Keys.workerUrl)
        let workspaceId = defaults.string(forKey: Keys.workspaceId)
        let accountId = defaults.string(forKey: Keys.accountId)
        let apiKey = try keychain.read(Keys.keychainAPIKey)
            ?? ProcessInfo.processInfo.environment["WORKER_API_KEY"]
            ?? config.apiKey
        let openaiApiKey = try keychain.read(Keys.keychainOpenAI)
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
            ?? config.openaiApiKey

        return Preferences(
            workerUrl: workerUrl,
            apiKey: apiKey,
            workspaceId: workspaceId,
            accountId: accountId,
            openaiApiKey: openaiApiKey
        )
    }
}
