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
                            ForEach(issue.repairActions) { action in
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
        case .enableAutomation(let kind):
            PlatformHelper.openAutomationSettings()
        case .retryActivation(let kind):
            Task {
                await session.enableSource(kind)
            }
        case .contactSupport(let kind):
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

// MARK: - Enhanced Source Card View with Repair Actions
struct EnhancedSourceCardView: View {
    let capability: SourceCapability
    let issues: [SourceIssue]
    @ObservedObject var session: AppSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Source status and primary actions
            HStack {
                Image(systemName: capability.kind.systemImage)
                    .font(.title2)
                    .foregroundColor(statusColor)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text(capability.displayName)
                        .font(.headline)
                    
                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                // Primary actions based on capability state only (no hard-coded repair)
                if capability.activation.isActive {
                    Button("Disable") {
                        Task {
                            await session.disableSource(capability.kind)
                        }
                    }
                    .buttonStyle(.bordered)
                } else {
                    // Enable button - repair actions handled by RepairActionsView
                    Button("Enable") {
                        Task {
                            await session.enableSource(capability.kind)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canEnable)
                }
            }
            
            // Authorization status
            if capability.authorization != .notRequired {
                HStack {
                    Image(systemName: authStatusIcon)
                        .foregroundColor(authStatusColor)
                    Text(authStatusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Availability status
            if case .unavailable(let reason) = capability.availability {
                HStack {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundColor(.orange)
                    Text("Unavailable: \(reason)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            // Repair actions from data model
            if !issues.isEmpty {
                Divider()
                RepairActionsView(issues: issues, session: session)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }
    
    // ... existing computed properties ...
    private var statusColor: Color {
        switch capability.activation {
        case .active: return .green
        case .activating: return .orange
        case .inactive: return .gray
        case .degraded: return .red
        }
    }
    
    private var statusText: String {
        switch capability.activation {
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
