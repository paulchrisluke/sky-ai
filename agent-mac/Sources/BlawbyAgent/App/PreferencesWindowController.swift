import AppKit
import SwiftUI

final class PreferencesWindowController: NSWindowController {
    private let workerField = NSTextField(string: "")
    private let apiKeyField = NSSecureTextField(string: "")
    private let workspaceField = NSTextField(string: "")
    private let accountField = NSTextField(string: "")
    private let openAIField = NSSecureTextField(string: "")

    convenience init(config: Config, sourceManager: SourceManager) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        setup(config: config, sourceManager: sourceManager)
    }

    private func setup(config: Config, sourceManager: SourceManager) {
        window?.title = "Blawby Preferences"

        workerField.stringValue = config.workerUrl
        apiKeyField.stringValue = config.apiKey
        workspaceField.stringValue = config.workspaceId
        accountField.stringValue = config.accountId
        openAIField.stringValue = config.openaiApiKey ?? ""

        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar

        let sourcesController = NSHostingController(rootView: SourcesView(sourceManager: sourceManager))
        let sourcesItem = NSTabViewItem(viewController: sourcesController)
        sourcesItem.label = "Sources"

        let connectionController = NSViewController()
        connectionController.view = makeConnectionView()
        let connectionItem = NSTabViewItem(viewController: connectionController)
        connectionItem.label = "Connection"

        tabs.addTabViewItem(sourcesItem)
        tabs.addTabViewItem(connectionItem)
        tabs.selectedTabViewItemIndex = 0

        window?.contentViewController = tabs
    }

    private func makeConnectionView() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 420))

        let labels = ["Worker URL", "API Key", "Workspace ID", "Account ID", "OpenAI API Key"]
        let fields: [NSView] = [workerField, apiKeyField, workspaceField, accountField, openAIField]

        var y = 330.0
        for (index, label) in labels.enumerated() {
            let labelField = NSTextField(labelWithString: label)
            labelField.frame = NSRect(x: 24, y: y, width: 160, height: 24)
            content.addSubview(labelField)

            let field = fields[index]
            field.frame = NSRect(x: 190, y: y - 2, width: 400, height: 24)
            content.addSubview(field)
            y -= 44
        }

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.frame = NSRect(x: 510, y: 22, width: 80, height: 30)
        content.addSubview(saveButton)

        return content
    }

    @objc private func save() {
        let defaults = UserDefaults.standard
        defaults.set(workerField.stringValue, forKey: Preferences.Keys.workerUrl)
        defaults.set(workspaceField.stringValue, forKey: Preferences.Keys.workspaceId)
        defaults.set(accountField.stringValue, forKey: Preferences.Keys.accountId)

        let keychain = KeychainStore()
        do {
            let apiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if apiKey.isEmpty {
                try keychain.delete(Preferences.Keys.keychainAPIKey)
            } else {
                try keychain.write(apiKey, account: Preferences.Keys.keychainAPIKey)
            }

            let openAI = openAIField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if openAI.isEmpty {
                try keychain.delete(Preferences.Keys.keychainOpenAI)
            } else {
                try keychain.write(openAI, account: Preferences.Keys.keychainOpenAI)
            }
            close()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "Failed to save secrets"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}
