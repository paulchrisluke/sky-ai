import SwiftUI

@main
struct BlawbyAgentApp: App {
    @StateObject private var session = AppSession()

    var body: some Scene {
        MenuBarExtra("Blawby", systemImage: "bolt.horizontal.circle.fill") {
            MenuBarRootView(session: session)
        }
        .menuBarExtraStyle(.window)

        Window("Blawby Dashboard", id: "main-dashboard") {
            DashboardRootView(session: session)
        }

        Window("Blawby Preferences", id: "preferences") {
            PreferencesView(session: session)
        }

        .commands {
            BlawbyCommands(session: session)
        }
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
                onOpenDashboard: { openWindow(id: "main-dashboard") },
                onOpenPreferences: { openWindow(id: "preferences") }
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

    var body: some View {
        if let sourceManager = session.sourceManager {
            DashboardView(sourceManager: sourceManager, state: session.menuState)
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
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandMenu("Blawby") {
            Button("Open Dashboard") {
                openWindow(id: "main-dashboard")
            }
            .keyboardShortcut("d")

            Button("Preferences…") {
                openWindow(id: "preferences")
            }
            .keyboardShortcut(",", modifiers: [.command])

            Divider()

            Button(session.menuState.syncActivated ? "Pause Sync" : "Resume Sync") {
                session.toggleSync()
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
