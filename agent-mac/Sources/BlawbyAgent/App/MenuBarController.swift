import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let setSyncEnabledHandler: @MainActor (Bool) -> Void
    private let preferencesHandler: () -> Void

    private let syncToggleMenuItem = NSMenuItem(title: "Sync: Off", action: #selector(syncToggleAction), keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "Connection: Connecting", action: nil, keyEquivalent: "")
    private let issuesItem = NSMenuItem(title: "Issues: None", action: nil, keyEquivalent: "")

    private let mailGroupItem = NSMenuItem(title: "Mail", action: nil, keyEquivalent: "")
    private let calendarGroupItem = NSMenuItem(title: "Calendar", action: nil, keyEquivalent: "")
    private let messagesGroupItem = NSMenuItem(title: "Messages", action: nil, keyEquivalent: "")
    private let mailDetailsMenu = NSMenu()
    private let calendarDetailsMenu = NSMenu()
    private let messagesDetailsMenu = NSMenu()

    private let lastSyncItem = NSMenuItem(title: "Last sync: -", action: nil, keyEquivalent: "")
    private let todayTotalsItem = NSMenuItem(title: "Today: Mail 0  Calendar 0", action: nil, keyEquivalent: "")

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
            } else {
                button.title = "Blawby"
            }
        }

        syncToggleMenuItem.target = self
        configureReadOnly(syncToggleMenuItem, symbolName: "arrow.triangle.2.circlepath")
        menu.addItem(syncToggleMenuItem)

        configureReadOnly(connectionItem, symbolName: "network")
        menu.addItem(connectionItem)

        configureReadOnly(issuesItem, symbolName: "exclamationmark.triangle")
        menu.addItem(issuesItem)

        menu.addItem(.separator())

        configureDetailsItem(mailGroupItem, symbolName: "envelope")
        mailGroupItem.submenu = mailDetailsMenu
        menu.addItem(mailGroupItem)

        configureDetailsItem(calendarGroupItem, symbolName: "calendar")
        calendarGroupItem.submenu = calendarDetailsMenu
        menu.addItem(calendarGroupItem)

        configureDetailsItem(messagesGroupItem, symbolName: "message")
        messagesGroupItem.submenu = messagesDetailsMenu
        menu.addItem(messagesGroupItem)

        menu.addItem(.separator())

        menu.addItem(lastSyncItem)
        menu.addItem(todayTotalsItem)

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
        mailProcessed: Int,
        calendarSynced: Int,
        connection: String,
        syncState: String,
        syncProgress: Int?,
        mailStatus: String,
        calendarStatus: String,
        messagesStatus: String,
        connectedMailAccounts: [String],
        knownMailAccounts: [String],
        connectedCalendarSources: [String],
        knownCalendarSources: [String],
        messagesSourceConnected: Bool,
        messagesSourceAvailable: Bool,
        syncActivated: Bool
    ) {
        lastSyncItem.title = "Last sync: \(lastSync)"
        todayTotalsItem.title = "Today: Mail \(mailProcessed)  Calendar \(calendarSynced)"
        connectionItem.title = "Connection: \(connection)"

        setLeadingTrailingTitle(
            item: syncToggleMenuItem,
            leading: "Sync: \(syncState)",
            trailing: syncProgress.map { "\($0)%" } ?? "—"
        )
        syncToggleMenuItem.state = syncActivated ? .on : .off
        if let image = NSImage(systemSymbolName: syncActivated ? "arrow.triangle.2.circlepath.circle.fill" : "pause.circle", accessibilityDescription: nil) {
            image.isTemplate = true
            syncToggleMenuItem.image = image
        }

        mailGroupItem.title = "Mail: \(mailStatus)"
        calendarGroupItem.title = "Calendar: \(calendarStatus)"
        messagesGroupItem.title = "Messages: \(messagesStatus)"

        updateIssuesItem(
            connectedMailAccounts: connectedMailAccounts,
            knownMailAccounts: knownMailAccounts,
            connectedCalendarSources: connectedCalendarSources,
            knownCalendarSources: knownCalendarSources,
            messagesSourceConnected: messagesSourceConnected,
            messagesSourceAvailable: messagesSourceAvailable
        )

        updateDetailsMenus(
            mailStatus: mailStatus,
            calendarStatus: calendarStatus,
            messagesStatus: messagesStatus,
            connectedMailAccounts: connectedMailAccounts,
            knownMailAccounts: knownMailAccounts,
            connectedCalendarSources: connectedCalendarSources,
            knownCalendarSources: knownCalendarSources,
            messagesSourceConnected: messagesSourceConnected,
            messagesSourceAvailable: messagesSourceAvailable
        )

        updateStatusIcon(connection: connection, syncState: syncState)
    }

    private func setLeadingTrailingTitle(item: NSMenuItem, leading: String, trailing: String) {
        item.attributedTitle = NSAttributedString(string: "\(leading)\t\(trailing)")
    }

    private func updateDetailsMenus(
        mailStatus: String,
        calendarStatus: String,
        messagesStatus: String,
        connectedMailAccounts: [String],
        knownMailAccounts: [String],
        connectedCalendarSources: [String],
        knownCalendarSources: [String],
        messagesSourceConnected: Bool,
        messagesSourceAvailable: Bool
    ) {
        rebuildDetailsMenu(
            menu: mailDetailsMenu,
            summary: mailStatus,
            connected: connectedMailAccounts,
            known: knownMailAccounts,
            connectedSymbol: "person.crop.circle.badge.checkmark",
            disconnectedSymbol: "person.crop.circle.badge.xmark"
        )
        rebuildDetailsMenu(
            menu: calendarDetailsMenu,
            summary: calendarStatus,
            connected: connectedCalendarSources,
            known: knownCalendarSources,
            connectedSymbol: "calendar.badge.checkmark",
            disconnectedSymbol: "calendar.badge.exclamationmark"
        )

        messagesDetailsMenu.removeAllItems()
        let messagesSummary = NSMenuItem(title: messagesStatus, action: nil, keyEquivalent: "")
        messagesSummary.isEnabled = false
        messagesDetailsMenu.addItem(messagesSummary)
        messagesDetailsMenu.addItem(.separator())

        if messagesSourceAvailable {
            let status = messagesSourceConnected ? "Connected" : "Disconnected"
            let symbol = messagesSourceConnected ? "checkmark.circle.fill" : "exclamationmark.circle"
            let row = NSMenuItem(title: "Messages DB | \(status)", action: nil, keyEquivalent: "")
            row.isEnabled = true
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                image.isTemplate = true
                row.image = image
            }
            messagesDetailsMenu.addItem(row)
        } else {
            let row = NSMenuItem(title: "Messages DB unavailable", action: nil, keyEquivalent: "")
            row.isEnabled = false
            messagesDetailsMenu.addItem(row)
        }
    }

    private func rebuildDetailsMenu(
        menu detailsMenu: NSMenu,
        summary: String,
        connected: [String],
        known: [String],
        connectedSymbol: String,
        disconnectedSymbol: String
    ) {
        detailsMenu.removeAllItems()

        let summaryItem = NSMenuItem(title: summary, action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        detailsMenu.addItem(summaryItem)
        detailsMenu.addItem(.separator())

        let connectedSet = Set(connected)
        let all = known.isEmpty ? connected : known
        if all.isEmpty {
            let empty = NSMenuItem(title: "No sources found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            detailsMenu.addItem(empty)
            return
        }

        let disconnectedRows = all.filter { !connectedSet.contains($0) }
        let connectedRows = all.filter { connectedSet.contains($0) }
        let ordered = disconnectedRows + connectedRows

        for name in ordered {
            let isConnected = connectedSet.contains(name)
            let status = isConnected ? "Connected" : "Disconnected"
            let item = NSMenuItem(title: "\(name) | \(status)", action: nil, keyEquivalent: "")
            item.isEnabled = true
            let symbol = isConnected ? connectedSymbol : disconnectedSymbol
            if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
                image.isTemplate = true
                item.image = image
            }
            detailsMenu.addItem(item)
        }
    }

    private func updateIssuesItem(
        connectedMailAccounts: [String],
        knownMailAccounts: [String],
        connectedCalendarSources: [String],
        knownCalendarSources: [String],
        messagesSourceConnected: Bool,
        messagesSourceAvailable: Bool
    ) {
        let mailKnown = knownMailAccounts.isEmpty ? connectedMailAccounts.count : knownMailAccounts.count
        let calendarKnown = knownCalendarSources.isEmpty ? connectedCalendarSources.count : knownCalendarSources.count
        let mailIssues = max(0, mailKnown - connectedMailAccounts.count)
        let calendarIssues = max(0, calendarKnown - connectedCalendarSources.count)
        let messagesIssues = messagesSourceAvailable && !messagesSourceConnected ? 1 : 0
        let totalIssues = mailIssues + calendarIssues + messagesIssues

        if totalIssues == 0 {
            issuesItem.title = "Issues: None"
            return
        }
        var parts: [String] = []
        if mailIssues > 0 { parts.append("Mail \(mailIssues)") }
        if calendarIssues > 0 { parts.append("Calendar \(calendarIssues)") }
        if messagesIssues > 0 { parts.append("Messages \(messagesIssues)") }
        issuesItem.title = "Issues: " + parts.joined(separator: " • ")
    }

    private func configureReadOnly(_ item: NSMenuItem, symbolName: String) {
        item.isEnabled = true
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            item.image = image
        }
    }

    private func configureDetailsItem(_ item: NSMenuItem, symbolName: String) {
        item.isEnabled = true
        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            item.image = image
        }
    }

    private func updateStatusIcon(connection: String, syncState: String) {
        guard let button = statusItem.button else {
            return
        }

        let symbolName: String
        if connection.lowercased().hasPrefix("connected") {
            if syncState.lowercased() != "off" {
                symbolName = "arrow.triangle.2.circlepath.circle.fill"
            } else {
                symbolName = "bolt.horizontal.circle.fill"
            }
        } else if connection.lowercased().hasPrefix("reconnecting") || connection.lowercased().hasPrefix("connecting") {
            symbolName = "arrow.triangle.2.circlepath"
        } else {
            symbolName = "wifi.exclamationmark"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Blawby") {
            image.isTemplate = true
            button.image = image
            button.title = " Blawby"
            return
        }
        button.title = "Blawby"
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
