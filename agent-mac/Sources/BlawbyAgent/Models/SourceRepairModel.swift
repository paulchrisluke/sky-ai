import Foundation
import AppKit

// MARK: - Source Repair Actions
enum SourceRepairAction: Identifiable {
    case requestPermission(SourceKind)
    case openSystemSettings(SourceKind)
    case enableAutomation(SourceKind)
    case retryActivation(SourceKind)
    case contactSupport(SourceKind)
    
    var id: String {
        switch self {
        case .requestPermission(let kind): return "request_permission_\(kind.rawValue)"
        case .openSystemSettings(let kind): return "open_settings_\(kind.rawValue)"
        case .enableAutomation(let kind): return "enable_automation_\(kind.rawValue)"
        case .retryActivation(let kind): return "retry_activation_\(kind.rawValue)"
        case .contactSupport(let kind): return "contact_support_\(kind.rawValue)"
        }
    }
    
    var title: String {
        switch self {
        case .requestPermission: return "Request Permission"
        case .openSystemSettings: return "Open Settings"
        case .enableAutomation: return "Enable Automation"
        case .retryActivation: return "Retry"
        case .contactSupport: return "Get Help"
        }
    }
    
    var description: String {
        switch self {
        case .requestPermission(let kind):
            return "Allow Blawby to access your \(kind.displayName)"
        case .openSystemSettings(let kind):
            return "Open System Settings to fix \(kind.displayName) access"
        case .enableAutomation(let kind):
            return "Enable Apple Events automation for \(kind.displayName)"
        case .retryActivation(let kind):
            return "Try activating \(kind.displayName) again"
        case .contactSupport(let kind):
            return "Get help with \(kind.displayName) setup"
        }
    }
}

// MARK: - Per-Source Issue Model
struct SourceIssue: Identifiable {
    let id: String
    let kind: SourceKind
    let severity: IssueSeverity
    let category: IssueCategory
    let title: String
    let description: String
    let repairActions: [SourceRepairAction]
    
    init(
        kind: SourceKind,
        severity: IssueSeverity,
        category: IssueCategory,
        title: String,
        description: String,
        repairActions: [SourceRepairAction] = []
    ) {
        self.id = "\(kind.rawValue)_\(category.rawValue)_\(title)_\(description)"
        self.kind = kind
        self.severity = severity
        self.category = category
        self.title = title
        self.description = description
        self.repairActions = repairActions
    }
}

enum IssueSeverity: String, CaseIterable {
    case error = "error"
    case warning = "warning"
    case info = "info"
    
    var displayName: String {
        switch self {
        case .error: return "Error"
        case .warning: return "Warning"
        case .info: return "Info"
        }
    }
}

enum IssueCategory: String, CaseIterable {
    case authorization = "authorization"
    case availability = "availability"
    case activation = "activation"
    case configuration = "configuration"
    case network = "network"
    case system = "system"
    
    var displayName: String {
        switch self {
        case .authorization: return "Authorization"
        case .availability: return "Availability"
        case .activation: return "Activation"
        case .configuration: return "Configuration"
        case .network: return "Network"
        case .system: return "System"
        }
    }
}

// MARK: - Platform Helper for System Actions
struct PlatformHelper {
    static func openSystemSettings(for kind: SourceKind) {
        let url: URL
        switch kind {
        case .calendar:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        case .contacts:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")!
        case .mail:
            url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        }
        NSWorkspace.shared.open(url)
    }
    
    static func openAutomationSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        NSWorkspace.shared.open(url)
    }
    
    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
    
    static func openSupportURL() {
        if let url = URL(string: "https://support.blawby.ai") {
            NSWorkspace.shared.open(url)
        }
    }
}
