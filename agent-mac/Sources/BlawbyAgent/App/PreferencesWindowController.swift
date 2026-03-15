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
        let content = NSView()

        let labels = ["Worker URL", "API Key", "Workspace ID", "Account ID", "OpenAI API Key"]
        let fields: [NSView] = [workerField, apiKeyField, workspaceField, accountField, openAIField]

        var labelFields: [NSTextField] = []
        let rows: [[NSView]] = zip(labels, fields).map { label, field in
            let labelField = NSTextField(labelWithString: label)
            labelField.alignment = .right
            labelField.translatesAutoresizingMaskIntoConstraints = false
            field.translatesAutoresizingMaskIntoConstraints = false
            labelFields.append(labelField)
            return [labelField, field]
        }

        let formGrid = NSGridView(views: rows)
        formGrid.translatesAutoresizingMaskIntoConstraints = false
        formGrid.rowSpacing = 12
        formGrid.columnSpacing = 12
        formGrid.column(at: 0).xPlacement = .trailing
        formGrid.column(at: 1).xPlacement = .fill

        let saveButton = NSButton(title: "Save", target: self, action: #selector(save))
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(formGrid)
        content.addSubview(saveButton)

        var constraints: [NSLayoutConstraint] = [
            formGrid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            formGrid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            formGrid.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            saveButton.topAnchor.constraint(greaterThanOrEqualTo: formGrid.bottomAnchor, constant: 20),
            saveButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            saveButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            workerField.widthAnchor.constraint(greaterThanOrEqualToConstant: 320)
        ]
        if let firstLabel = labelFields.first {
            constraints.append(firstLabel.widthAnchor.constraint(equalToConstant: 160))
            for labelField in labelFields.dropFirst() {
                constraints.append(labelField.widthAnchor.constraint(equalTo: firstLabel.widthAnchor))
            }
        }
        NSLayoutConstraint.activate(constraints)

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
