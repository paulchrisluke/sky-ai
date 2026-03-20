import Foundation
import SwiftUI
import EventKit
import Contacts

// MARK: - Bootstrap Context
struct BootstrapContext {
    let logger: Logger
    let localStore: LocalStore
    let configStore: ConfigStore
    let preferences: Preferences
    let config: Config
    let activationStateStore: ActivationStateStore
    let syncPreference: Bool
}

// MARK: - App Bootstrapper
final class AppBootstrapper {
    func bootstrap(sourceRegistry: SourceRegistry) async throws -> AppBootState {
        // Layer A: Unconditional boot (never triggers permissions)
        let context = try await performUnconditionalBoot()
        
        // Layer B: Source discovery (determines relevance, no permissions requested)
        let discoveredCapabilities = await discoverSources(context: context)
        
        // Layer C: Load enabled intents and attempt activation
        let (activeSources, activationIssues) = try await activateEnabledSources(context: context, capabilities: discoveredCapabilities, registry: sourceRegistry)
        
        // Layer D: Merge runtime activation state for UI (after activation)
        let mergedCapabilities = mergeActivationState(capabilities: discoveredCapabilities, registry: sourceRegistry)
        
        // Layer E: Compute boot state from actual runtime plus issues
        let bootState = computeBootState(context: context, capabilities: mergedCapabilities, activeSources: activeSources, issues: activationIssues)
        
        return bootState
    }
    
    // MARK: - Layer A: Unconditional Boot
    private func performUnconditionalBoot() async throws -> BootstrapContext {
        let baseDir = resolveBlawbyHome()
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        
        // Core infrastructure that must succeed
        let logger = try Logger(baseDirectory: baseDir)
        let localStore = try LocalStore(baseDirectory: baseDir)
        let configStore = try ConfigStore(baseDirectory: baseDir)
        
        // Configuration loading
        let fileConfig = configStore.load()
        let prefs = try Preferences.load(config: fileConfig)
        let config = Config(
            workerUrl: prefs.workerUrl ?? fileConfig.workerUrl,
            apiKey: prefs.apiKey ?? fileConfig.apiKey,
            workspaceId: prefs.workspaceId ?? fileConfig.workspaceId,
            accountId: ConfigStore.normalizeAccountId(prefs.accountId ?? fileConfig.accountId),
            openaiApiKey: prefs.openaiApiKey ?? fileConfig.openaiApiKey
        )
        
        // Setup state persistence
        localStore.seedSyncMetricsIfNeeded(accountId: config.accountId)
        let activationStateStore = ActivationStateStore()
        
        // Sync preference
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Preferences.Keys.syncActivated) == nil {
            defaults.set(true, forKey: Preferences.Keys.syncActivated)
        }
        let syncPreference = defaults.bool(forKey: Preferences.Keys.syncActivated)
        
        return BootstrapContext(
            logger: logger,
            localStore: localStore,
            configStore: configStore,
            preferences: prefs,
            config: config,
            activationStateStore: activationStateStore,
            syncPreference: syncPreference
        )
    }
    
    // MARK: - Layer B: Source Discovery
    private func discoverSources(context: BootstrapContext) async -> [SourceCapability] {
        var capabilities: [SourceCapability] = []
        
        // Discover Mail availability
        let mailCapability = await discoverMailCapability(context: context)
        capabilities.append(mailCapability)
        
        // Discover Calendar capability
        let calendarCapability = await discoverCalendarCapability(context: context)
        capabilities.append(calendarCapability)
        
        // Discover Contacts capability
        let contactsCapability = await discoverContactsCapability(context: context)
        capabilities.append(contactsCapability)
        
        return capabilities
    }
    
    // MARK: - Merge Runtime Activation State
    private func mergeActivationState(
        capabilities: [SourceCapability],
        registry: SourceRegistry
    ) -> [SourceCapability] {
        capabilities.map { capability in
            let activation: SourceActivationStatus = registry.isActive(capability.kind) ? .active : .inactive
            return SourceCapability(
                kind: capability.kind,
                displayName: capability.displayName,
                availability: capability.availability,
                authorization: capability.authorization,
                activation: activation,
                isRequiredForCoreValue: capability.isRequiredForCoreValue,
                canDefer: capability.canDefer
            )
        }
    }
    
    // MARK: - Individual Source Discovery
    private func discoverMailCapability(context: BootstrapContext) async -> SourceCapability {
        // Check if Mail.app is available
        let mailUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Mail")
        let availability: SourceAvailability = mailUrl != nil ? .available : .unavailable(reason: "Mail.app not installed")
        
        // Mail doesn't require explicit permissions upfront (uses Apple Events)
        let authorization: SourceAuthorizationStatus = .notRequired
        
        // Mail is highest user value, cannot be deferred
        let activation: SourceActivationStatus = .inactive
        
        return SourceCapability(
            kind: .mail,
            displayName: "Mail",
            availability: availability,
            authorization: authorization,
            activation: activation,
            isRequiredForCoreValue: true,
            canDefer: false
        )
    }
    
    private func discoverCalendarCapability(context: BootstrapContext) async -> SourceCapability {
        // Check Calendar availability (always available on macOS)
        let availability: SourceAvailability = .available
        
        // Check current authorization status without requesting
        let authorization = await checkCalendarAuthorizationStatus()
        
        let activation: SourceActivationStatus = .inactive
        
        return SourceCapability(
            kind: .calendar,
            displayName: "Calendar",
            availability: availability,
            authorization: authorization,
            activation: activation,
            isRequiredForCoreValue: false,
            canDefer: true
        )
    }
    
    private func discoverContactsCapability(context: BootstrapContext) async -> SourceCapability {
        // Check Contacts availability (always available on macOS)
        let availability: SourceAvailability = .available
        
        // Check current authorization status without requesting
        let authorization = await checkContactsAuthorizationStatus()
        
        let activation: SourceActivationStatus = .inactive
        
        // Contacts is enrichment, can be deferred
        return SourceCapability(
            kind: .contacts,
            displayName: "Contacts",
            availability: availability,
            authorization: authorization,
            activation: activation,
            isRequiredForCoreValue: false,
            canDefer: true
        )
    }
    
    // MARK: - Authorization Status Checks (Side-Effect Free)
    private func checkCalendarAuthorizationStatus() async -> SourceAuthorizationStatus {
        // Check current status WITHOUT requesting access
        if #available(macOS 14.0, *) {
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .authorized:
                return .authorized
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            case .notDetermined:
                return .notDetermined
            @unknown default:
                return .notDetermined
            }
        } else {
            let status = EKEventStore.authorizationStatus(for: .event)
            switch status {
            case .authorized:
                return .authorized
            case .denied:
                return .denied
            case .restricted:
                return .restricted
            case .notDetermined:
                return .notDetermined
            @unknown default:
                return .notDetermined
            }
        }
    }
    
    private func checkContactsAuthorizationStatus() async -> SourceAuthorizationStatus {
        // Check current status WITHOUT requesting access
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            return .authorized
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .notDetermined
        }
    }
    
    // MARK: - Layer C: Activate Enabled Sources
    private func activateEnabledSources(
        context: BootstrapContext,
        capabilities: [SourceCapability],
        registry: SourceRegistry
    ) async throws -> ([SourceKind: ActiveSource], [StartupIssue]) {
        var activationIssues: [StartupIssue] = []
        
        // Get enabled sources from persisted intent
        let enabledCapabilities = capabilities.filter { 
            context.activationStateStore.isEnabled($0.kind) && $0.availability.isAvailable
        }
        
        // Attempt activation only for sources not already active
        for capability in enabledCapabilities {
            // Skip if already active in registry
            if registry.isActive(capability.kind) {
                continue
            }
            
            do {
                let activeSource = try await registry.activate(capability.kind, in: context)
                // Registry manages active sources, we don't need to track them here
            } catch {
                // Activation failed - add to issues
                activationIssues.append(.activationFailed(capability.kind, reason: error.localizedDescription))
            }
        }
        
        // Return current active sources from registry and any issues
        let activeSources = registry.getActiveSources()
        return (activeSources, activationIssues)
    }
    
    // MARK: - Layer D: Compute Boot State
    private func computeBootState(
        context: BootstrapContext,
        capabilities: [SourceCapability],
        activeSources: [SourceKind: ActiveSource],
        issues: [StartupIssue]
    ) -> AppBootState {
        // Determine state based on actual active sources
        if !activeSources.isEmpty {
            // Include issues for enabled sources only (discovery + activation)
            let enabledKinds = Set(SourceKind.allCases.filter { context.activationStateStore.isEnabled($0) })
            let enabledDiscoveryIssues = extractIssues(capabilities: capabilities).filter { issue in
                switch issue {
                case .sourceUnavailable(let kind, _), .authorizationDenied(let kind), .activationFailed(let kind, _):
                    return enabledKinds.contains(kind)
                case .partialDependencyFailure:
                    return true
                }
            }
            let allRuntimeIssues = enabledDiscoveryIssues + issues
            
            if !allRuntimeIssues.isEmpty {
                return .degraded(context, activeSources, allRuntimeIssues)
            } else {
                return .ready(context, activeSources)
            }
        } else {
            // No active sources - show setup
            // Include discovery issues for all sources
            let discoveryIssues = extractIssues(capabilities: capabilities)
            let allIssues = discoveryIssues + issues
            return .setupRequired(context, capabilities, allIssues)
        }
    }
    
    private func extractIssues(capabilities: [SourceCapability]) -> [StartupIssue] {
        var issues: [StartupIssue] = []
        
        for capability in capabilities {
            switch capability.availability {
            case .unavailable(let reason):
                issues.append(.sourceUnavailable(capability.kind, reason: reason))
            case .available:
                break
            }
            
            switch capability.authorization {
            case .denied:
                issues.append(.authorizationDenied(capability.kind))
            case .restricted:
                issues.append(.authorizationDenied(capability.kind))
            case .notRequired, .authorized, .notDetermined:
                break
            }
        }
        
        return issues
    }
    
    // MARK: - Error Mapping
    private func mapToFatalIssue(_ error: Error) -> FatalStartupIssue {
        let errorMessage = error.localizedDescription
        
        if errorMessage.contains("Logger") || errorMessage.contains("log") {
            return .loggerInitializationFailed(errorMessage)
        } else if errorMessage.contains("Config") || errorMessage.contains("preferences") {
            return .configurationLoadFailed(errorMessage)
        } else {
            return .storageInitializationFailed(errorMessage)
        }
    }
}
