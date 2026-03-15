import SwiftUI

struct DashboardView: View {
    @ObservedObject var sourceManager: SourceManager
    @ObservedObject var state: MenuBarState

    @State private var selectedSourceId: String?
    @State private var sourceSearch = ""

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSourceId) {
                ForEach(filteredSources, id: \.id) { source in
                    SourceSidebarRow(source: source)
                        .tag(source.id)
                }
            }
            .navigationTitle("Sources")
            .searchable(text: $sourceSearch, prompt: "Filter sources")
        } detail: {
            if let source = selectedSource {
                SourceDetailView(
                    source: source,
                    connection: state.connection,
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
            if selectedSourceId == nil {
                selectedSourceId = filteredSources.first?.id
            }
        }
        .onChange(of: filteredSources.map(\.id)) { ids in
            if let selectedSourceId, ids.contains(selectedSourceId) {
                return
            }
            self.selectedSourceId = ids.first
        }
    }

    private var filteredSources: [ConnectedSource] {
        let query = sourceSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        let sources = activeSources
        guard !query.isEmpty else { return sources }

        return sources.filter { source in
            source.sourceName.localizedCaseInsensitiveContains(query)
                || source.sourceType.localizedCaseInsensitiveContains(query)
                || source.status.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedSource: ConnectedSource? {
        guard let selectedSourceId else { return nil }
        return activeSources.first { $0.id == selectedSourceId }
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

private struct SourceSidebarRow: View {
    let source: ConnectedSource

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .foregroundColor(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(source.sourceName)
                    .lineLimit(1)
                Text(source.status.capitalized)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
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
    let connection: String
    let lastSync: String

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Label(source.sourceName, systemImage: iconName)
                    .font(.title2.weight(.semibold))
                Spacer()
                StatusBadge(status: source.status)
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
                detailRow(label: "Connection", value: connection)
                detailRow(label: "Last Sync", value: lastSync)
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

private struct StatusBadge: View {
    let status: String

    var body: some View {
        Text(status.capitalized)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(backgroundColor.opacity(0.18))
            .foregroundColor(backgroundColor)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch status {
        case "syncing": return .blue
        case "current": return .green
        case "error": return .red
        default: return .secondary
        }
    }
}
