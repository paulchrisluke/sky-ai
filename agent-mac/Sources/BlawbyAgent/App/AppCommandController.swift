import AppKit

@MainActor
final class AppCommandController: NSObject {
    private let openDashboardHandler: () -> Void
    private let openPreferencesHandler: () -> Void
    private let toggleSyncHandler: () -> Void
    private let isSyncEnabled: () -> Bool
    private var toggleSyncMenuItem: NSMenuItem?

    init(
        openDashboard: @escaping () -> Void,
        openPreferences: @escaping () -> Void,
        toggleSync: @escaping () -> Void,
        isSyncEnabled: @escaping () -> Bool
    ) {
        self.openDashboardHandler = openDashboard
        self.openPreferencesHandler = openPreferences
        self.toggleSyncHandler = toggleSync
        self.isSyncEnabled = isSyncEnabled
    }

    func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)

        let appMenu = NSMenu()
        appItem.submenu = appMenu

        let dashboardItem = NSMenuItem(
            title: "Open Dashboard",
            action: #selector(openDashboard),
            keyEquivalent: "d"
        )
        dashboardItem.keyEquivalentModifierMask = [.command]
        dashboardItem.target = self
        appMenu.addItem(dashboardItem)

        let preferencesItem = NSMenuItem(
            title: "Preferences...",
            action: #selector(openPreferences),
            keyEquivalent: ","
        )
        preferencesItem.keyEquivalentModifierMask = [.command]
        preferencesItem.target = self
        appMenu.addItem(preferencesItem)

        let toggleSyncItem = NSMenuItem(
            title: "Pause Sync",
            action: #selector(toggleSync),
            keyEquivalent: "p"
        )
        toggleSyncItem.keyEquivalentModifierMask = [.command, .shift]
        toggleSyncItem.target = self
        appMenu.addItem(toggleSyncItem)
        self.toggleSyncMenuItem = toggleSyncItem

        appMenu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(
            title: "Quit Blawby",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.keyEquivalentModifierMask = [.command]
        quitItem.target = NSApp
        appMenu.addItem(quitItem)

        NSApp.mainMenu = mainMenu
    }

    func refresh() {
        toggleSyncMenuItem?.title = isSyncEnabled() ? "Pause Sync" : "Resume Sync"
    }

    @objc
    private func openDashboard() {
        openDashboardHandler()
    }

    @objc
    private func openPreferences() {
        openPreferencesHandler()
    }

    @objc
    private func toggleSync() {
        toggleSyncHandler()
    }
}
