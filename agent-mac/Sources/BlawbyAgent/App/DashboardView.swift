import SwiftUI

struct DashboardView: View {
    @ObservedObject var sourceManager: SourceManager
    @ObservedObject var state: MenuBarState
    let onToggleSync: () -> Void
    let onOpenPreferences: () -> Void

    @State private var selectedSourceId: String?
    @State private var sourceSearch = ""
    @State private var expandedMailAccounts: Set<String> = []
    @State private var expandedCalendarAccounts: Set<String> = []
    @State private var expandedMessageAccounts: Set<String> = []

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSourceId) {
                Section("Mailboxes") {
                    ForEach(mailAccountGroups) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedMailAccounts.contains(group.id) || sourceSearchQuery.isEmpty == false },
                                set: { expanded in
                                    if expanded {
                                        expandedMailAccounts.insert(group.id)
                                    } else {
                                        expandedMailAccounts.remove(group.id)
                                    }
                                }
                            )
                        ) {
                            ForEach(group.sources, id: \.id) { source in
                                SourceSidebarRow(source: source, titleOverride: mailboxName(for: source))
                                    .tag(source.id)
                            }
                        } label: {
                            SidebarAccountLabel(
                                title: group.accountName,
                                systemImage: "person.crop.circle",
                                totalsText: groupTotalsText(group.sources)
                            )
                        }
                    }
                }

                Section("Calendars") {
                    ForEach(calendarAccountGroups) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedCalendarAccounts.contains(group.id) || sourceSearchQuery.isEmpty == false },
                                set: { expanded in
                                    if expanded {
                                        expandedCalendarAccounts.insert(group.id)
                                    } else {
                                        expandedCalendarAccounts.remove(group.id)
                                    }
                                }
                            )
                        ) {
                            ForEach(group.sources, id: \.id) { source in
                                SourceSidebarRow(source: source)
                                    .tag(source.id)
                            }
                        } label: {
                            SidebarAccountLabel(
                                title: group.accountName,
                                systemImage: "person.crop.circle",
                                totalsText: groupTotalsText(group.sources)
                            )
                        }
                    }
                }

                Section("Messages") {
                    ForEach(messageAccountGroups) { group in
                        DisclosureGroup(
                            isExpanded: Binding(
                                get: { expandedMessageAccounts.contains(group.id) || sourceSearchQuery.isEmpty == false },
                                set: { expanded in
                                    if expanded {
                                        expandedMessageAccounts.insert(group.id)
                                    } else {
                                        expandedMessageAccounts.remove(group.id)
                                    }
                                }
                            )
                        ) {
                            ForEach(group.sources, id: \.id) { source in
                                SourceSidebarRow(source: source)
                                    .tag(source.id)
                            }
                        } label: {
                            SidebarAccountLabel(
                                title: group.accountName,
                                systemImage: "person.crop.circle",
                                totalsText: groupTotalsText(group.sources)
                            )
                        }
                    }
                }
            }
            .navigationTitle("Sources")
            .searchable(text: $sourceSearch, prompt: "Filter sources")
        } detail: {
            if let source = selectedSource {
                SourceDetailView(
                    source: source,
                    sourcePath: sourcePath(for: source),
                    lastSync: state.lastSync
                )
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .font(.system(size: 30))
                        .foregroundColor(.secondary)
                    Text("Select a Source")
                        .font(.headline)
                    Text("Choose a source from the sidebar to inspect status and sync progress.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedSourceId == nil, let first = filteredSources.first {
                selectedSourceId = first.id
            }
            expandedMailAccounts = Set(mailAccountGroups.map(\.id))
            expandedCalendarAccounts = Set(calendarAccountGroups.map(\.id))
            expandedMessageAccounts = Set(messageAccountGroups.map(\.id))
        }
        .onChange(of: sourceSearchQuery) { query in
            if query.isEmpty {
                return
            }
            expandedMailAccounts = Set(mailAccountGroups.map(\.id))
            expandedCalendarAccounts = Set(calendarAccountGroups.map(\.id))
            expandedMessageAccounts = Set(messageAccountGroups.map(\.id))
        }
        .onChange(of: filteredSources.map(\.id)) { ids in
            if let selectedSourceId, ids.contains(selectedSourceId) {
                return
            }
            self.selectedSourceId = ids.first
            expandedMailAccounts = Set(mailAccountGroups.map(\.id))
            expandedCalendarAccounts = Set(calendarAccountGroups.map(\.id))
            expandedMessageAccounts = Set(messageAccountGroups.map(\.id))
        }
        .toolbar {
            ToolbarItemGroup {
                Button(state.syncActivated ? "Pause Sync" : "Resume Sync") {
                    onToggleSync()
                }
                .labelStyle(.titleAndIcon)

                Button("Preferences") {
                    onOpenPreferences()
                }
            }
        }
    }

    private var sourceSearchQuery: String {
        sourceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSources: [ConnectedSource] {
        let query = sourceSearchQuery
        let sources = activeSources
        guard !query.isEmpty else { return sources }

        return sources.filter { source in
            source.sourceName.localizedCaseInsensitiveContains(query)
                || source.sourceType.localizedCaseInsensitiveContains(query)
                || source.status.localizedCaseInsensitiveContains(query)
                || source.accountId.localizedCaseInsensitiveContains(query)
                || mailboxName(for: source).localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedSource: ConnectedSource? {
        guard let selectedSourceId else { return nil }
        return activeSources.first { $0.id == selectedSourceId }
    }

    private var mailAccountGroups: [AccountGroup] {
        groupedAccounts(from: filteredSources.filter { $0.sourceType == "mail" }, sortByMailbox: true)
    }

    private var calendarAccountGroups: [AccountGroup] {
        groupedAccounts(from: filteredSources.filter { $0.sourceType == "calendar" }, sortByMailbox: false)
    }

    private var messageAccountGroups: [AccountGroup] {
        groupedAccounts(from: filteredSources.filter { $0.sourceType == "messages" }, sortByMailbox: false)
    }

    private var activeSources: [ConnectedSource] {
        sourceManager.sources
            .filter(\.enabled)
            .sorted { lhs, rhs in
                if lhs.status == rhs.status {
                    return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
                }
                return sortPriority(lhs.status) < sortPriority(rhs.status)
            }
    }

    private func groupedAccounts(from sources: [ConnectedSource], sortByMailbox: Bool) -> [AccountGroup] {
        let groups = Dictionary(grouping: sources, by: \.accountId)
        return groups.map { accountId, accountSources in
            let sortedSources: [ConnectedSource]
            if sortByMailbox {
                sortedSources = accountSources.sorted {
                    mailboxName(for: $0).localizedCaseInsensitiveCompare(mailboxName(for: $1)) == .orderedAscending
                }
            } else {
                sortedSources = accountSources.sorted {
                    $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending
                }
            }
            return AccountGroup(id: accountId, accountName: accountId, sources: sortedSources)
        }
        .sorted { $0.accountName.localizedCaseInsensitiveCompare($1.accountName) == .orderedAscending }
    }

    private func mailboxName(for source: ConnectedSource) -> String {
        guard source.sourceType == "mail" else { return source.sourceName }
        let parts = source.id.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3 {
            return String(parts.dropFirst(2).joined(separator: ":"))
        }
        return source.sourceName
    }

    private func groupTotalsText(_ sources: [ConnectedSource]) -> String {
        let synced = sources.reduce(0) { $0 + max(0, $1.totalSynced) }
        let total = sources.reduce(0) { $0 + max(0, max($1.totalEstimated, $1.totalSynced)) }
        return "\(synced)/\(total)"
    }

    private func sourcePath(for source: ConnectedSource) -> String {
        switch source.sourceType {
        case "mail":
            return "\(source.accountId) > \(mailboxName(for: source))"
        case "calendar":
            return "\(source.accountId) > \(source.sourceName)"
        case "messages":
            return "\(source.accountId) > Messages"
        default:
            return source.sourceName
        }
    }

    private func sortPriority(_ status: String) -> Int {
        switch status {
        case "error": return 0
        case "syncing": return 1
        case "pending": return 2
        case "current": return 3
        default: return 4
        }
    }
}

private struct AccountGroup: Identifiable {
    let id: String
    let accountName: String
    let sources: [ConnectedSource]
}

private struct SidebarAccountLabel: View {
    let title: String
    let systemImage: String
    let totalsText: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .foregroundColor(.secondary)
            Text(title)
                .lineLimit(1)
            Spacer()
            Text(totalsText)
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }
}

private struct SourceSidebarRow: View {
    let source: ConnectedSource
    let titleOverride: String?

    init(source: ConnectedSource, titleOverride: String? = nil) {
        self.source = source
        self.titleOverride = titleOverride
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundColor(statusColor)
            Text(titleOverride ?? source.sourceName)
                .lineLimit(1)
            Spacer()
            Text("\(source.totalSynced)/\(max(source.totalEstimated, source.totalSynced))")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
        }
    }

    private var iconName: String {
        switch source.sourceType {
        case "mail": return "envelope.fill"
        case "calendar": return "calendar"
        case "messages": return "message.fill"
        default: return "circle.fill"
        }
    }

    private var statusColor: Color {
        switch source.status {
        case "syncing": return .blue
        case "current": return .green
        case "error": return .red
        default: return .secondary
        }
    }
}

private struct SourceDetailView: View {
    let source: ConnectedSource
    let sourcePath: String
    let lastSync: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(sourcePath)
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Label(source.sourceName, systemImage: iconName)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text(source.status.capitalized)
                    .font(.caption.weight(.semibold))
                    .foregroundColor(statusColor)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Sync Progress")
                    .font(.headline)
                ProgressView(value: progressValue)
                    .progressViewStyle(.linear)
                Text("\(source.totalSynced) of \(progressTotal) synced")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            Group {
                detailRow(label: "Type", value: source.sourceType.capitalized)
                detailRow(label: "Account", value: source.accountId)
                detailRow(
                    label: "Synced",
                    value: relativeSyncText
                )
                if let error = source.lastError, !error.isEmpty {
                    detailRow(label: "Last Error", value: error, color: .red)
                }
            }
            Spacer()
        }
        .padding(24)
    }

    private var progressTotal: Int {
        max(source.totalEstimated, source.totalSynced)
    }

    private var progressValue: Double {
        guard progressTotal > 0 else { return 0 }
        return min(1.0, max(0.0, Double(source.totalSynced) / Double(progressTotal)))
    }

    private var iconName: String {
        switch source.sourceType {
        case "mail": return "envelope.fill"
        case "calendar": return "calendar"
        case "messages": return "message.fill"
        default: return "circle.fill"
        }
    }

    private var statusColor: Color {
        switch source.status {
        case "syncing": return .blue
        case "current": return .green
        case "error": return .red
        default: return .secondary
        }
    }

    private var relativeSyncText: String {
        guard let lastSync else { return "Never" }
        return lastSync.formatted(
            .relative(presentation: .named, unitsStyle: .abbreviated)
        )
    }

    @ViewBuilder
    private func detailRow(label: String, value: String, color: Color = .primary) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundColor(.secondary)
            Text(value)
                .foregroundColor(color)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.body)
    }
}
