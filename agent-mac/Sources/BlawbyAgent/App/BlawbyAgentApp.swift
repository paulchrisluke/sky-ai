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
                .frame(minWidth: 960, minHeight: 620)
        }
        
        Window("Blawby Preferences", id: "preferences") {
            PreferencesView(session: session)
                .frame(minWidth: 760, minHeight: 440)
        }
        
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
        switch session.bootState {
        case .launching:
            ProgressView("Starting…")
                .padding()
                .frame(width: 320)
                
        case .setupRequired(let context, let capabilities, let issues):
            VStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.title2)
                    .foregroundColor(.blue)
                
                Text("Setup Required")
                    .font(.headline)
                
                Text("Connect a source to get started")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Divider()
                
                Button("Open Dashboard") {
                    activateAndOpenWindow("main-dashboard", openWindow: openWindow)
                }
                .buttonStyle(.borderedProminent)
                
                Button("Preferences") {
                    activateAndOpenWindow("preferences", openWindow: openWindow)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(width: 320)
            
        case .fatal(let fatalIssue):
            VStack(spacing: 8) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.title2)
                    .foregroundColor(.red)
                
                Text("Startup Failed")
                    .font(.headline)
                
                Text("Blawby encountered an error")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Divider()
                
                Button("Preferences") {
                    activateAndOpenWindow("preferences", openWindow: openWindow)
                }
                .buttonStyle(.borderedProminent)
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .frame(width: 320)
        }
    }
}

// MARK: - Ready Menu Bar View
private struct ReadyMenuBarView: View {
    @ObservedObject var session: AppSession
    let onOpenDashboard: () -> Void
    let onOpenPreferences: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.title2)
                .foregroundColor(.green)
            
            Text("Blawby Ready")
                .font(.headline)
            
            Text("Sources connected")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(spacing: 8) {
                Button("Open Dashboard") {
                    onOpenDashboard()
                }
                .buttonStyle(.borderedProminent)
                
                HStack(spacing: 8) {
                    Button("Preferences") {
                        onOpenPreferences()
                    }
                    .buttonStyle(.bordered)
                    
                    if session.legacyMenuState.syncActivated {
                        Button("Pause") {
                            session.toggleSync()
                        }
                        .buttonStyle(.bordered)
                    } else {
                        Button("Resume") {
                            session.toggleSync()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - Degraded Menu Bar View
private struct DegradedMenuBarView: View {
    @ObservedObject var session: AppSession
    let onOpenDashboard: () -> Void
    let onOpenPreferences: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.title2)
                .foregroundColor(.orange)
            
            Text("Some Issues")
                .font(.headline)
            
            Text("One or more sources need attention")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Divider()
            
            VStack(spacing: 8) {
                Button("Open Dashboard") {
                    onOpenDashboard()
                }
                .buttonStyle(.borderedProminent)
                
                Button("Preferences") {
                    onOpenPreferences()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

// MARK: - Fatal Menu Bar View
private struct FatalMenuBarView: View {
    @ObservedObject var session: AppSession
    let onOpenPreferences: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.title2)
                .foregroundColor(.red)
            
            Text("Startup Failed")
                .font(.headline)
            
            Text("Blawby encountered an error")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            Divider()
            
            VStack(spacing: 8) {
                Button("Preferences") {
                    onOpenPreferences()
                }
                .buttonStyle(.borderedProminent)
                
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 320)
    }
}

private struct DashboardRootView: View {
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        switch session.bootState {
        case .launching:
            ProgressView("Starting Blawby…")
                .padding()
                .frame(minWidth: 960, minHeight: 620)
                
        case .setupRequired(let context, let capabilities, let issues):
            OnboardingDashboardView(
                context: context,
                capabilities: capabilities,
                issues: issues,
                session: session
            )
            .frame(minWidth: 960, minHeight: 620)
            
        case .fatal(let fatalIssue):
            FatalErrorView(
                fatalIssue: fatalIssue,
                session: session
            )
            .frame(minWidth: 960, minHeight: 620)
        }
    }
}

// MARK: - Onboarding Dashboard View (Phase 1)
private struct OnboardingDashboardView: View {
    let context: BootstrapContext
    let capabilities: [SourceCapability]
    let issues: [StartupIssue]
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Primary headline
                VStack(spacing: 8) {
                    Text("Connect your first source")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Choose a source to get started with Blawby")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 32)
                
                // Source cards
                LazyVStack(spacing: 16) {
                    ForEach(capabilities) { capability in
                        SourceCardView(
                            capability: capability,
                            session: session
                        )
                    }
                }
                
                // Issues section (if any)
                if !issues.isEmpty {
                    VStack(spacing: 16) {
                        Text("Some issues need attention")
                            .font(.headline)
                        
                        LazyVStack(spacing: 12) {
                            ForEach(issues) { issue in
                                IssueCardView(issue: issue)
                            }
                        }
                    }
                    .padding(.vertical, 24)
                }
                
                // What happens next
                VStack(spacing: 8) {
                    Text("What happens next")
                        .font(.headline)
                    Text("Blawby will sync your data and help you stay organized with intelligent task extraction and insights.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 600)
                }
                .padding(.vertical, 24)
                
                // Current status
                VStack(spacing: 8) {
                    Text("Current Status")
                        .font(.headline)
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown")
                    }
                    HStack {
                        Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                        Spacer()
                        Text(session.syncRequested ? "Enabled" : "Disabled")
                    }
                }
                .frame(maxWidth: 400)
                
                Spacer()
            }
            .padding()
        }
    }
}

// MARK: - Source Card View (Phase 2)
private struct SourceCardView: View {
    let capability: SourceCapability
    @ObservedObject var session: AppSession

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: capability.kind.systemImage)
                    .font(.title2)
                    .foregroundColor(statusColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(capability.displayName)
                        .font(.headline)
                    
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                if capability.activation.isActive {
                    Button("Disable") {
                        Task {
                            await session.disableSource(capability.kind)
                        }
                    }
                    .buttonStyle(.bordered)
                } else if capability.authorization == .denied || capability.authorization == .restricted {
                    Button("Open Settings") {
                        // Open System Settings to the appropriate privacy section
                        openSystemSettings(for: capability.kind)
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Button("Enable") {
                        Task {
                            await session.enableSource(capability.kind)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canEnable)
                }
            }
            
            // Authorization status
            if capability.authorization != .notRequired {
                HStack {
                    Image(systemName: authStatusIcon)
                        .foregroundColor(authStatusColor)
                    Text(authStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Availability status
            if case .unavailable(let reason) = capability.availability {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Unavailable: \(reason)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var statusColor: Color {
        switch capability.activation {
        case .active: return .green
        case .activating: return .orange
        case .inactive: return .gray
        case .degraded: return .red
        }
    }
    
    private var statusText: String {
        switch capability.activation {
        case .active: return "Active"
        case .activating: return "Activating..."
        case .inactive: return "Inactive"
        case .degraded(let reason): return "Degraded: \(reason)"
        }
    }
    
    private var canEnable: Bool {
        return capability.availability.isAvailable && 
               capability.authorization != .denied &&
               capability.authorization != .restricted
    }
    
    private func openSystemSettings(for kind: SourceKind) {
        let url: URL
        switch kind {
        case .calendar:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        case .contacts:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
        case .mail:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        }
        NSWorkspace.shared.open(url)
    }
    
    private var authStatusIcon: String {
        switch capability.authorization {
        case .authorized: return "checkmark.shield"
        case .denied: return "xmark.shield"
        case .restricted: return "minus.shield"
        case .notDetermined: return "questionmark.shield"
        case .notRequired: return "shield"
        }
    }
    
    private var authStatusColor: Color {
        switch capability.authorization {
        case .authorized: return .green
        case .denied: return .red
        case .restricted: return .orange
        case .notDetermined: return .gray
        case .notRequired: return .blue
        }
    }
    
    private var authStatusText: String {
        switch capability.authorization {
        case .authorized: return "Authorized"
        case .denied: return "Access denied"
        case .restricted: return "Access restricted"
        case .notDetermined: return "Not requested"
        case .notRequired: return "Not required"
        }
    }
}

// MARK: - Ready Dashboard View
private struct ReadyDashboardView: View {
    let runtime: AppRuntime
    @ObservedObject var session: AppSession

    var body: some View {
        VStack {
            Text("Blawby is Ready")
                .font(.largeTitle)
                .fontWeight(.bold)
            Text("Your sources are connected and syncing")
                .font(.title2)
                .foregroundColor(.secondary)
        }
        .padding()
    }
}

// MARK: - Degraded Dashboard View
private struct DegradedDashboardView: View {
    let runtime: AppRuntime
    let issues: [StartupIssue]
    @ObservedObject var session: AppSession

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Text("Some sources need attention")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                LazyVStack(spacing: 16) {
                    ForEach(issues) { issue in
                        IssueCardView(issue: issue)
                    }
                }
                
                Button("Continue with available sources") {
                    // Continue with what works
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }
}

// MARK: - Issue Card View
private struct IssueCardView: View {
    let issue: StartupIssue

    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundColor(.orange)
            
            VStack(alignment: .leading) {
                Text(issueTitle)
                    .font(.headline)
                Text(issueDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Fix") {
                // TODO: Implement repair actions
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private var issueTitle: String {
        switch issue {
        case .sourceUnavailable(let kind, _):
            return "\(kind.displayName) unavailable"
        case .authorizationDenied(let kind):
            return "\(kind.displayName) access denied"
        case .activationFailed(let kind, _):
            return "\(kind.displayName) activation failed"
        case .partialDependencyFailure(let component, _):
            return "Component issue: \(component)"
        }
    }
    
    private var issueDescription: String {
        switch issue {
        case .sourceUnavailable(_, let reason):
            return reason
        case .authorizationDenied:
            return "Open System Settings to grant access"
        case .activationFailed(_, let reason):
            return reason
        case .partialDependencyFailure(_, let reason):
            return reason
        }
    }
}

// MARK: - Fatal Error View
private struct FatalErrorView: View {
    let fatalIssue: FatalStartupIssue
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.octagon")
                .font(.system(size: 64))
                .foregroundColor(.red)
            
            Text("Blawby failed to start")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text(errorDescription)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
            
            VStack(spacing: 16) {
                Button("Open Preferences") {
                    activateAndOpenWindow("preferences", openWindow: openWindow)
                }
                .buttonStyle(.borderedProminent)
                
                Button("View Logs") {
                    // TODO: Implement log viewing
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
    
    private var errorDescription: String {
        switch fatalIssue {
        case .storageInitializationFailed(let reason):
            return "Blawby couldn't initialize its storage. This might be due to disk space or permissions issues."
        case .configurationLoadFailed(let reason):
            return "Blawby's configuration is corrupted or unreadable."
        case .loggerInitializationFailed(let reason):
            return "Blawby couldn't start its logging system."
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
