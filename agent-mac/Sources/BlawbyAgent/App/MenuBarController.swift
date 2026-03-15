import AppKit

@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private let syncNowHandler: () -> Void
    private let preferencesHandler: () -> Void

    private let lastSyncItem = NSMenuItem(title: "Last synced: -", action: nil, keyEquivalent: "")
    private let mailItem = NSMenuItem(title: "Mail: 0 processed today", action: nil, keyEquivalent: "")
    private let calendarItem = NSMenuItem(title: "Calendar: 0 events synced", action: nil, keyEquivalent: "")

    init(syncNow: @escaping () -> Void, preferences: @escaping () -> Void) {
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.syncNowHandler = syncNow
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
        menu.addItem(lastSyncItem)
        menu.addItem(mailItem)
        menu.addItem(calendarItem)
        menu.addItem(.separator())

        let syncItem = NSMenuItem(title: "Sync Now", action: #selector(syncNowAction), keyEquivalent: "")
        syncItem.target = self
        menu.addItem(syncItem)

        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(preferencesAction), keyEquivalent: "")
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitAction), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    func update(lastSync: String, mailProcessed: Int, calendarSynced: Int) {
        lastSyncItem.title = "Last synced: \(lastSync)"
        mailItem.title = "Mail: \(mailProcessed) processed today"
        calendarItem.title = "Calendar: \(calendarSynced) events synced"
    }

    @objc private func syncNowAction() {
        syncNowHandler()
    }

    @objc private func preferencesAction() {
        preferencesHandler()
    }

    @objc private func quitAction() {
        NSApplication.shared.terminate(nil)
    }
}
