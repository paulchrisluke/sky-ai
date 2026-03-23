import SwiftUI

// MARK: - Dashboard Navigation
enum DashboardSection: String, CaseIterable {
    case overview = "overview"
    case mail = "mail"
    case calendar = "calendar"
    case contacts = "contacts"
    case activity = "activity"
    
    var displayName: String {
        switch self {
        case .overview: return "Overview"
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .contacts: return "Contacts"
        case .activity: return "Activity"
        }
    }
    
    var systemImage: String {
        switch self {
        case .overview: return "chart.bar"
        case .mail: return "envelope"
        case .calendar: return "calendar"
        case .contacts: return "person.2"
        case .activity: return "clock"
        }
    }
}
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
            DashboardRootView(
                context: nil,
                capabilities: [],
                activeSources: [:],
                issues: [],
                session: session
            )
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
        VStack(spacing: 0) {
            // Title
            HStack {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundColor(.primary)
                Text("Blawby")
                    .font(.headline)
                Spacer()
            }
            .padding()
            
            Divider()
            
            // Source toggles
            VStack(spacing: 0) {
                ForEach([SourceKind.calendar, SourceKind.mail, SourceKind.contacts], id: \.self) { kind in
                    SourceToggleRow(
                        kind: kind,
                        isEnabled: session.isEnabled(kind),
                        canToggle: session.canToggle(kind),
                        onToggle: { enabled in
                            Task {
                                await session.setEnabled(kind, enabled)
                            }
                        }
                    )
                }
            }
            
            Divider()
            
            // Action rows
            VStack(spacing: 0) {
                ActionRow(title: "Dashboard") {
                    activateAndOpenWindow("main-dashboard", openWindow: openWindow)
                }
                
                ActionRow(title: "Preferences") {
                    activateAndOpenWindow("preferences", openWindow: openWindow)
                }
                
                ActionRow(title: "Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .frame(width: 280)
    }
}

private struct SourceToggleRow: View {
    let kind: SourceKind
    let isEnabled: Bool
    let canToggle: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack {
            Text(kind.displayName)
                .font(.body)
            
            Spacer()
            
            Toggle("", isOn: Binding(
                get: { isEnabled },
                set: { onToggle($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!canToggle)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct ActionRow: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.body)
                    .foregroundColor(.primary)
                Spacer()
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

// MARK: - Dashboard Root View
private struct DashboardRootView: View {
    let context: BootstrapContext?
    let capabilities: [ResolvedSourceCapability]
    let activeSources: [SourceKind: ActiveSource]
    let issues: [SourceIssue]
    @ObservedObject var session: AppSession
    @Environment(\.openWindow) private var openWindow
    @State private var selectedSection: DashboardSection = .overview
    
    var body: some View {
        NavigationSplitView {
            // Sidebar
            List(DashboardSection.allCases, id: \.self, selection: $selectedSection) { section in
                Label(section.displayName, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Blawby")
            .listStyle(.sidebar)
        } detail: {
            // Detail pane
            DetailHostView(selectedSection: selectedSection, session: session)
        }
        .frame(minWidth: 960, minHeight: 620)
    }
}

// MARK: - Detail Host
private struct DetailHostView: View {
    let selectedSection: DashboardSection
    @ObservedObject var session: AppSession
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                switch selectedSection {
                case .overview:
                    OverviewDetailContent(session: session)
                case .mail:
                    MailDetailContent(session: session)
                case .calendar:
                    CalendarDetailContent(session: session)
                case .contacts:
                    ContactsDetailContent(session: session)
                case .activity:
                    ActivityDetailContent(session: session)
                }
            }
            .padding()
        }
        .navigationTitle(selectedSection.displayName)
    }
}

// MARK: - Overview Detail
private struct OverviewDetailContent: View {
    @ObservedObject var session: AppSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Status Summary
            VStack(alignment: .leading, spacing: 12) {
                Text("System Status")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                List {
                    HStack {
                        Text("Mail Sources")
                        Spacer()
                        Text("0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Calendar Sources")
                        Spacer()
                        Text("0")
                            .foregroundColor(.secondary)
                    }
                    HStack {
                        Text("Contact Sources")
                        Spacer()
                        Text("0")
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.plain)
            }
            
            // Recent Activity
            VStack(alignment: .leading, spacing: 12) {
                Text("Recent Activity")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                List {
                    HStack {
                        Text("No recent activity")
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Mail Detail
private struct MailDetailContent: View {
    @ObservedObject var session: AppSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Mail Sources")
                .font(.title2)
                .fontWeight(.semibold)
            
            List {
                HStack {
                    Text("No mail sources configured")
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Calendar Detail
private struct CalendarDetailContent: View {
    @ObservedObject var session: AppSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Calendar Sources")
                .font(.title2)
                .fontWeight(.semibold)
            
            List {
                HStack {
                    Text("No calendar sources configured")
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Contacts Detail
private struct ContactsDetailContent: View {
    @ObservedObject var session: AppSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Contact Sources")
                .font(.title2)
                .fontWeight(.semibold)
            
            List {
                HStack {
                    Text("No contact sources configured")
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.plain)
        }
    }
}

// MARK: - Activity Detail
private struct ActivityDetailContent: View {
    @ObservedObject var session: AppSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Sync Activity")
                .font(.title2)
                .fontWeight(.semibold)
            
            // Derived from existing sync/status data
            List {
                HStack {
                    Text("No recent sync activity")
                        .foregroundColor(.secondary)
                }
            }
            .listStyle(.plain)
            
            // Status Overview
            VStack(alignment: .leading, spacing: 12) {
                Text("Status Overview")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                List {
                    HStack {
                        Text("System Status")
                        Spacer()
                        Text("Ready")
                            .foregroundColor(.green)
                    }
                    HStack {
                        Text("Last Sync")
                        Spacer()
                        Text("Never")
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.plain)
            }
        }
    }
}

// MARK: - Onboarding Dashboard View (Phase 3)
private struct OnboardingDashboardView: View {
    let context: BootstrapContext
    let capabilities: [ResolvedSourceCapability]
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
                LazyVStack(spacing: 12) {
                    ForEach(capabilities) { capability in
                        let sourceIssues = issues.filter { $0.kind == capability.kind }
                        ExpandableSourceRow(
                            capability: capability,
                            issues: sourceIssues,
                            session: session
                        )
                    }
                }
            }
            .padding(.horizontal, 32)
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
