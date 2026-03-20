import SwiftUI
import Sparkle
import AppKit

// MARK: - Commands
struct BlawbyCommands: Commands {
    let session: AppSession
    let updates: SparkleUpdateController
    
    var body: some Commands {
        EmptyCommands()
    }
}

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
            
        case .ready(let context, let activeSources):
            ReadyMenuBarView(
                context: context,
                activeSources: activeSources,
                session: session,
                onOpenDashboard: { activateAndOpenWindow("main-dashboard", openWindow: openWindow) },
                onOpenPreferences: { activateAndOpenWindow("preferences", openWindow: openWindow) }
            )
            .frame(width: 320)
            
        case .degraded(let context, let activeSources, let issues):
            DegradedMenuBarView(
                context: context,
                activeSources: activeSources,
                issues: issues,
                session: session,
                onOpenDashboard: { activateAndOpenWindow("main-dashboard", openWindow: openWindow) },
                onOpenPreferences: { activateAndOpenWindow("preferences", openWindow: openWindow) }
            )
            .frame(width: 320)
        }
    }
}

// MARK: - Ready Menu Bar View
private struct ReadyMenuBarView: View {
    let context: BootstrapContext
    let activeSources: [SourceKind: ActiveSource]
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

// MARK: - Degraded Menu Bar View
private struct DegradedMenuBarView: View {
    let context: BootstrapContext
    let activeSources: [SourceKind: ActiveSource]
    let issues: [SourceIssue]
    @ObservedObject var session: AppSession
    let onOpenDashboard: () -> Void
    let onOpenPreferences: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.horizontal.circle.fill")
                .font(.title2)
                .foregroundColor(.orange)
            
            Text("Attention Needed")
                .font(.headline)
            
            Text("Some sources need attention")
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
            FatalErrorView(fatalIssue: fatalIssue.localizedDescription)
            .frame(minWidth: 960, minHeight: 620)
            
        case .ready(let context, let activeSources):
            ReadyDashboardView(
                context: context,
                activeSources: activeSources,
                session: session
            )
            .frame(minWidth: 960, minHeight: 620)
            
        case .degraded(let context, let activeSources, let issues):
            DegradedDashboardView(
                context: context,
                activeSources: activeSources,
                issues: issues,
                session: session
            )
            .frame(minWidth: 960, minHeight: 620)
        }
    }
}

// MARK: - Onboarding Dashboard View (Phase 3)
private struct OnboardingDashboardView: View {
    let context: BootstrapContext
    let capabilities: [SourceCapability]
    let issues: [SourceIssue]
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
                
                // Source cards with repair actions
                LazyVStack(spacing: 16) {
                    ForEach(capabilities) { capability in
                        let sourceIssues = issues.filter { $0.kind == capability.kind }
                        EnhancedSourceCardView(
                            capability: capability,
                            issues: sourceIssues,
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
                }
            }
            .padding(.horizontal, 32)
        }
    }
}

// MARK: - Issue Card View
private struct IssueCardView: View {
    let issue: SourceIssue
    
    var body: some View {
        HStack {
            Image(systemName: severityIcon(for: issue.severity))
                .foregroundColor(severityColor(for: issue.severity))
            
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text(issue.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    private func severityIcon(for severity: IssueSeverity) -> String {
        switch severity {
        case .error: return "xmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "info.circle.fill"
        }
    }
    
    private func severityColor(for severity: IssueSeverity) -> Color {
        switch severity {
        case .error: return .red
        case .warning: return .orange
        case .info: return .blue
        }
    }
}



// MARK: - Sparkle Update Controller
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

// MARK: - Dashboard Views
private struct ReadyDashboardView: View {
    let context: BootstrapContext
    let activeSources: [SourceKind: ActiveSource]
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Primary headline
                VStack(spacing: 8) {
                    Text("Blawby is ready")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Your sources are active and syncing")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 32)
                
                // Active sources
                LazyVStack(spacing: 16) {
                    ForEach(Array(activeSources.keys).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { kind in
                        EnhancedSourceCardView(
                            capability: SourceCapability(
                                kind: kind,
                                displayName: kind.displayName,
                                availability: .available,
                                authorization: .authorized,
                                activation: .active,
                                isRequiredForCoreValue: kind == .mail,
                                canDefer: false
                            ),
                            issues: [],
                            session: session
                        )
                    }
                }
            }
            .padding(.horizontal, 32)
        }
    }
}

private struct DegradedDashboardView: View {
    let context: BootstrapContext
    let activeSources: [SourceKind: ActiveSource]
    let issues: [SourceIssue]
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Primary headline
                VStack(spacing: 8) {
                    Text("Some sources need attention")
                        .font(.largeTitle)
                        .fontWeight(.bold)
                    Text("Fix the issues below to restore full functionality")
                        .font(.title3)
                        .foregroundColor(.secondary)
                }
                .padding(.top, 32)
                
                // Active sources with issues
                LazyVStack(spacing: 16) {
                    ForEach(Array(activeSources.keys).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { kind in
                        let sourceIssues = issues.filter { $0.kind == kind }
                        EnhancedSourceCardView(
                            capability: SourceCapability(
                                kind: kind,
                                displayName: kind.displayName,
                                availability: .available,
                                authorization: .authorized,
                                activation: .active,
                                isRequiredForCoreValue: kind == .mail,
                                canDefer: false
                            ),
                            issues: sourceIssues,
                            session: session
                        )
                    }
                }
                
                // Issues section
                if !issues.isEmpty {
                    VStack(spacing: 16) {
                        Text("Additional Issues")
                            .font(.headline)
                        
                        LazyVStack(spacing: 12) {
                            ForEach(issues) { issue in
                                IssueCardView(issue: issue)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 32)
        }
    }
}

private struct FatalErrorView: View {
    let fatalIssue: String
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.octagon")
                .font(.system(size: 64))
                .foregroundColor(.red)
            
            Text("Blawby failed to start")
                .font(.largeTitle)
                .fontWeight(.bold)
            
            Text(fatalIssue)
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: 400)
    }
}
