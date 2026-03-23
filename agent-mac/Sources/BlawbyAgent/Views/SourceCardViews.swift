import SwiftUI

// MARK: - Repair Actions View
private struct RepairActionsView: View {
    let issues: [SourceIssue]
    @ObservedObject var session: AppSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(issues) { issue in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Image(systemName: severityIcon(for: issue.severity))
                            .foregroundColor(severityColor(for: issue.severity))
                        
                        Text(issue.title)
                            .font(.subheadline)
                            .fontWeight(.medium)
                        
                        Spacer()
                    }
                    
                    Text(issue.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    // Repair actions
                    if !issue.repairActions.isEmpty {
                        HStack {
                            ForEach(issue.repairActions, id: \.self) { action in
                                Button(action.title) {
                                    executeRepairAction(action)
                                }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
    
    private func executeRepairAction(_ action: SourceRepairAction) {
        switch action {
        case .requestPermission(let kind):
            Task {
                await session.enableSource(kind)
            }
        case .openSystemSettings(let kind):
            PlatformHelper.openSystemSettings(for: kind)
        case .enableAutomation(_):
            PlatformHelper.openAutomationSettings()
        case .retryActivation(let kind):
            Task {
                await session.enableSource(kind)
            }
        case .contactSupport(_):
            // Open support URL or help
            PlatformHelper.openSupportURL()
        }
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

// MARK: - Expandable Source Row with Inline Details
struct ExpandableSourceRow: View {
    let capability: ResolvedSourceCapability
    let issues: [SourceIssue]
    @ObservedObject var session: AppSession
    @State private var isExpanded = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Compact row (always visible)
            HStack {
                Image(systemName: capability.kind.systemImage)
                    .font(.title2)
                    .foregroundColor(statusColor)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(capability.displayName)
                        .font(.body)
                        .fontWeight(.medium)
                    
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Expansion indicator
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.3)) {
                    isExpanded.toggle()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            
            // Expanded details (inline)
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider()
                    
                    // Status details
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Status")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(statusText)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        
                        // Authorization status
                        if capability.authorization != .notRequired {
                            HStack {
                                Image(systemName: authStatusIcon)
                                    .font(.caption)
                                    .foregroundColor(authStatusColor)
                                Text(authStatusText)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                        
                        // Availability status
                        if case .unavailable(let reason) = capability.availability {
                            HStack {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundColor(.orange)
                                Text("Unavailable: \(reason)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                        }
                    }
                    
                    // Actions
                    HStack(spacing: 12) {
                        if capability.runtimeStatus == .active {
                            Button("Disable") {
                                Task {
                                    await session.disableSource(capability.kind)
                                }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button("Enable") {
                                Task {
                                    await session.enableSource(capability.kind)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canEnable)
                        }
                    }
                    
                    // Repair actions
                    if !issues.isEmpty {
                        Divider()
                        RepairActionsView(issues: issues, session: session)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // Computed properties (same as before)
    private var statusColor: Color {
        switch capability.runtimeStatus {
        case .active: return .green
        case .activating: return .orange
        case .inactive: return .gray
        case .degraded: return .red
        }
    }
    
    private var statusText: String {
        switch capability.runtimeStatus {
        case .active: return "Active"
        case .activating: return "Activating..."
        case .inactive: return "Inactive"
        case .degraded(let reason): return "Degraded: \(reason)"
        }
    }
    
    private var canEnable: Bool {
        return capability.availability.isAvailable && 
               capability.authorization != .denied &&
               capability.authorization != .restricted
    }
    
    private var authStatusIcon: String {
        switch capability.authorization {
        case .authorized: return "checkmark.shield"
        case .denied: return "xmark.shield"
        case .restricted: return "minus.shield"
        case .notDetermined: return "questionmark.shield"
        case .notRequired: return "shield"
        }
    }
    
    private var authStatusColor: Color {
        switch capability.authorization {
        case .authorized: return .green
        case .denied: return .red
        case .restricted: return .orange
        case .notDetermined: return .gray
        case .notRequired: return .blue
        }
    }
    
    private var authStatusText: String {
        switch capability.authorization {
        case .authorized: return "Authorized"
        case .denied: return "Access denied"
        case .restricted: return "Access restricted"
        case .notDetermined: return "Not requested"
        case .notRequired: return "Not required"
        }
    }
}
