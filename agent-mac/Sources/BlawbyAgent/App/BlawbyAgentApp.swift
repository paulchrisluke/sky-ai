import SwiftUI
import Foundation

// MARK: - ConnectedSource Identifiable Extension
extension ConnectedSource: Identifiable {
    // ConnectedSource already has an `id` property, so this satisfies Identifiable
}

// MARK: - Date Formatters
private let relativeFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
}()

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
        
        Settings {
            PreferencesView(session: session)
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
            // Detail pane with toolbar
            VStack(spacing: 0) {
                // Toolbar
                HStack {
                    Text(selectedSection.displayName)
                        .font(.title2)
                        .fontWeight(.semibold)
                    
                    Spacer()
                    
                    Button(action: {
                        // TODO: Implement refresh/sync action
                    }) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("Refresh")
                    
                    Button(action: {
                        // TODO: Implement sync action
                    }) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    .help("Sync All")
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color(NSColor.controlBackgroundColor))
                
                // Detail content
                DetailHostView(selectedSection: selectedSection, session: session)
            }
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
    }
}

// MARK: - Overview Detail
private struct OverviewDetailContent: View {
    @ObservedObject var session: AppSession
    @State private var connectedSources: [ConnectedSource] = []
    @State private var isLoading = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("System Overview")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if !isLoading {
                    Text("\(connectedSources.count) sources")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 12)
            
            // Summary strip
            HStack(spacing: 24) {
                SummaryMetric(title: "Connected", value: "\(connectedSources.count)", color: .blue)
                SummaryMetric(title: "Active", value: "\(activeSources.count)", color: .green)
                SummaryMetric(title: "Errors", value: "\(errorSources.count)", color: .red)
                if let lastSync = lastSyncTime {
                    SummaryMetric(title: "Last Sync", value: lastSync, color: .secondary)
                }
            }
            .padding(.bottom, 16)
            
            // Main content - Recent Activity List
            VStack(alignment: .leading, spacing: 8) {
                Text("Recent Activity")
                    .font(.headline)
                    .fontWeight(.medium)
                
                if connectedSources.isEmpty {
                    List {
                        HStack {
                            Text("No sources configured")
                                .foregroundColor(.secondary)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    Table(recentSources.prefix(10)) {
                        TableColumn("Source") { source in
                            Text(source.sourceName)
                                .font(.system(size: 13))
                        }
                        TableColumn("Type") { source in
                            Text(source.sourceType.capitalized)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Status") { source in
                            statusBadge(source.status)
                        }
                        TableColumn("Updated") { source in
                            Text(relativeFormatter.localizedString(for: source.updatedAt, relativeTo: Date()))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                    .tableStyle(.bordered)
                    .frame(minHeight: 200)
                }
            }
        }
        .task {
            await loadSources()
        }
    }
    
    private var activeSources: [ConnectedSource] {
        connectedSources.filter { $0.enabled && $0.status != .error }
    }
    
    private var errorSources: [ConnectedSource] {
        connectedSources.filter { $0.status == .error }
    }
    
    private var recentSources: [ConnectedSource] {
        connectedSources.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    private var lastSyncTime: String? {
        guard let latest = connectedSources.map(\.updatedAt).sorted().last else { return nil }
        return relativeFormatter.localizedString(for: latest, relativeTo: Date())
    }
    
    private func loadSources() async {
        guard let context = session.currentContext else {
            isLoading = false
            return
        }
        
        do {
            connectedSources = context.localStore.connectedSources()
            isLoading = false
        } catch {
            print("Error loading sources: \(error)")
            isLoading = false
        }
    }
}

// MARK: - Summary Metric Component
private struct SummaryMetric: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline)
                .foregroundColor(color)
        }
    }
}

// MARK: - Mail Detail
private struct MailDetailContent: View {
    @ObservedObject var session: AppSession
    @State private var mailSources: [ConnectedSource] = []
    @State private var isLoading = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("Mail Sources")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if !isLoading {
                    Text("\(mailSources.count) sources")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 12)
            
            // Summary strip
            HStack(spacing: 24) {
                SummaryMetric(title: "Sources", value: "\(mailSources.count)", color: .blue)
                SummaryMetric(title: "Active", value: "\(activeSources.count)", color: .green)
                SummaryMetric(title: "Errors", value: "\(errorSources.count)", color: .red)
                SummaryMetric(title: "Total Items", value: "\(totalItems)", color: .secondary)
            }
            .padding(.bottom, 16)
            
            // Main content - Mail Sources Table
            VStack(alignment: .leading, spacing: 8) {
                if mailSources.isEmpty {
                    List {
                        HStack {
                            Text("No mail sources configured")
                                .foregroundColor(.secondary)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    Table(mailSources) {
                        TableColumn("Name") { source in
                            Text(source.sourceName)
                                .font(.system(size: 13))
                        }
                        TableColumn("Status") { source in
                            statusBadge(source.status)
                        }
                        TableColumn("Account ID") { source in
                            Text(source.accountId)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Total Synced") { source in
                            Text("\(source.totalSynced)")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Updated") { source in
                            Text(relativeFormatter.localizedString(for: source.updatedAt, relativeTo: Date()))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Error") { source in
                            if let error = source.lastError {
                                Text(error)
                                    .font(.system(size: 13))
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                            } else {
                                Text("—")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .tableStyle(.bordered)
                    .frame(minHeight: 300)
                }
            }
        }
        .task {
            await loadMailSources()
        }
    }
    
    private var activeSources: [ConnectedSource] {
        mailSources.filter { $0.enabled && $0.status != .error }
    }
    
    private var errorSources: [ConnectedSource] {
        mailSources.filter { $0.status == .error }
    }
    
    private var totalItems: Int {
        mailSources.reduce(0) { $0 + $1.totalSynced }
    }
    
    private func loadMailSources() async {
        guard let context = session.currentContext else {
            isLoading = false
            return
        }
        
        do {
            let allSources = context.localStore.connectedSources()
            mailSources = allSources.filter { $0.sourceType == "mail" }
            isLoading = false
        } catch {
            print("Error loading mail sources: \(error)")
            isLoading = false
        }
    }
}

// MARK: - Calendar Detail
private struct CalendarDetailContent: View {
    @ObservedObject var session: AppSession
    @State private var calendarSources: [ConnectedSource] = []
    @State private var isLoading = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("Calendar Sources")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if !isLoading {
                    Text("\(calendarSources.count) sources")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 12)
            
            // Summary strip
            HStack(spacing: 24) {
                SummaryMetric(title: "Sources", value: "\(calendarSources.count)", color: .blue)
                SummaryMetric(title: "Active", value: "\(activeSources.count)", color: .green)
                SummaryMetric(title: "Errors", value: "\(errorSources.count)", color: .red)
                SummaryMetric(title: "Total Synced", value: "\(totalItems)", color: .secondary)
            }
            .padding(.bottom, 16)
            
            // Main content - Calendar Sources Table
            VStack(alignment: .leading, spacing: 8) {
                if calendarSources.isEmpty {
                    List {
                        HStack {
                            Text("No calendar sources configured")
                                .foregroundColor(.secondary)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    Table(calendarSources) {
                        TableColumn("Name") { source in
                            Text(source.sourceName)
                                .font(.system(size: 13))
                        }
                        TableColumn("Status") { source in
                            statusBadge(source.status)
                        }
                        TableColumn("Source ID") { source in
                            Text(source.accountId)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Total Synced") { source in
                            Text("\(source.totalSynced)")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Updated") { source in
                            Text(relativeFormatter.localizedString(for: source.updatedAt, relativeTo: Date()))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Error") { source in
                            if let error = source.lastError {
                                Text(error)
                                    .font(.system(size: 13))
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                            } else {
                                Text("—")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .tableStyle(.bordered)
                    .frame(minHeight: 300)
                }
            }
        }
        .task {
            await loadCalendarSources()
        }
    }
    
    private var activeSources: [ConnectedSource] {
        calendarSources.filter { $0.enabled && $0.status != .error }
    }
    
    private var errorSources: [ConnectedSource] {
        calendarSources.filter { $0.status == .error }
    }
    
    private var totalItems: Int {
        calendarSources.reduce(0) { $0 + $1.totalSynced }
    }
    
    private func loadCalendarSources() async {
        guard let context = session.currentContext else {
            isLoading = false
            return
        }
        
        do {
            let allSources = context.localStore.connectedSources()
            calendarSources = allSources.filter { $0.sourceType == "calendar" }
            isLoading = false
        } catch {
            print("Error loading calendar sources: \(error)")
            isLoading = false
        }
    }
}

// MARK: - Contacts Detail
private struct ContactsDetailContent: View {
    @ObservedObject var session: AppSession
    @State private var messagesSources: [ConnectedSource] = []
    @State private var isLoading = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("Contact Sources")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if !isLoading {
                    Text("\(messagesSources.count) sources")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 12)
            
            // Summary strip (lighter)
            HStack(spacing: 24) {
                SummaryMetric(title: "Sources", value: "\(messagesSources.count)", color: .blue)
                SummaryMetric(title: "Active", value: "\(activeSources.count)", color: .green)
                SummaryMetric(title: "Total Contacts", value: "\(totalItems)", color: .secondary)
            }
            .padding(.bottom, 16)
            
            // Main content - Messages Sources Table
            VStack(alignment: .leading, spacing: 8) {
                if messagesSources.isEmpty {
                    List {
                        HStack {
                            Text("No contact sources configured")
                                .foregroundColor(.secondary)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    Table(messagesSources) {
                        TableColumn("Name") { source in
                            Text(source.sourceName)
                                .font(.system(size: 13))
                        }
                        TableColumn("Status") { source in
                            statusBadge(source.status)
                        }
                        TableColumn("Database") { source in
                            Text(source.accountId)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Total Contacts") { source in
                            Text("\(source.totalSynced)")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Updated") { source in
                            Text(relativeFormatter.localizedString(for: source.updatedAt, relativeTo: Date()))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    }
                    .tableStyle(.bordered)
                    .frame(minHeight: 250)
                }
            }
        }
        .task {
            await loadContactsSources()
        }
    }
    
    private var activeSources: [ConnectedSource] {
        messagesSources.filter { $0.enabled && $0.status != .error }
    }
    
    private var totalItems: Int {
        messagesSources.reduce(0) { $0 + $1.totalSynced }
    }
    
    private func loadContactsSources() async {
        guard let context = session.currentContext else {
            isLoading = false
            return
        }
        
        do {
            let allSources = context.localStore.connectedSources()
            messagesSources = allSources.filter { $0.sourceType == "messages" }
            isLoading = false
        } catch {
            print("Error loading contacts sources: \(error)")
            isLoading = false
        }
    }
}

// MARK: - Activity Detail
private struct ActivityDetailContent: View {
    @ObservedObject var session: AppSession
    @State private var allSources: [ConnectedSource] = []
    @State private var isLoading = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header row
            HStack {
                Text("Sync Activity")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                if !isLoading {
                    Text("\(allSources.count) sources")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.bottom, 12)
            
            // Summary strip
            HStack(spacing: 24) {
                SummaryMetric(title: "Total Sources", value: "\(allSources.count)", color: .blue)
                SummaryMetric(title: "Active", value: "\(activeSources.count)", color: .green)
                SummaryMetric(title: "Errors", value: "\(errorSources.count)", color: .red)
                SummaryMetric(title: "Last Activity", value: lastSyncText, color: .secondary)
            }
            .padding(.bottom, 16)
            
            // Main content - Chronological Activity Table
            VStack(alignment: .leading, spacing: 8) {
                if allSources.isEmpty {
                    List {
                        HStack {
                            Text("No recent sync activity")
                                .foregroundColor(.secondary)
                        }
                    }
                    .listStyle(.plain)
                } else {
                    Table(recentActivitySources) {
                        TableColumn("Source") { source in
                            Text(source.sourceName)
                                .font(.system(size: 13))
                        }
                        TableColumn("Kind") { source in
                            Text(source.sourceType.capitalized)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Status") { source in
                            statusBadge(source.status)
                        }
                        TableColumn("Updated") { source in
                            Text(relativeFormatter.localizedString(for: source.updatedAt, relativeTo: Date()))
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                        TableColumn("Error") { source in
                            if let error = source.lastError {
                                Text(error)
                                    .font(.system(size: 13))
                                    .foregroundColor(.red)
                                    .lineLimit(1)
                            } else {
                                Text("—")
                                    .font(.system(size: 13))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .tableStyle(.bordered)
                    .frame(minHeight: 400)
                }
            }
        }
        .task {
            await loadActivity()
        }
    }
    
    private var recentActivitySources: [ConnectedSource] {
        allSources.sorted { $0.updatedAt > $1.updatedAt }
    }
    
    private var activeSources: [ConnectedSource] {
        allSources.filter { $0.enabled && $0.status != .error }
    }
    
    private var errorSources: [ConnectedSource] {
        allSources.filter { $0.status == .error }
    }
    
    private var lastSyncText: String {
        let latestActivity = allSources.map(\.updatedAt).sorted().last ?? Date()
        return relativeFormatter.localizedString(for: latestActivity, relativeTo: Date())
    }
    
    private func loadActivity() async {
        guard let context = session.currentContext else {
            isLoading = false
            return
        }
        
        do {
            allSources = context.localStore.connectedSources()
            isLoading = false
        } catch {
            print("Error loading activity: \(error)")
            isLoading = false
        }
    }
}

// MARK: - Shared Components
private func statusBadge(_ status: SourceStatus) -> some View {
    Text(status.displayName)
        .font(.caption)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(colorForStatus(status))
        .foregroundColor(.white)
        .cornerRadius(3)
}

private func colorForStatus(_ status: SourceStatus) -> Color {
    switch status {
    case .idle, .current: return .green
    case .syncing: return .blue
    case .error: return .red
    case .pending: return .orange
    case .paused: return .gray
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
