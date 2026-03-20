import Foundation
import SwiftUI

// MARK: - Core Boot State (Phase 2)
enum AppBootState {
    case launching
    case setupRequired(BootstrapContext, [SourceCapability], [StartupIssue])
    case ready(BootstrapContext, [SourceKind: ActiveSource])
    case degraded(BootstrapContext, [SourceKind: ActiveSource], [StartupIssue])
    case fatal(FatalStartupIssue)
}

// MARK: - Setup Model (Phase 2 - may be deprecated)
struct SetupModel {
    let context: BootstrapContext
    let sourceCapabilities: [SourceCapability]
    let hasCompletedFirstRun: Bool
}

// MARK: - Source Capability Model
enum SourceKind: String, CaseIterable {
    case mail = "mail"
    case calendar = "calendar"
    case contacts = "contacts"
}

enum SourceAvailability: Equatable {
    case available
    case unavailable(reason: String)
}

enum SourceAuthorizationStatus: Equatable {
    case notRequired
    case notDetermined
    case authorized
    case denied
    case restricted
}

enum SourceActivationStatus: Equatable {
    case inactive
    case activating
    case active
    case degraded(reason: String)
}

struct SourceCapability: Identifiable {
    let id: String
    let kind: SourceKind
    let displayName: String
    let availability: SourceAvailability
    let authorization: SourceAuthorizationStatus
    let activation: SourceActivationStatus
    let isRequiredForCoreValue: Bool
    let canDefer: Bool
    
    init(kind: SourceKind, displayName: String, availability: SourceAvailability, authorization: SourceAuthorizationStatus, activation: SourceActivationStatus, isRequiredForCoreValue: Bool, canDefer: Bool) {
        self.id = kind.rawValue
        self.kind = kind
        self.displayName = displayName
        self.availability = availability
        self.authorization = authorization
        self.activation = activation
        self.isRequiredForCoreValue = isRequiredForCoreValue
        self.canDefer = canDefer
    }
}

// MARK: - Error Models
enum StartupIssue: Identifiable {
    case sourceUnavailable(SourceKind, reason: String)
    case authorizationDenied(SourceKind)
    case activationFailed(SourceKind, reason: String)
    case partialDependencyFailure(component: String, reason: String)
    
    var id: String {
        switch self {
        case .sourceUnavailable(let kind, let reason):
            return "source_unavailable_\(kind.rawValue)_\(reason.hashValue)"
        case .authorizationDenied(let kind):
            return "auth_denied_\(kind.rawValue)"
        case .activationFailed(let kind, let reason):
            return "activation_failed_\(kind.rawValue)_\(reason.hashValue)"
        case .partialDependencyFailure(let component, let reason):
            return "dependency_failed_\(component)_\(reason.hashValue)"
        }
    }
}

enum FatalStartupIssue: Identifiable {
    case storageInitializationFailed(String)
    case configurationLoadFailed(String)
    case loggerInitializationFailed(String)
    
    var id: String {
        switch self {
        case .storageInitializationFailed(let reason):
            return "storage_failed_\(reason.hashValue)"
        case .configurationLoadFailed(let reason):
            return "config_failed_\(reason.hashValue)"
        case .loggerInitializationFailed(let reason):
            return "logger_failed_\(reason.hashValue)"
        }
    }
}

// MARK: - Menu State
enum MenuState {
    case launching
    case setupRequired
    case ready
    case degraded
    case fatal
}

// MARK: - Active Source Runtime
struct ActiveSource {
    let kind: SourceKind
    let stop: @Sendable () async -> Void
}

// MARK: - Source Provider Protocol
protocol SourceProvider {
    var kind: SourceKind { get }
    func discover(in context: BootstrapContext) async -> SourceCapability
    func activate(in context: BootstrapContext) async throws -> ActiveSource
}

// MARK: - Activation State Persistence
class ActivationStateStore {
    private let userDefaults = UserDefaults.standard
    
    private func key(for sourceKind: SourceKind) -> String {
        return "BlawbyActivation_\(sourceKind.rawValue)"
    }
    
    private func skippedKey(for sourceKind: SourceKind) -> String {
        return "BlawbySkipped_\(sourceKind.rawValue)"
    }
    
    var onboardingCompleted: Bool {
        get { userDefaults.bool(forKey: "BlawbyOnboardingCompleted") }
        set { userDefaults.set(newValue, forKey: "BlawbyOnboardingCompleted") }
    }
    
    func isEnabled(_ sourceKind: SourceKind) -> Bool {
        return userDefaults.bool(forKey: key(for: sourceKind))
    }
    
    func setEnabled(_ sourceKind: SourceKind, enabled: Bool) {
        userDefaults.set(enabled, forKey: key(for: sourceKind))
    }
    
    func isSkipped(_ sourceKind: SourceKind) -> Bool {
        return userDefaults.bool(forKey: skippedKey(for: sourceKind))
    }
    
    func setSkipped(_ sourceKind: SourceKind, skipped: Bool) {
        userDefaults.set(skipped, forKey: skippedKey(for: sourceKind))
    }
    
    func reset() {
        userDefaults.removeObject(forKey: "BlawbyOnboardingCompleted")
        for sourceKind in SourceKind.allCases {
            userDefaults.removeObject(forKey: key(for: sourceKind))
            userDefaults.removeObject(forKey: skippedKey(for: sourceKind))
        }
    }
}

// MARK: - Source Registry (Activation Boundary)
@MainActor
class SourceRegistry {
    private var providers: [SourceKind: SourceProvider] = [:]
    private var activeSources: [SourceKind: ActiveSource] = [:]
    private var discoveredCapabilities: [SourceCapability] = []
    
    init() {
        // Register providers
        providers[.calendar] = CalendarSourceProvider()
        // TODO: Add Mail and Contacts providers in Phase 2+
    }
    
    // MARK: - Discovery
    func updateCapabilities(_ capabilities: [SourceCapability]) {
        discoveredCapabilities = capabilities
    }
    
    func getCapabilities() -> [SourceCapability] {
        return discoveredCapabilities
    }
    
    func getCapability(for kind: SourceKind) -> SourceCapability? {
        return discoveredCapabilities.first { $0.kind == kind }
    }
    
    // MARK: - Activation (Only Boundary)
    func activate(_ kind: SourceKind, in context: BootstrapContext) async throws -> ActiveSource {
        guard let provider = providers[kind] else {
            throw NSError(domain: "SourceRegistry", code: 1, userInfo: [NSLocalizedDescriptionKey: "No provider for source kind: \(kind.rawValue)"])
        }
        
        // Stop existing source if active
        if let existing = activeSources[kind] {
            await existing.stop()
            activeSources.removeValue(forKey: kind)
        }
        
        // Activate new source
        let activeSource = try await provider.activate(in: context)
        activeSources[kind] = activeSource
        
        return activeSource
    }
    
    func deactivate(_ kind: SourceKind) async {
        guard let activeSource = activeSources.removeValue(forKey: kind) else {
            return
        }
        await activeSource.stop()
    }
    
    func getActiveSources() -> [SourceKind: ActiveSource] {
        return activeSources
    }
    
    func isActive(_ kind: SourceKind) -> Bool {
        return activeSources[kind] != nil
    }
    
    // MARK: - Shutdown
    func shutdown() async {
        for (_, activeSource) in activeSources {
            await activeSource.stop()
        }
        activeSources.removeAll()
    }
}

// MARK: - Extensions for User-Friendly Display
extension SourceKind {
    var displayName: String {
        switch self {
        case .mail: return "Mail"
        case .calendar: return "Calendar"
        case .contacts: return "Contacts"
        }
    }
    
    var systemImage: String {
        switch self {
        case .mail: return "envelope"
        case .calendar: return "calendar"
        case .contacts: return "person.2"
        }
    }
}

extension SourceAvailability {
    var isAvailable: Bool {
        switch self {
        case .available: return true
        case .unavailable: return false
        }
    }
    
    var displayMessage: String {
        switch self {
        case .available: return "Available"
        case .unavailable(let reason): return "Unavailable: \(reason)"
        }
    }
}

extension SourceAuthorizationStatus {
    var isAuthorized: Bool {
        switch self {
        case .authorized, .notRequired: return true
        case .notDetermined, .denied, .restricted: return false
        }
    }
    
    var displayMessage: String {
        switch self {
        case .notRequired: return "Not required"
        case .notDetermined: return "Not requested"
        case .authorized: return "Authorized"
        case .denied: return "Access denied"
        case .restricted: return "Restricted"
        }
    }
}

extension SourceActivationStatus {
    var isActive: Bool {
        switch self {
        case .active: return true
        case .inactive, .activating, .degraded: return false
        }
    }
    
    var displayMessage: String {
        switch self {
        case .inactive: return "Inactive"
        case .activating: return "Activating..."
        case .active: return "Active"
        case .degraded(let reason): return "Degraded: \(reason)"
        }
    }
}
