import SwiftUI
import Sparkle
import AppKit

@main
struct BlawbyAgentApp: App {
    @StateObject private var session = AppSession()
    @StateObject private var updates = SparkleUpdateController()

    var body: some Scene {
        MenuBarExtra("Blawby", systemImage: "bolt.horizontal.circle.fill") {
            MenuBarRootView(session: session)
        }
        .menuBarExtraStyle(.window)

        Window("Blawby Dashboard", id: "main-dashboard") {
            DashboardRootView(session: session)
        }
        .defaultSize(width: 1200, height: 760)
        .windowResizability(.contentMinSize)

        Window("Blawby Preferences", id: "preferences") {
            PreferencesView(session: session)
        }
        .defaultSize(width: 760, height: 520)
        .windowResizability(.contentMinSize)

        .commands {
            BlawbyCommands(session: session, updates: updates)
        }
    }
}

@MainActor
private func activateAndOpenWindow(_ id: String, openWindow: OpenWindowAction) {
    NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    openWindow(id: id)
    for delay in [0.0, 0.05, 0.15] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            for window in NSApplication.shared.windows {
                configureWindow(window, for: id)
            }
            if let target = targetWindow(for: id) {
                target.orderFrontRegardless()
                target.makeKeyAndOrderFront(nil)
            }
        }
    }
}

@MainActor
private func targetWindow(for id: String) -> NSWindow? {
    switch id {
    case "main-dashboard":
        return NSApplication.shared.windows.first { $0.title == "Blawby Dashboard" }
    case "preferences":
        return NSApplication.shared.windows.first { $0.title == "Blawby Preferences" }
    default:
        return NSApplication.shared.windows.first
    }
}

@MainActor
private func configureWindow(_ window: NSWindow, for id: String) {
    window.collectionBehavior.insert(.moveToActiveSpace)
    window.styleMask.insert(.resizable)
    window.styleMask.remove(.fullSizeContentView)
    window.titlebarAppearsTransparent = true
    window.titleVisibility = .hidden
    window.toolbarStyle = .automatic

    if id == "main-dashboard", window.title == "Blawby Dashboard" {
        window.minSize = NSSize(width: 960, height: 620)
    } else if id == "preferences", window.title == "Blawby Preferences" {
        window.minSize = NSSize(width: 680, height: 440)
    }
}

private struct MenuBarRootView: View {
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let sourceManager = session.sourceManager {
            MenuBarPopoverView(
                sourceManager: sourceManager,
                state: session.menuState,
                onToggleSync: { session.toggleSync() },
                onOpenDashboard: { activateAndOpenWindow("main-dashboard", openWindow: openWindow) },
                onOpenPreferences: { activateAndOpenWindow("preferences", openWindow: openWindow) }
            )
        } else if let startupError = session.startupError {
            Text("Startup failed: \(startupError)")
                .foregroundColor(.red)
                .padding()
                .frame(width: 320)
        } else {
            ProgressView("Starting Blawby…")
                .padding()
                .frame(width: 320)
        }
    }
}

private struct DashboardRootView: View {
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let sourceManager = session.sourceManager {
            DashboardView(
                sourceManager: sourceManager,
                state: session.menuState
            )
            .frame(minWidth: 960, minHeight: 620)
        } else if let startupError = session.startupError {
            Text("Startup failed: \(startupError)")
                .foregroundColor(.red)
                .padding()
        } else {
            ProgressView("Loading dashboard…")
                .padding()
        }
    }
}

private struct BlawbyCommands: Commands {
    @ObservedObject var session: AppSession
    @ObservedObject var updates: SparkleUpdateController
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Blawby") {
            Button("Open Dashboard") {
                activateAndOpenWindow("main-dashboard", openWindow: openWindow)
            }
            .keyboardShortcut("d")

            Button("Preferences…") {
                activateAndOpenWindow("preferences", openWindow: openWindow)
            }
            .keyboardShortcut(",", modifiers: [.command])

            Button("Check for Updates…") {
                updates.checkForUpdates()
            }

            Divider()

            Button(session.menuState.syncActivated ? "Pause Sync" : "Resume Sync") {
                session.toggleSync()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])

            Divider()

            Button("Quit Blawby") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
    }
}

@MainActor
final class SparkleUpdateController: ObservableObject {
    private let updaterController: SPUStandardUpdaterController

    init() {
        self.updaterController = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
    }

    func checkForUpdates() {
        updaterController.checkForUpdates(nil)
    }
}
