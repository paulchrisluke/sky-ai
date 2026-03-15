import SwiftUI

class MenuBarState: ObservableObject {
    @Published var connection: String = "Connecting"
    @Published var lastSync: String = "-"
    @Published var syncActivated: Bool = true
}

struct MenuBarPopoverView: View {
    @ObservedObject var sourceManager: SourceManager
    @ObservedObject var state: MenuBarState
    let onClose: () -> Void
    let onToggleSync: () -> Void
    let onOpenDashboard: () -> Void
    let onOpenPreferences: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .foregroundColor(.primary)
                Text("Blawby")
                    .font(.headline)
                Spacer()
                Button(action: onOpenPreferences) {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.secondary)
                .help("Preferences")

                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(PlainButtonStyle())
                .foregroundColor(.secondary)
                .padding(.leading, 8)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Progress Section
            VStack(alignment: .leading, spacing: 12) {
                Text("Overall progress")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                let totalSyncedFloat = CGFloat(totalSynced)
                let totalEstimatedFloat = CGFloat(totalEstimated)
                let ratio = totalEstimated > 0 ? min(1.0, max(0.0, totalSyncedFloat / totalEstimatedFloat)) : 0.0

                HStack {
                    ProgressView(value: ratio)
                        .progressViewStyle(LinearProgressViewStyle())
                    Text(totalEstimated == 0 ? "Waiting..." : "\(Int(ratio * 100))%")
                        .font(.caption)
                        .frame(width: 40, alignment: .trailing)
                }

                Text("\(formatNumber(totalSynced)) / \(formatNumber(totalEstimated)) items synced")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()

            Divider()

            // Quick Actions
            VStack(alignment: .leading, spacing: 12) {
                Text("Quick actions")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                HStack(spacing: 8) {
                    Button(action: onToggleSync) {
                        Label(state.syncActivated ? "Pause Sync" : "Resume Sync", systemImage: state.syncActivated ? "pause.fill" : "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(action: onOpenDashboard) {
                        Label("Open Dashboard", systemImage: "rectangle.on.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Text("Active sources now live in the Dashboard window.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            
            Divider()
            
            // Footer
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("Connection:")
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 8, height: 8)
                    Text(state.connection)
                }
                .font(.caption)
                
                Text("Last sync: \(state.lastSync)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 320)
    }

    private var totalSynced: Int {
        sourceManager.sources.filter(\.enabled).reduce(0) { $0 + max(0, $1.totalSynced) }
    }

    private var totalEstimated: Int {
        sourceManager.sources.filter(\.enabled).reduce(0) { $0 + max(0, $1.totalEstimated) }
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

struct SourceRow: View {
    let source: ConnectedSource

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(statusColor)
                .frame(width: 20)
                
            VStack(alignment: .leading, spacing: 4) {
                Text(source.sourceName)
                    .font(.subheadline)
                    .lineLimit(1)
                
                let synced = max(0, source.totalSynced)
                let estimated = max(0, source.totalEstimated)
                let ratio = estimated > 0 ? CGFloat(synced) / CGFloat(estimated) : 0.0
                
                HStack {
                    if source.status == "current" {
                        ProgressView(value: estimated > 0 ? 1.0 : 0.0)
                            .progressViewStyle(LinearProgressViewStyle())
                            .accentColor(statusColor)
                        Text(estimated == 0 ? "waiting" : "100% ✓")
                            .font(.caption)
                            .frame(width: 60, alignment: .trailing)
                    } else if source.status == "syncing" {
                        ProgressView(value: ratio)
                            .progressViewStyle(LinearProgressViewStyle())
                            .accentColor(statusColor)
                        Text(estimated == 0 ? "waiting" : "\(Int(ratio * 100))%")
                            .font(.caption)
                            .frame(width: 30, alignment: .trailing)
                        Text("\(formatNumber(synced))/\(formatNumber(estimated))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    } else if source.status == "error" {
                        ProgressView(value: ratio)
                            .progressViewStyle(LinearProgressViewStyle())
                            .accentColor(statusColor)
                        Text("Error")
                            .font(.caption)
                            .foregroundColor(.red)
                            .frame(width: 60, alignment: .trailing)
                    } else {
                        ProgressView(value: 0.0)
                            .progressViewStyle(LinearProgressViewStyle())
                        Text("0%")
                            .font(.caption)
                            .frame(width: 30, alignment: .trailing)
                        Text("waiting")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 60, alignment: .trailing)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
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

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

/*
#Preview {
    MenuBarPopoverView(
        sourceManager: SourceManager(
            config: Config(workerUrl: "", apiKey: "", workspaceId: "", accountId: "", openaiApiKey: nil),
            localStore: try! LocalStore(baseDirectory: URL(fileURLWithPath: "/tmp")),
            mailWatcher: MailWatcher(configStore: try! ConfigStore(baseDirectory: URL(fileURLWithPath: "/tmp")), logger: .none),
            calendarWatcher: CalendarWatcher(config: Config(workerUrl: "", apiKey: "", workspaceId: "", accountId: "", openaiApiKey: nil), logger: .none),
            mailProcessor: MailProcessor(localStore: try! LocalStore(baseDirectory: URL(fileURLWithPath: "/tmp")), extractor: EntityExtractor(apiKey: nil, contactsReader: ContactsReader(localStore: try! LocalStore(baseDirectory: URL(fileURLWithPath: "/tmp")), logger: .none), logger: .none)),
            webSocketPublisher: WebSocketPublisher(config: Config(workerUrl: "", apiKey: "", workspaceId: "", accountId: "", openaiApiKey: nil), logger: .none),
            logger: .none
        ),
        state: MenuBarState(),
        onClose: { print("Closed") },
        onToggleSync: { print("Sync toggled") },
        onOpenDashboard: { print("Dashboard opened") },
        onOpenPreferences: { print("Preferences opened") }
    )
    .frame(width: 320)
}
*/
