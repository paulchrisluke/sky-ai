import SwiftUI
import Sparkle

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

        Window("Blawby Preferences", id: "preferences") {
            PreferencesView(session: session)
        }

        .commands {
            BlawbyCommands(session: session, updates: updates)
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
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let sourceManager = session.sourceManager {
            DashboardView(
                sourceManager: sourceManager,
                state: session.menuState,
                onToggleSync: { session.toggleSync() },
                onOpenPreferences: { openWindow(id: "preferences") }
            )
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
                openWindow(id: "main-dashboard")
            }
            .keyboardShortcut("d")

            Button("Preferences…") {
                openWindow(id: "preferences")
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
