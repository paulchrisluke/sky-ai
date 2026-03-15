import SwiftUI
import Combine

@MainActor
final class SourcesViewModel: ObservableObject {
    @Published private(set) var sources: [ConnectedSource] = []

    private let sourceManager: SourceManager
    private var cancellables: Set<AnyCancellable> = []

    init(sourceManager: SourceManager) {
        self.sourceManager = sourceManager
        self.sources = sourceManager.sources

        sourceManager.$sources
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                self?.sources = value
            }
            .store(in: &cancellables)
    }

    func groupedSources() -> [(String, [ConnectedSource])] {
        let groups = Dictionary(grouping: sources) { source in
            switch source.sourceType {
            case "mail": return "Mail"
            case "calendar": return "Calendar"
            case "messages": return "Messages"
            default: return "Other"
            }
        }

        let order = ["Mail", "Calendar", "Messages", "Other"]
        return order.compactMap { key in
            guard let items = groups[key], !items.isEmpty else { return nil }
            return (key, items.sorted { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending })
        }
    }

    func setEnabled(sourceId: String, enabled: Bool) {
        Task {
            await sourceManager.setEnabled(sourceId, enabled: enabled)
        }
    }

    func progressText(for source: ConnectedSource) -> String {
        if !source.enabled {
            return "Paused"
        }
        if source.status == "error" {
            return source.lastError.map { "Error: \($0)" } ?? "Error"
        }
        if source.status == "current" {
            return "✓ Current"
        }

        let synced = max(0, source.totalSynced)
        let estimated = max(0, source.totalEstimated)
        let pct: Int
        if estimated <= 0 {
            pct = 0
        } else {
            pct = Int((Double(synced) / Double(estimated) * 100.0).rounded())
        }
        return "Synced \(formatNumber(synced)) / \(formatNumber(estimated)) (\(pct)%)"
    }

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct SourcesView: View {
    @StateObject private var viewModel: SourcesViewModel

    init(sourceManager: SourceManager) {
        _viewModel = StateObject(wrappedValue: SourcesViewModel(sourceManager: sourceManager))
    }

    var body: some View {
        List {
            ForEach(viewModel.groupedSources(), id: \.0) { group, items in
                Section(group) {
                    ForEach(items, id: \.id) { source in
                        HStack(spacing: 12) {
                            Toggle("", isOn: Binding(
                                get: { source.enabled },
                                set: { enabled in
                                    viewModel.setEnabled(sourceId: source.id, enabled: enabled)
                                }
                            ))
                            .toggleStyle(.switch)
                            .labelsHidden()

                            VStack(alignment: .leading, spacing: 2) {
                                Text(source.sourceName)
                                    .font(.body)
                                Text(viewModel.progressText(for: source))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}
