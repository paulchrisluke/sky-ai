import SwiftUI

struct DashboardView: View {
    @ObservedObject var sourceManager: SourceManager
    @ObservedObject var state: MenuBarState

    @State private var selectedCategory: SourceCategory?

    var body: some View {
        NavigationSplitView {
            List(SourceCategory.allCases, id: \.self, selection: Binding(
                get: { selectedCategory },
                set: { category in
                    selectedCategory = category
                }
            )) { category in
                Label(category.title, systemImage: category.iconName)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
        } detail: {
            if let category = selectedCategory {
                CategoryDetailView(
                    category: category,
                    groups: accountGroups(for: category),
                    lastSync: state.lastSync
                )
            } else {
                DashboardOverviewView(
                    sources: activeSources,
                    lastSync: state.lastSync
                )
            }
        }
    }



    private func sources(for category: SourceCategory) -> [ConnectedSource] {
        activeSources.filter { $0.sourceType == category.sourceType }
    }

    private func accountGroups(for category: SourceCategory) -> [AccountGroup] {
        groupedAccounts(from: sources(for: category), sortByMailbox: category == .mail)
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

    private func sourceDisplayName(for source: ConnectedSource) -> String {
        if source.sourceType == SourceCategory.mail.sourceType {
            return mailboxName(for: source)
        }
        return source.sourceName
    }

    private func mailboxName(for source: ConnectedSource) -> String {
        guard source.sourceType == SourceCategory.mail.sourceType else { return source.sourceName }
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
        NavigationStack {
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
            .navigationTitle("Overview")
            .toolbarBackground(.visible, for: .automatic)
            .toolbarBackground(.thinMaterial, for: .automatic)
        }
        .navigationTitle("Dashboard")
    }
}

private struct CategoryDetailView: View {
    let category: SourceCategory
    let groups: [AccountGroup]
    let lastSync: Date?

    private var sources: [ConnectedSource] {
        groups.flatMap(\.sources)
    }

    private var synced: Int {
        sources.reduce(0) { $0 + max(0, $1.totalSynced) }
    }

    private var total: Int {
        sources.reduce(0) { $0 + max(0, max($1.totalEstimated, $1.totalSynced)) }
    }

    private var progressValue: Double {
        guard total > 0 else { return 0 }
        return min(1.0, max(0.0, Double(synced) / Double(total)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack {
                        Label(category.title, systemImage: category.iconName)
                            .font(.title2.weight(.semibold))
                        Spacer()
                        Text("\(groups.count) accounts")
                            .font(.caption.weight(.semibold))
                            .foregroundColor(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Category Sync Progress")
                            .font(.headline)
                        ProgressView(value: progressValue)
                            .progressViewStyle(.linear)
                        Text("\(synced) of \(total) synced across \(sources.count) sources")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Accounts")
                            .font(.headline)
                        ForEach(groups) { group in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Label(group.accountName, systemImage: "person.crop.circle")
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Text(groupTotalsText(group.sources))
                                        .font(.caption.monospacedDigit())
                                        .foregroundColor(.secondary)
                                }

                                ForEach(group.sources, id: \.id) { source in
                                    HStack(spacing: 10) {
                                        Image(systemName: iconName(for: source.sourceType))
                                            .foregroundColor(statusColor(for: source.status))
                                        Text(sourceName(for: source))
                                            .lineLimit(1)
                                        Spacer()
                                        Text("\(source.totalSynced)/\(max(source.totalEstimated, source.totalSynced))")
                                            .font(.caption.monospacedDigit())
                                            .foregroundColor(.secondary)
                                    }
                                    .padding(.leading, 20)
                                }
                            }
                        }
                    }

                    Divider()

                    HStack {
                        Text("Last Sync")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(relativeSyncText)
                    }
                    .font(.body)
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(category.title)
            .toolbarBackground(.visible, for: .automatic)
            .toolbarBackground(.thinMaterial, for: .automatic)
        }
    }

    private func sourceName(for source: ConnectedSource) -> String {
        if category == .mail {
            let parts = source.id.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count >= 3 {
                return String(parts.dropFirst(2).joined(separator: ":"))
            }
        }
        return source.sourceName
    }

    private func groupTotalsText(_ sources: [ConnectedSource]) -> String {
        let synced = sources.reduce(0) { $0 + max(0, $1.totalSynced) }
        let total = sources.reduce(0) { $0 + max(0, max($1.totalEstimated, $1.totalSynced)) }
        return "\(synced)/\(total)"
    }

    private var relativeSyncText: String {
        guard let lastSync else { return "Never" }
        return lastSync.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    private func iconName(for sourceType: String) -> String {
        switch sourceType {
        case SourceCategory.mail.sourceType: return "envelope.fill"
        case SourceCategory.calendar.sourceType: return "calendar"
        case SourceCategory.messages.sourceType: return "message.fill"
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
}

private enum SourceCategory: String, CaseIterable, Identifiable, Hashable {
    case mail
    case messages
    case calendar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .mail: return "Mail"
        case .messages: return "Messages"
        case .calendar: return "Calendar"
        }
    }

    var sourceType: String {
        switch self {
        case .mail: return "mail"
        case .messages: return "messages"
        case .calendar: return "calendar"
        }
    }

    var iconName: String {
        switch self {
        case .mail: return "tray.full"
        case .messages: return "message"
        case .calendar: return "calendar"
        }
    }
}

private struct AccountGroup: Identifiable {
    let id: String
    let accountName: String
    let sources: [ConnectedSource]
}

