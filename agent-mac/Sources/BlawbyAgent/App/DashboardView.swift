import AppKit
import SwiftUI

struct DashboardView: View {
    @ObservedObject var sourceManager: SourceManager
    @ObservedObject var state: MenuBarState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Overview")
                        .font(.title2.weight(.semibold))
                    Text("\(formatNumber(totalSynced)) / \(formatNumber(totalEstimated)) items synced")
                        .font(.headline)
                    HStack(spacing: 12) {
                        Label(state.connection, systemImage: "dot.radiowaves.left.and.right")
                            .foregroundColor(connectionColor)
                        Text("Last sync: \(state.lastSync)")
                            .foregroundColor(.secondary)
                    }
                    .font(.subheadline)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Active Sources")
                        .font(.title3.weight(.semibold))

                    if activeSources.isEmpty {
                        Text("No active sources.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(activeSources, id: \.id) { source in
                            SourceRow(source: source)
                            Divider()
                        }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var totalSynced: Int {
        sourceManager.sources.filter(\.enabled).reduce(0) { $0 + max(0, $1.totalSynced) }
    }

    private var totalEstimated: Int {
        sourceManager.sources.filter(\.enabled).reduce(0) { $0 + max(0, $1.totalEstimated) }
    }

    private var activeSources: [ConnectedSource] {
        let enabled = sourceManager.sources.filter(\.enabled)
        let prioritized = enabled
            .filter { $0.totalEstimated > 0 }
            .sorted { lhs, rhs in
                if lhs.totalEstimated == rhs.totalEstimated {
                    return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
                }
                return lhs.totalEstimated > rhs.totalEstimated
            }

        let pending = enabled
            .filter { $0.totalEstimated == 0 && ($0.status == "pending" || $0.status == "syncing") }
            .sorted { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending }

        return prioritized + pending
    }

    private var connectionColor: Color {
        let lowered = state.connection.lowercased()
        if lowered.hasPrefix("connected") {
            return .green
        } else if lowered.hasPrefix("reconnecting") || lowered.hasPrefix("connecting") {
            return .yellow
        } else {
            return .red
        }
    }

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

final class DashboardWindowController: NSWindowController {
    convenience init(sourceManager: SourceManager, state: MenuBarState) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        self.init(window: window)
        setup(sourceManager: sourceManager, state: state)
    }

    private func setup(sourceManager: SourceManager, state: MenuBarState) {
        window?.title = "Blawby Dashboard"
        window?.minSize = NSSize(width: 640, height: 420)
        window?.setFrameAutosaveName("BlawbyDashboardWindow")
        window?.contentViewController = NSHostingController(
            rootView: DashboardView(sourceManager: sourceManager, state: state)
        )
    }
}
