import AppKit
import Combine

@MainActor
final class AppUIController {
    private var menuBar: MenuBarController?
    private var preferencesWindow: PreferencesWindowController?
    private var dashboardWindow: DashboardWindowController?
    private var sourceCancellable: AnyCancellable?

    func observeSources(
        _ sourceManager: SourceManager,
        onChanged: @escaping @MainActor () -> Void
    ) {
        sourceCancellable = sourceManager.$sources
            .receive(on: DispatchQueue.main)
            .sink { _ in
                onChanged()
            }
    }

    func setupMenuBar(
        sourceManager: SourceManager,
        setSyncEnabled: @escaping @MainActor (Bool) -> Void,
        openDashboard: @escaping () -> Void,
        preferences: @escaping () -> Void
    ) {
        menuBar = MenuBarController(
            sourceManager: sourceManager,
            setSyncEnabled: setSyncEnabled,
            openDashboard: openDashboard,
            preferences: preferences
        )
    }

    func updateMenu(
        lastSync: String,
        connection: String,
        syncActivated: Bool,
        sources: [ConnectedSource]
    ) {
        menuBar?.update(
            lastSync: lastSync,
            connection: connection,
            syncActivated: syncActivated,
            sources: sources
        )
    }

    func openPreferences(config: Config, sourceManager: SourceManager) {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController(config: config, sourceManager: sourceManager)
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func openDashboard(sourceManager: SourceManager) {
        guard let menuBar else { return }
        if dashboardWindow == nil {
            dashboardWindow = DashboardWindowController(sourceManager: sourceManager, state: menuBar.state)
        }
        dashboardWindow?.showWindow(nil)
        dashboardWindow?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
