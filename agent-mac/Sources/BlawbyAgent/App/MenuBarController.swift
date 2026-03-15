import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let setSyncEnabledHandler: @MainActor (Bool) -> Void
    private let preferencesHandler: () -> Void

    private let statusHeaderItem = NSMenuItem(title: "Status", action: nil, keyEquivalent: "")
    private let servicesHeaderItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
    private let activityHeaderItem = NSMenuItem(title: "Activity", action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "Connection: Connecting", action: nil, keyEquivalent: "")
    private let syncStateItem = NSMenuItem(title: "Sync: Idle", action: nil, keyEquivalent: "")
    private let issuesItem = NSMenuItem(title: "Issues: None", action: nil, keyEquivalent: "")
    private let mailStatusItem = NSMenuItem(title: "Mail: Waiting", action: nil, keyEquivalent: "")
    private let calendarStatusItem = NSMenuItem(title: "Calendar: Waiting", action: nil, keyEquivalent: "")
    private let messagesStatusItem = NSMenuItem(title: "Messages: Waiting", action: nil, keyEquivalent: "")
    private let mailDetailsItem = NSMenuItem(title: "Mail Details", action: nil, keyEquivalent: "")
    private let calendarDetailsItem = NSMenuItem(title: "Calendar Details", action: nil, keyEquivalent: "")
    private let messagesDetailsItem = NSMenuItem(title: "Messages Details", action: nil, keyEquivalent: "")
    private let lastSyncItem = NSMenuItem(title: "Last sync: -", action: nil, keyEquivalent: "")
    private let todayTotalsItem = NSMenuItem(title: "Today: Mail 0  Calendar 0", action: nil, keyEquivalent: "")
    private let mailDetailsMenu = NSMenu()
    private let calendarDetailsMenu = NSMenu()
    private let messagesDetailsMenu = NSMenu()
    private let syncToggleItem = NSMenuItem()
    private let syncSwitch = NSSwitch(frame: .zero)
    private var suppressSwitchStateUpdatesUntil: Date?

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

        menu.addItem(NSMenuItem(title: "Blawby", action: nil, keyEquivalent: ""))
        configureHeader(statusHeaderItem)
        menu.addItem(statusHeaderItem)
        configureReadOnly(connectionItem, symbolName: "network")
        menu.addItem(connectionItem)
        configureReadOnly(syncStateItem, symbolName: "arrow.triangle.2.circlepath")
        menu.addItem(syncStateItem)
        configureReadOnly(issuesItem, symbolName: "exclamationmark.triangle")
        menu.addItem(issuesItem)
        menu.addItem(.separator())
        configureHeader(servicesHeaderItem)
        menu.addItem(servicesHeaderItem)
        configureReadOnly(mailStatusItem, symbolName: "envelope")
        menu.addItem(mailStatusItem)
        configureReadOnly(calendarStatusItem, symbolName: "calendar")
        menu.addItem(calendarStatusItem)
        configureReadOnly(messagesStatusItem, symbolName: "message")
        menu.addItem(messagesStatusItem)
        configureDetailsItem(mailDetailsItem, symbolName: "chevron.right")
        mailDetailsItem.submenu = mailDetailsMenu
        menu.addItem(mailDetailsItem)
        configureDetailsItem(calendarDetailsItem, symbolName: "chevron.right")
        calendarDetailsItem.submenu = calendarDetailsMenu
        menu.addItem(calendarDetailsItem)
        configureDetailsItem(messagesDetailsItem, symbolName: "chevron.right")
        messagesDetailsItem.submenu = messagesDetailsMenu
        menu.addItem(messagesDetailsItem)
        menu.addItem(.separator())
        configureHeader(activityHeaderItem)
        menu.addItem(activityHeaderItem)
        menu.addItem(lastSyncItem)
        menu.addItem(todayTotalsItem)
        menu.addItem(.separator())

        syncToggleItem.view = buildSyncToggleRow()
        menu.addItem(syncToggleItem)

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
            item: syncStateItem,
            leading: "Sync: \(syncState)",
            trailing: syncProgress.map { "\($0)%" } ?? "—"
        )
        mailStatusItem.title = "Mail: \(mailStatus)"
        calendarStatusItem.title = "Calendar: \(calendarStatus)"
        messagesStatusItem.title = "Messages: \(messagesStatus)"
        updateIssuesItem(
            connectedMailAccounts: connectedMailAccounts,
            knownMailAccounts: knownMailAccounts,
            connectedCalendarSources: connectedCalendarSources,
            knownCalendarSources: knownCalendarSources,
            messagesSourceConnected: messagesSourceConnected,
            messagesSourceAvailable: messagesSourceAvailable
        )
        updateDetailsMenus(
            connectedMailAccounts: connectedMailAccounts,
            knownMailAccounts: knownMailAccounts,
            connectedCalendarSources: connectedCalendarSources,
            knownCalendarSources: knownCalendarSources,
            messagesSourceConnected: messagesSourceConnected,
            messagesSourceAvailable: messagesSourceAvailable
        )
        let desiredState: NSControl.StateValue = syncActivated ? .on : .off
        let now = Date()
        let suppress = suppressSwitchStateUpdatesUntil.map { now < $0 } ?? false
        if !suppress && syncSwitch.state != desiredState {
            syncSwitch.state = desiredState
        }
        updateStatusIcon(connection: connection, syncState: syncState)
    }

    private func setLeadingTrailingTitle(item: NSMenuItem, leading: String, trailing: String) {
        let full = "\(leading)\t\(trailing)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = 280
        paragraph.tabStops = [NSTextTab(textAlignment: .right, location: 280)]
        item.attributedTitle = NSAttributedString(
            string: full,
            attributes: [
                .font: NSFont.menuFont(ofSize: 0),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )
    }

    private func updateDetailsMenus(
        connectedMailAccounts: [String],
        knownMailAccounts: [String],
        connectedCalendarSources: [String],
        knownCalendarSources: [String],
        messagesSourceConnected: Bool,
        messagesSourceAvailable: Bool
    ) {
        rebuildDetailsMenu(
            menu: mailDetailsMenu,
            connected: connectedMailAccounts,
            known: knownMailAccounts,
            connectedSymbol: "person.crop.circle.badge.checkmark",
            disconnectedSymbol: "person.crop.circle.badge.xmark"
        )
        rebuildDetailsMenu(
            menu: calendarDetailsMenu,
            connected: connectedCalendarSources,
            known: knownCalendarSources,
            connectedSymbol: "calendar.badge.checkmark",
            disconnectedSymbol: "calendar.badge.exclamationmark"
        )

        messagesDetailsMenu.removeAllItems()
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
        connected: [String],
        known: [String],
        connectedSymbol: String,
        disconnectedSymbol: String
    ) {
        detailsMenu.removeAllItems()
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

    private func configureHeader(_ item: NSMenuItem) {
        item.isEnabled = true
        item.attributedTitle = NSAttributedString(
            string: item.title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
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

    private func buildSyncToggleRow() -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 30))

        let label = NSTextField(labelWithString: "Sync")
        label.font = NSFont.menuFont(ofSize: 0)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        syncSwitch.target = self
        syncSwitch.action = #selector(syncSwitchChanged(_:))
        syncSwitch.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(syncSwitch)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            syncSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            syncSwitch.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])

        return container
    }

    private func updateStatusIcon(connection: String, syncState: String) {
        guard let button = statusItem.button else {
            return
        }

        let symbolName: String
        if connection.lowercased().hasPrefix("connected") {
            if syncState.lowercased().hasPrefix("on") {
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

    @objc private func syncSwitchChanged(_ sender: NSSwitch) {
        suppressSwitchStateUpdatesUntil = Date().addingTimeInterval(1.0)
        setSyncEnabledHandler(sender.state == .on)
    }

    @objc private func preferencesAction() {
        preferencesHandler()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
