import SwiftUI

struct DashboardView: View {
    @ObservedObject var sourceManager: SourceManager
    @ObservedObject var state: MenuBarState

    @State private var selection: SidebarSelection?
    @State private var sourceSearch = ""
    @State private var expandedMailAccounts: Set<String> = []
    @State private var expandedCalendarAccounts: Set<String> = []
    @State private var expandedMessageAccounts: Set<String> = []

    var body: some View {
        NavigationSplitView {
            List {
                Section("Smart Mailboxes") {
                    ForEach(visibleSmartMailboxKinds, id: \.rawValue) { kind in
                        smartMailboxButton(kind: kind)
                    }
                }

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
                                sourceButton(source: source, titleOverride: mailboxName(for: source))
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
                                sourceButton(source: source)
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
                                sourceButton(source: source)
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
            .listStyle(.sidebar)
            .navigationTitle("Sources")
            .searchable(text: $sourceSearch, prompt: "Filter sources")
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } detail: {
            if let smartKind = selectedSmartMailboxKind {
                SmartMailboxDetailView(
                    kind: smartKind,
                    sources: smartMailboxSources(for: smartKind),
                    lastSync: state.lastSync
                )
            } else if let source = selectedSource {
                SourceDetailView(
                    source: source,
                    sourcePath: sourcePath(for: source),
                    lastSync: state.lastSync
                )
            } else {
                DashboardOverviewView(
                    sources: activeSources,
                    lastSync: state.lastSync
                )
            }
        }
        .onAppear {
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
            if case let .source(selectedSourceId)? = selection, ids.contains(selectedSourceId) {
                // Keep valid source selection.
            } else {
                selection = nil
            }
            expandedMailAccounts = Set(mailAccountGroups.map(\.id))
            expandedCalendarAccounts = Set(calendarAccountGroups.map(\.id))
            expandedMessageAccounts = Set(messageAccountGroups.map(\.id))
        }
    }

    private func smartMailboxButton(kind: SmartMailboxKind) -> some View {
        Button {
            selection = .smart(kind.rawValue)
        } label: {
            SmartMailboxSidebarRow(
                kind: kind,
                count: smartMailboxSources(for: kind).count
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(selection == .smart(kind.rawValue) ? Color.accentColor.opacity(0.18) : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    private func sourceButton(source: ConnectedSource, titleOverride: String? = nil) -> some View {
        Button {
            selection = .source(source.id)
        } label: {
            SourceSidebarRow(source: source, titleOverride: titleOverride)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(selection == .source(source.id) ? Color.accentColor.opacity(0.18) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
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
        guard case let .source(selectedSourceId)? = selection else { return nil }
        return activeSources.first { $0.id == selectedSourceId }
    }

    private var selectedSmartMailboxKind: SmartMailboxKind? {
        guard case let .smart(rawValue)? = selection else { return nil }
        return SmartMailboxKind(rawValue: rawValue)
    }

    private var visibleSmartMailboxKinds: [SmartMailboxKind] {
        let query = sourceSearchQuery.lowercased()
        if query.isEmpty { return SmartMailboxKind.allCases }
        return SmartMailboxKind.allCases.filter { $0.displayName.lowercased().contains(query) }
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

    private func smartMailboxSources(for kind: SmartMailboxKind) -> [ConnectedSource] {
        switch kind {
        case .allInboxes:
            return activeSources.filter { $0.sourceType == "mail" }
        case .needsAction:
            return activeSources.filter { $0.status == "error" || $0.status == "pending" || $0.status == "syncing" }
        case .errors:
            return activeSources.filter { $0.status == "error" }
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

private struct DashboardOverviewView: View {
    let sources: [ConnectedSource]
    let lastSync: Date?

    private var syncedTotal: Int {
        sources.reduce(0) { $0 + max(0, $1.totalSynced) }
    }

    private var estimatedTotal: Int {
        sources.reduce(0) { $0 + max(0, max($1.totalEstimated, $1.totalSynced)) }
    }

    private var progressValue: Double {
        guard estimatedTotal > 0 else { return 0 }
        return min(1, max(0, Double(syncedTotal) / Double(estimatedTotal)))
    }

    private var groupedStatuses: [(label: String, count: Int)] {
        let labels = ["error", "syncing", "pending", "current"]
        return labels.map { label in
            (label.capitalized, sources.filter { $0.status == label }.count)
        }
    }

    private var needsAttention: [ConnectedSource] {
        sources
            .filter { $0.status != "current" }
            .sorted { lhs, rhs in
                let left = max(0, max(lhs.totalEstimated, lhs.totalSynced) - lhs.totalSynced)
                let right = max(0, max(rhs.totalEstimated, rhs.totalSynced) - rhs.totalSynced)
                return left > right
            }
            .prefix(8)
            .map { $0 }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Overview")
                        .font(.title2.weight(.semibold))
                    Spacer()
                    if let lastSync {
                        Text("Last sync \(lastSync, style: .relative)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Global Sync Progress")
                        .font(.headline)
                    ProgressView(value: progressValue)
                        .progressViewStyle(.linear)
                    Text("\(syncedTotal) of \(estimatedTotal) synced across \(sources.count) sources")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Status Breakdown")
                        .font(.headline)
                    ForEach(groupedStatuses, id: \.label) { row in
                        HStack {
                            Text(row.label)
                            Spacer()
                            Text("\(row.count)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Needs Attention")
                        .font(.headline)
                    if needsAttention.isEmpty {
                        Text("All sources are current.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(needsAttention, id: \.id) { source in
                            HStack {
                                Text(source.sourceName)
                                    .lineLimit(1)
                                Spacer()
                                Text(source.status.capitalized)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private enum SidebarSelection: Hashable {
    case smart(String)
    case source(String)
}

private enum SmartMailboxKind: String, CaseIterable {
    case allInboxes = "all_inboxes"
    case needsAction = "needs_action"
    case errors = "errors"

    var displayName: String {
        switch self {
        case .allInboxes: return "All Inboxes"
        case .needsAction: return "Needs Action"
        case .errors: return "Errors"
        }
    }

    var iconName: String {
        switch self {
        case .allInboxes: return "tray.full"
        case .needsAction: return "exclamationmark.bubble"
        case .errors: return "xmark.octagon"
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

private struct SmartMailboxSidebarRow: View {
    let kind: SmartMailboxKind
    let count: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: kind.iconName)
                .foregroundColor(.secondary)
            Text(kind.displayName)
            Spacer()
            Text("\(count)")
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

private struct SmartMailboxDetailView: View {
    let kind: SmartMailboxKind
    let sources: [ConnectedSource]
    let lastSync: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Smart Mailboxes > \(kind.displayName)")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack {
                Label(kind.displayName, systemImage: kind.iconName)
                    .font(.title2.weight(.semibold))
                Spacer()
                Text("\(sources.count) sources")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Aggregate Sync Progress")
                    .font(.headline)
                ProgressView(value: aggregateProgressValue)
                    .progressViewStyle(.linear)
                Text("\(aggregateSynced) of \(aggregateTotal) synced")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Divider()

            if sources.isEmpty {
                Text("No sources match this smart mailbox.")
                    .foregroundColor(.secondary)
            } else if kind == .allInboxes {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Folder Aggregates")
                        .font(.headline)
                    ForEach(allInboxFolderGroups) { folder in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(folder.folderName, systemImage: "tray")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(folder.synced)/\(folder.total)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundColor(.secondary)
                            }
                            .padding(.bottom, 2)

                            ForEach(folder.accounts) { account in
                                HStack(spacing: 10) {
                                    Image(systemName: "person.crop.circle")
                                        .foregroundColor(.secondary)
                                    Text(account.accountId)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Spacer()
                                    Text("\(account.synced)/\(account.total)")
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }
                                .padding(.leading, 20)
                            }
                        }
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Included Sources")
                        .font(.headline)
                    ForEach(sources, id: \.id) { source in
                        HStack(spacing: 10) {
                            Image(systemName: iconName(for: source.sourceType))
                                .foregroundColor(statusColor(for: source.status))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.sourceName)
                                Text(source.accountId)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Text("\(source.totalSynced)/\(max(source.totalEstimated, source.totalSynced))")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Divider()
            detailRow(label: "Last Sync", value: relativeSyncText)
            Spacer()
        }
        .padding(24)
    }

    private var aggregateSynced: Int {
        sources.reduce(0) { $0 + max(0, $1.totalSynced) }
    }

    private var aggregateTotal: Int {
        sources.reduce(0) { $0 + max(0, max($1.totalEstimated, $1.totalSynced)) }
    }

    private var aggregateProgressValue: Double {
        guard aggregateTotal > 0 else { return 0 }
        return min(1.0, max(0.0, Double(aggregateSynced) / Double(aggregateTotal)))
    }

    private var allInboxFolderGroups: [FolderAggregateGroup] {
        let mailSources = sources.filter { $0.sourceType == "mail" }
        let grouped = Dictionary(grouping: mailSources) { source in
            mailboxName(for: source)
        }

        var folderResults: [FolderAggregateGroup] = []
        for (folderName, folderSources) in grouped {
            let accountGroups = Dictionary(grouping: folderSources, by: \.accountId)
            var accountRows: [FolderAggregateAccount] = []
            accountRows.reserveCapacity(accountGroups.count)

            for (accountId, accountSources) in accountGroups {
                let synced = accountSources.reduce(0) { $0 + max(0, $1.totalSynced) }
                let total = accountSources.reduce(0) { $0 + max(0, max($1.totalEstimated, $1.totalSynced)) }
                accountRows.append(FolderAggregateAccount(id: accountId, accountId: accountId, synced: synced, total: total))
            }
            accountRows.sort { $0.accountId.localizedCaseInsensitiveCompare($1.accountId) == .orderedAscending }

            let synced = accountRows.reduce(0) { $0 + $1.synced }
            let total = accountRows.reduce(0) { $0 + $1.total }
            folderResults.append(
                FolderAggregateGroup(
                    id: folderName,
                    folderName: folderName,
                    synced: synced,
                    total: total,
                    accounts: accountRows
                )
            )
        }

        return folderResults.sorted { $0.folderName.localizedCaseInsensitiveCompare($1.folderName) == .orderedAscending }
    }

    private func mailboxName(for source: ConnectedSource) -> String {
        let parts = source.id.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 3 {
            return String(parts.dropFirst(2).joined(separator: ":"))
        }
        return source.sourceName
    }

    private var relativeSyncText: String {
        guard let lastSync else { return "Never" }
        return lastSync.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func iconName(for sourceType: String) -> String {
        switch sourceType {
        case "mail": return "envelope.fill"
        case "calendar": return "calendar"
        case "messages": return "message.fill"
        default: return "circle.fill"
        }
    }

    private func statusColor(for status: String) -> Color {
        switch status {
        case "syncing": return .blue
        case "current": return .green
        case "error": return .red
        default: return .secondary
        }
    }

    @ViewBuilder
    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .frame(width: 110, alignment: .leading)
                .foregroundColor(.secondary)
            Text(value)
                .textSelection(.enabled)
            Spacer()
        }
        .font(.body)
    }
}

private struct FolderAggregateGroup: Identifiable {
    let id: String
    let folderName: String
    let synced: Int
    let total: Int
    let accounts: [FolderAggregateAccount]
}

private struct FolderAggregateAccount: Identifiable {
    let id: String
    let accountId: String
    let synced: Int
    let total: Int
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
