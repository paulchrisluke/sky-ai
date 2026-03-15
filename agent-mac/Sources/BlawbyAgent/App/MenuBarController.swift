import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let setSyncEnabledHandler: @MainActor (Bool) -> Void
    private let preferencesHandler: () -> Void

    private let syncToggleMenuItem = NSMenuItem(title: "Sync: Off", action: #selector(syncToggleAction), keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "Connection: Connecting", action: nil, keyEquivalent: "")
    private let topStatusItem = NSMenuItem(title: "✓ All current", action: nil, keyEquivalent: "")
    private let lastSyncItem = NSMenuItem(title: "Last sync: -", action: nil, keyEquivalent: "")

    private let sourcesSectionMarker = NSMenuItem.separator()
    private let footerSeparator = NSMenuItem.separator()

    private var sourceItems: [NSMenuItem] = []

    init(setSyncEnabled: @escaping @MainActor (Bool) -> Void, preferences: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.setSyncEnabledHandler = setSyncEnabled
        self.preferencesHandler = preferences
        super.init()
        setup()
    }

    private func setup() {
        menu.autoenablesItems = false

        if let button = statusItem.button {
            button.title = " Blawby"
            button.imagePosition = .imageLeading
            if let image = NSImage(systemSymbolName: "bolt.horizontal.circle.fill", accessibilityDescription: "Blawby") {
                image.isTemplate = true
                button.image = image
            }
        }

        syncToggleMenuItem.target = self
        menu.addItem(syncToggleMenuItem)

        connectionItem.isEnabled = false
        menu.addItem(connectionItem)

        topStatusItem.isEnabled = false
        menu.addItem(topStatusItem)

        menu.addItem(.separator())
        menu.addItem(sourcesSectionMarker)

        menu.addItem(footerSeparator)
        lastSyncItem.isEnabled = false
        menu.addItem(lastSyncItem)

        menu.addItem(.separator())
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(preferencesAction), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func update(
        lastSync: String,
        connection: String,
        syncActivated: Bool,
        sources: [ConnectedSource]
    ) {
        connectionItem.title = "Connection: \(connection)"
        syncToggleMenuItem.title = syncActivated ? "Sync: On" : "Sync: Off"
        syncToggleMenuItem.state = syncActivated ? .on : .off
        lastSyncItem.title = "Last sync: \(lastSync)"

        rebuildSourceRows(sources)
        topStatusItem.title = topStatusTitle(for: sources)

        updateStatusIcon(connection: connection, topStatus: topStatusItem.title)
    }

    private func rebuildSourceRows(_ sources: [ConnectedSource]) {
        for item in sourceItems {
            menu.removeItem(item)
        }
        sourceItems.removeAll()

        // Show a summary instead of detailed source list in menu bar
        let enabled = sources.filter(\.enabled)
        let total = sources.count
        
        let summaryItem = NSMenuItem(
            title: "\(enabled.count) of \(total) sources enabled", 
            action: nil, 
            keyEquivalent: ""
        )
        summaryItem.isEnabled = false
        insertSourceItem(summaryItem)
    }

    private func insertSourceItem(_ item: NSMenuItem) {
        let index = menu.index(of: footerSeparator)
        menu.insertItem(item, at: index)
        sourceItems.append(item)
    }

    private func topStatusTitle(for sources: [ConnectedSource]) -> String {
        let enabled = sources.filter(\.enabled)
        if enabled.isEmpty {
            return "⏸ No sources enabled"
        }

        let errorCount = enabled.filter { $0.status == "error" }.count
        if errorCount > 0 {
            return "⚠ \(errorCount) errors"
        }

        let syncing = enabled.contains { $0.status == "syncing" }
        if syncing {
            let x = enabled.reduce(0) { $0 + max(0, $1.totalSynced) }
            let y = enabled.reduce(0) { $0 + max(0, $1.totalEstimated) }
            return "Syncing… \(formatNumber(x)) / \(formatNumber(y))"
        }

        if enabled.allSatisfy({ $0.status == "current" }) {
            return "✓ All current"
        }

        let paused = sources.filter { !$0.enabled }.count
        if paused > 0 {
            return "⏸ \(paused) sources paused"
        }

        return "Syncing…"
    }

    private func progressText(for source: ConnectedSource) -> String {
        if !source.enabled {
            return "Paused"
        }
        if source.status == "error" {
            if let err = source.lastError, !err.isEmpty {
                return "⚠ \(err)"
            }
            return "⚠ Error"
        }
        if source.status == "current" {
            return "✓"
        }
        let synced = formatNumber(max(0, source.totalSynced))
        let estimated = formatNumber(max(0, source.totalEstimated))
        return "\(synced) / \(estimated)"
    }

    private func iconForSourceType(_ sourceType: String) -> String {
        switch sourceType {
        case "mail": return "📧"
        case "calendar": return "📅"
        case "messages": return "💬"
        default: return "•"
        }
    }

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func updateStatusIcon(connection: String, topStatus: String) {
        guard let button = statusItem.button else { return }

        let symbolName: String
        if topStatus.hasPrefix("⚠") {
            symbolName = "exclamationmark.triangle.fill"
        } else if topStatus.hasPrefix("Syncing") {
            symbolName = "arrow.triangle.2.circlepath.circle.fill"
        } else if connection.lowercased().hasPrefix("connected") {
            symbolName = "checkmark.circle.fill"
        } else if connection.lowercased().hasPrefix("reconnecting") || connection.lowercased().hasPrefix("connecting") {
            symbolName = "arrow.triangle.2.circlepath"
        } else {
            symbolName = "wifi.exclamationmark"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Blawby") {
            image.isTemplate = true
            button.image = image
            button.title = " Blawby"
        }
    }

    @objc private func syncToggleAction() {
        let enable = syncToggleMenuItem.state != .on
        setSyncEnabledHandler(enable)
    }

    @objc private func preferencesAction() {
        preferencesHandler()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
