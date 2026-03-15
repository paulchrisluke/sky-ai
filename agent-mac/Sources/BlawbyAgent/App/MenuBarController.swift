import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let syncNowHandler: () -> Void
    private let backfillHandler: () -> Void
    private let preferencesHandler: () -> Void

    private let lastSyncItem = NSMenuItem(title: "Last synced: -", action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "Connection: connecting", action: nil, keyEquivalent: "")
    private let syncStateItem = NSMenuItem(title: "Sync: idle", action: nil, keyEquivalent: "")
    private let queueItem = NSMenuItem(title: "Queue: 0 pending", action: nil, keyEquivalent: "")
    private let mailStatusItem = NSMenuItem(title: "Mail status: n/a", action: nil, keyEquivalent: "")
    private let calendarStatusItem = NSMenuItem(title: "Calendar status: n/a", action: nil, keyEquivalent: "")
    private let mailItem = NSMenuItem(title: "Mail: 0 processed today", action: nil, keyEquivalent: "")
    private let calendarItem = NSMenuItem(title: "Calendar: 0 events synced", action: nil, keyEquivalent: "")

    init(syncNow: @escaping () -> Void, backfill: @escaping () -> Void, preferences: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.syncNowHandler = syncNow
        self.backfillHandler = backfill
        self.preferencesHandler = preferences
        super.init()
        setup()
    }

    private func setup() {
        if let button = statusItem.button {
            if let image = NSImage(systemSymbolName: "antenna.radiowaves.left.and.right", accessibilityDescription: "Blawby") {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "Blawby"
            }
        }

        menu.addItem(NSMenuItem(title: "Blawby", action: nil, keyEquivalent: ""))
        menu.addItem(connectionItem)
        menu.addItem(syncStateItem)
        menu.addItem(queueItem)
        menu.addItem(mailStatusItem)
        menu.addItem(calendarStatusItem)
        menu.addItem(.separator())
        menu.addItem(lastSyncItem)
        menu.addItem(mailItem)
        menu.addItem(calendarItem)
        menu.addItem(.separator())

        let syncItem = NSMenuItem(title: "Sync Now", action: #selector(syncNowAction), keyEquivalent: "")
        syncItem.target = self
        menu.addItem(syncItem)

        let backfillItem = NSMenuItem(title: "Backfill Last 90 Days", action: #selector(backfillAction), keyEquivalent: "")
        backfillItem.target = self
        menu.addItem(backfillItem)

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
        queuePending: Int,
        mailStatus: String,
        calendarStatus: String
    ) {
        lastSyncItem.title = "Last synced: \(lastSync)"
        mailItem.title = "Mail: \(mailProcessed) processed today"
        calendarItem.title = "Calendar: \(calendarSynced) events synced"
        connectionItem.title = "Connection: \(connection)"
        syncStateItem.title = "Sync: \(syncState)"
        queueItem.title = "Queue: \(queuePending) pending"
        mailStatusItem.title = "Mail status: \(mailStatus)"
        calendarStatusItem.title = "Calendar status: \(calendarStatus)"
        updateStatusIcon(connection: connection, syncState: syncState)
    }

    private func updateStatusIcon(connection: String, syncState: String) {
        guard let button = statusItem.button else {
            return
        }

        let symbolName: String
        if connection.hasPrefix("connected") {
            if syncState.hasPrefix("active") {
                symbolName = "arrow.triangle.2.circlepath.circle.fill"
            } else {
                symbolName = "antenna.radiowaves.left.and.right"
            }
        } else if connection.hasPrefix("reconnecting") || connection.hasPrefix("connecting") {
            symbolName = "arrow.triangle.2.circlepath"
        } else {
            symbolName = "wifi.exclamationmark"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Blawby") {
            image.isTemplate = true
            button.image = image
            button.title = ""
            return
        }
        button.title = "Blawby"
    }

    @objc private func syncNowAction() {
        syncNowHandler()
    }

    @objc private func backfillAction() {
        backfillHandler()
    }

    @objc private func preferencesAction() {
        preferencesHandler()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
