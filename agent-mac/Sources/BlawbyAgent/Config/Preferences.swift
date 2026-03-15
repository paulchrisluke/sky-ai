import Foundation

struct Preferences {
    let workerUrl: String?
    let apiKey: String?
    let workspaceId: String?
    let accountId: String?
    let openaiApiKey: String?

    static func load(config: Config) -> Preferences {
        let defaults = UserDefaults.standard
        let workerUrl = defaults.string(forKey: "workerUrl")
        let apiKey = defaults.string(forKey: "apiKey")
        let workspaceId = defaults.string(forKey: "workspaceId")
        let accountId = defaults.string(forKey: "accountId")
        let openaiApiKey = defaults.string(forKey: "openaiApiKey")
            ?? config.openaiApiKey
            ?? ProcessInfo.processInfo.environment["OPENAI_API_KEY"]
        return Preferences(
            workerUrl: workerUrl,
            apiKey: apiKey,
            workspaceId: workspaceId,
            accountId: accountId,
            openaiApiKey: openaiApiKey
        )
    }
}
