import Foundation
import SwiftUI

// MARK: - App Boot State
enum AppBootState {
    case launching
    case setupRequired(BootstrapContext, [ResolvedSourceCapability], [SourceIssue])
    case ready(BootstrapContext, [ResolvedSourceCapability], [SourceKind: ActiveSource])
    case degraded(BootstrapContext, [ResolvedSourceCapability], [SourceKind: ActiveSource], [SourceIssue])
    case fatal(FatalStartupIssue)
}

// MARK: - Setup Model (Phase 2 - may be deprecated)
struct SetupModel {
    let context: BootstrapContext
    let sourceCapabilities: [ResolvedSourceCapability]
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

// Discovery-only activation states (what provider reports from discover())
enum SourceDiscoveryStatus: Equatable {
    case inactive
    case activating
    case degraded(reason: String)
}

// Runtime activation states (what registry reports from actual activation)
enum SourceActivationStatus: Equatable {
    case inactive
    case activating
    case active
    case degraded(reason: String)
}

// Pure discovery model - what providers report from discover()
struct DiscoveredSourceCapability: Equatable, Identifiable {
    var id: String { kind.rawValue }
    
    let kind: SourceKind
    let displayName: String
    let availability: SourceAvailability
    let authorization: SourceAuthorizationStatus
    let discoveryStatus: SourceDiscoveryStatus  // What provider reports from discovery
    let isRequiredForCoreValue: Bool
    let canDefer: Bool
    
    init(
        kind: SourceKind,
        displayName: String,
        availability: SourceAvailability,
        authorization: SourceAuthorizationStatus,
        discoveryStatus: SourceDiscoveryStatus,
        isRequiredForCoreValue: Bool,
        canDefer: Bool
    ) {
        self.kind = kind
        self.displayName = displayName
        self.availability = availability
        self.authorization = authorization
        self.discoveryStatus = discoveryStatus
        self.isRequiredForCoreValue = isRequiredForCoreValue
        self.canDefer = canDefer
    }
}

// Merged model with runtime state - what UI consumes
struct ResolvedSourceCapability: Equatable, Identifiable {
    var id: String { kind.rawValue }
    
    let kind: SourceKind
    let displayName: String
    let availability: SourceAvailability
    let authorization: SourceAuthorizationStatus
    let discoveryStatus: SourceDiscoveryStatus  // What provider reports from discovery
    let runtimeStatus: SourceActivationStatus  // What registry reports from runtime
    let isRequiredForCoreValue: Bool
    let canDefer: Bool
    
    init(
        kind: SourceKind,
        displayName: String,
        availability: SourceAvailability,
        authorization: SourceAuthorizationStatus,
        discoveryStatus: SourceDiscoveryStatus,
        runtimeStatus: SourceActivationStatus,
        isRequiredForCoreValue: Bool,
        canDefer: Bool
    ) {
        self.kind = kind
        self.displayName = displayName
        self.availability = availability
        self.authorization = authorization
        self.discoveryStatus = discoveryStatus
        self.runtimeStatus = runtimeStatus
        self.isRequiredForCoreValue = isRequiredForCoreValue
        self.canDefer = canDefer
    }
}

// MARK: - Fatal Error Models
enum FatalStartupIssue: Identifiable {
    case storageInitializationFailed(String)
    case configurationLoadFailed(String)
    case loggerInitializationFailed(String)
    
    var id: String {
        switch self {
        case .storageInitializationFailed(let reason):
            return "storage_initialization_failed:\(reason)"
        case .configurationLoadFailed(let reason):
            return "configuration_load_failed:\(reason)"
        case .loggerInitializationFailed(let reason):
            return "logger_initialization_failed:\(reason)"
        }
    }
    
    var localizedDescription: String {
        switch self {
        case .storageInitializationFailed(let reason):
            return "Storage initialization failed: \(reason)"
        case .configurationLoadFailed(let reason):
            return "Configuration load failed: \(reason)"
        case .loggerInitializationFailed(let reason):
            return "Logger initialization failed: \(reason)"
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
    func discover(in context: BootstrapContext) async -> DiscoveredSourceCapability
    func activate(in context: BootstrapContext) async throws -> ActiveSource
    func generateIssues(for capability: DiscoveredSourceCapability) -> [SourceIssue]
    func generateActivationFailureIssues(for error: Error) -> [SourceIssue]
}

// MARK: - Activation State Persistence
class ActivationStateStore {
    private let userDefaults: UserDefaults
    
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }
    
    private func desiredKey(for sourceKind: SourceKind) -> String {
        return "BlawbyDesired_\(sourceKind.rawValue)"
    }
    
    private func skippedKey(for sourceKind: SourceKind) -> String {
        return "BlawbySkipped_\(sourceKind.rawValue)"
    }
    
    var onboardingCompleted: Bool {
        get { userDefaults.bool(forKey: "BlawbyOnboardingCompleted") }
        set { userDefaults.set(newValue, forKey: "BlawbyOnboardingCompleted") }
    }
    
    // Desired enabled state (user wants this source enabled)
    func isDesired(_ sourceKind: SourceKind) -> Bool {
        return userDefaults.bool(forKey: desiredKey(for: sourceKind))
    }
    
    func setDesired(_ sourceKind: SourceKind, desired: Bool) {
        userDefaults.set(desired, forKey: desiredKey(for: sourceKind))
    }
    
    func isSkipped(_ sourceKind: SourceKind) -> Bool {
        return userDefaults.bool(forKey: skippedKey(for: sourceKind))
    }
    
    func setSkipped(_ sourceKind: SourceKind, skipped: Bool) {
        userDefaults.set(skipped, forKey: skippedKey(for: sourceKind))
    }
    
    // Legacy compatibility - remove these methods after migration
    @available(*, deprecated, message: "Use registry.activeSources for actual enabled state")
    func isEnabled(_ sourceKind: SourceKind) -> Bool {
        return userDefaults.bool(forKey: "BlawbyActivation_\(sourceKind.rawValue)")
    }
    
    @available(*, deprecated, message: "Use registry.activeSources for actual enabled state")
    func setEnabled(_ sourceKind: SourceKind, enabled: Bool) {
        userDefaults.set(enabled, forKey: "BlawbyActivation_\(sourceKind.rawValue)")
    }
    
    func reset() {
        userDefaults.removeObject(forKey: "BlawbyOnboardingCompleted")
        for sourceKind in SourceKind.allCases {
            userDefaults.removeObject(forKey: desiredKey(for: sourceKind))
            userDefaults.removeObject(forKey: skippedKey(for: sourceKind))
            userDefaults.removeObject(forKey: "BlawbyActivation_\(sourceKind.rawValue)")
        }
    }
}

// MARK: - Source Registry (Activation Boundary)
@MainActor
class SourceRegistry {
    private var _providers: [SourceKind: SourceProvider] = [:]
    private var activeSources: [SourceKind: ActiveSource] = [:]
    private var runtimeStates: [SourceKind: SourceActivationStatus] = [:]
    
    var providers: [SourceKind: SourceProvider] { _providers }
    
    init() {
        // Register providers
        _providers[.calendar] = CalendarSourceProvider()
        _providers[.mail] = MailSourceProvider()
        _providers[.contacts] = ContactsSourceProvider()
    }
    
    // MARK: - Activation (Only Boundary)
    func activate(_ kind: SourceKind, in context: BootstrapContext) async throws -> ActiveSource {
        guard let provider = _providers[kind] else {
            throw NSError(domain: "SourceRegistry", code: 1, userInfo: [NSLocalizedDescriptionKey: "No provider for source kind: \(kind.rawValue)"])
        }
        
        // Set activating state
        runtimeStates[kind] = .activating
        
        // Stop existing source if active
        if let existing = activeSources[kind] {
            await existing.stop()
            activeSources.removeValue(forKey: kind)
        }
        
        do {
            // Activate new source
            let activeSource = try await provider.activate(in: context)
            activeSources[kind] = activeSource
            runtimeStates[kind] = .active
            return activeSource
        } catch {
            // Set degraded state on failure
            runtimeStates[kind] = .degraded(reason: error.localizedDescription)
            throw error
        }
    }
    
    func deactivate(_ kind: SourceKind) async {
        if let activeSource = activeSources.removeValue(forKey: kind) {
            await activeSource.stop()
        }
        runtimeStates[kind] = .inactive
    }
    
    func getActiveSources() -> [SourceKind: ActiveSource] {
        return activeSources
    }
    
    func isActive(_ kind: SourceKind) -> Bool {
        return activeSources[kind] != nil
    }
    
    func getRuntimeState(_ kind: SourceKind) -> SourceActivationStatus {
        return runtimeStates[kind] ?? .inactive
    }
    
    // MARK: - Shutdown
    func shutdown() async {
        for (_, activeSource) in activeSources {
            await activeSource.stop()
        }
        activeSources.removeAll()
        runtimeStates.removeAll()
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
