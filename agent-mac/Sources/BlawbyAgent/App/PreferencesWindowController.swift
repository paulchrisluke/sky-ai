import AppKit

final class PreferencesWindowController: NSWindowController {
    private let workerField = NSTextField(string: "")
    private let apiKeyField = NSSecureTextField(string: "")
    private let workspaceField = NSTextField(string: "")
    private let accountField = NSTextField(string: "")
    private let openAIField = NSSecureTextField(string: "")

    convenience init(config: Config) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        setup(config: config)
    }

    private func setup(config: Config) {
        guard let content = window?.contentView else { return }
        window?.title = "Blawby Preferences"

        workerField.stringValue = config.workerUrl
        apiKeyField.stringValue = config.apiKey
        workspaceField.stringValue = config.workspaceId
        accountField.stringValue = config.accountId
        openAIField.stringValue = config.openaiApiKey ?? ""

        let labels = ["Worker URL", "API Key", "Workspace ID", "Account ID", "OpenAI API Key"]
        let fields: [NSView] = [workerField, apiKeyField, workspaceField, accountField, openAIField]

        var y = 230.0
        for (index, label) in labels.enumerated() {
            let labelField = NSTextField(labelWithString: label)
            labelField.frame = NSRect(x: 20, y: y, width: 140, height: 24)
            content.addSubview(labelField)

            let field = fields[index]
            field.frame = NSRect(x: 170, y: y - 2, width: 320, height: 24)
            content.addSubview(field)
            y -= 40
        }

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.frame = NSRect(x: 420, y: 16, width: 80, height: 30)
        content.addSubview(saveButton)
    }

    @objc private func save() {
        UserDefaults.standard.set(workerField.stringValue, forKey: "workerUrl")
        UserDefaults.standard.set(apiKeyField.stringValue, forKey: "apiKey")
        UserDefaults.standard.set(workspaceField.stringValue, forKey: "workspaceId")
        UserDefaults.standard.set(accountField.stringValue, forKey: "accountId")
        UserDefaults.standard.set(openAIField.stringValue, forKey: "openaiApiKey")
        close()
    }
}
