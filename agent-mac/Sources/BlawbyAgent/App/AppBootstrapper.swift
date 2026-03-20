import Foundation
import SwiftUI
import EventKit
import Contacts

// MARK: - Bootstrap Error Types
enum BootstrapError: Error, LocalizedError {
    case storageInitializationFailed(String)
    case configurationLoadFailed(String)
    case loggerInitializationFailed(String)
    
    var errorDescription: String? {
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
@MainActor
final class AppBootstrapper {
    private var cachedContext: BootstrapContext?
    
    func bootstrap(sourceRegistry: SourceRegistry) async throws -> AppBootState {
        // Use cached context if available, otherwise create new one
        let context = try await getCachedContext()
        
        // Layer B: Source discovery (determines relevance, no permissions requested)
        let discoveredCapabilities = await discoverSources(context: context, registry: sourceRegistry)
        
        // Layer C: Load desired intents and attempt activation
        let (activeSources, activationIssues) = try await activateEnabledSources(context: context, capabilities: discoveredCapabilities, registry: sourceRegistry)
        
        // Layer D: Merge runtime activation state for UI (after activation)
        let resolvedCapabilities = await resolveCapabilities(discoveredCapabilities: discoveredCapabilities, registry: sourceRegistry)
        
        // Layer E: Compute boot state from actual runtime plus issues
        let bootState = await computeBootState(
            context: context, 
            discoveredCapabilities: discoveredCapabilities,
            resolvedCapabilities: resolvedCapabilities, 
            activeSources: activeSources, 
            issues: activationIssues, 
            registry: sourceRegistry
        )
        
        return bootState
    }
    
    // MARK: - Cached Context Management
    private func getCachedContext() async throws -> BootstrapContext {
        if let cachedContext = cachedContext {
            return cachedContext
        }
        
        let newContext = try await performUnconditionalBoot()
        cachedContext = newContext
        return newContext
    }
    
    func invalidateCache() {
        cachedContext = nil
    }
    
    // MARK: - Layer A: Unconditional Boot
    private func performUnconditionalBoot() async throws -> BootstrapContext {
        let baseDir = resolveBlawbyHome()
        try FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        
        // Core infrastructure that must succeed - throw typed errors at exact failure points
        let logger: Logger
        do {
            logger = try Logger(baseDirectory: baseDir)
        } catch {
            throw BootstrapError.loggerInitializationFailed(String(describing: error))
        }
        
        let localStore: LocalStore
        do {
            localStore = try LocalStore(baseDirectory: baseDir)
        } catch {
            throw BootstrapError.storageInitializationFailed(String(describing: error))
        }
        
        let configStore: ConfigStore
        do {
            configStore = try ConfigStore(baseDirectory: baseDir)
        } catch {
            throw BootstrapError.storageInitializationFailed(String(describing: error))
        }
        
        // Configuration loading
        let fileConfig: Config
        do {
            fileConfig = configStore.load()
        } catch {
            throw BootstrapError.configurationLoadFailed(String(describing: error))
        }
        
        let prefs: Preferences
        do {
            prefs = try Preferences.load(config: fileConfig)
        } catch {
            throw BootstrapError.configurationLoadFailed(String(describing: error))
        }
        
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
    private func discoverSources(context: BootstrapContext, registry: SourceRegistry) async -> [DiscoveredSourceCapability] {
        var capabilities: [DiscoveredSourceCapability] = []
        
        // Discover sources in deterministic order using SourceKind.allCases
        for kind in SourceKind.allCases {
            guard let provider = registry.providers[kind] else { continue }
            let capability = await provider.discover(in: context)
            capabilities.append(capability)
        }
        
        return capabilities
    }
    
    // MARK: - Layer D: Resolve Runtime State
    private func resolveCapabilities(
        discoveredCapabilities: [DiscoveredSourceCapability],
        registry: SourceRegistry
    ) async -> [ResolvedSourceCapability] {
        var resolvedCapabilities: [ResolvedSourceCapability] = []
        for discovered in discoveredCapabilities {
            // Get runtime state from registry
            let runtimeStatus = registry.getRuntimeState(discovered.kind)
            
            resolvedCapabilities.append(ResolvedSourceCapability(
                kind: discovered.kind,
                displayName: discovered.displayName,
                availability: discovered.availability,
                authorization: discovered.authorization,
                discoveryStatus: discovered.discoveryStatus,  // Keep original discovery state
                runtimeStatus: runtimeStatus,  // Set actual runtime state
                isRequiredForCoreValue: discovered.isRequiredForCoreValue,
                canDefer: discovered.canDefer
            ))
        }
        return resolvedCapabilities
    }
    
    // MARK: - Layer C: Activate Enabled Sources
    private func activateEnabledSources(
        context: BootstrapContext,
        capabilities: [DiscoveredSourceCapability],
        registry: SourceRegistry
    ) async throws -> ([SourceKind: ActiveSource], [SourceIssue]) {
        var sourceIssues: [SourceIssue] = []
        
        // Get desired sources from persisted user intent, gated on authorization
        let desiredCapabilities = capabilities.filter { 
            context.activationStateStore.isDesired($0.kind) && 
            $0.availability.isAvailable &&
            $0.authorization.isAuthorized
        }
        
        // Attempt activation only for sources not already active
        for capability in desiredCapabilities {
            // Skip if already active in registry
            if await registry.isActive(capability.kind) {
                continue
            }
            
            do {
                _ = try await registry.activate(capability.kind, in: context)
                // Registry manages active sources - no need to persist separate enabled state
            } catch {
                // Activation failed - generate issues from provider
                if let provider = registry.providers[capability.kind] {
                    let providerIssues = provider.generateActivationFailureIssues(for: error)
                    sourceIssues.append(contentsOf: providerIssues)
                } else {
                    // Fallback generic issue
                    sourceIssues.append(SourceIssue(
                        kind: capability.kind,
                        severity: .error,
                        category: .activation,
                        title: "\(capability.kind.displayName) Activation Failed",
                        description: error.localizedDescription,
                        repairActions: [.retryActivation(capability.kind)]
                    ))
                }
            }
        }
        
        // Return current active sources from registry and any issues
        let activeSources = await registry.getActiveSources()
        return (activeSources, sourceIssues)
    }
    
    // MARK: - Layer E: Compute Boot State
    private func computeBootState(
        context: BootstrapContext,
        discoveredCapabilities: [DiscoveredSourceCapability],
        resolvedCapabilities: [ResolvedSourceCapability],
        activeSources: [SourceKind: ActiveSource],
        issues: [SourceIssue],
        registry: SourceRegistry
    ) async -> AppBootState {
        // Determine state based on actual active sources
        if !activeSources.isEmpty {
            // Include issues for desired sources only (discovery + activation)
            let desiredKinds = Set(SourceKind.allCases.filter { context.activationStateStore.isDesired($0) })
            let enabledDiscoveryIssues = await generateDiscoverySourceIssues(capabilities: discoveredCapabilities, registry: registry)
                .filter { desiredKinds.contains($0.kind) }
            let allRuntimeIssues = enabledDiscoveryIssues + issues
            
            if !allRuntimeIssues.isEmpty {
                return .degraded(context, resolvedCapabilities, activeSources, allRuntimeIssues)
            } else {
                return .ready(context, resolvedCapabilities, activeSources)
            }
        } else {
            // No active sources - determine if setup is actually required
            let hasCompletedOnboarding = context.activationStateStore.onboardingCompleted
            let syncIsDisabled = !context.syncPreference
            let hasSkippedAllSources = SourceKind.allCases.allSatisfy { context.activationStateStore.isSkipped($0) }
            
            // If user has completed onboarding and either disabled sync or skipped all sources, 
            // treat as valid steady state rather than setup required
            if hasCompletedOnboarding && (syncIsDisabled || hasSkippedAllSources) {
                // Return ready with empty active sources - this is a valid state
                return .ready(context, resolvedCapabilities, [:])
            }
            
            // Otherwise, setup is still required
            let discoveryIssues = await generateDiscoverySourceIssues(capabilities: discoveredCapabilities, registry: registry)
            let allIssues = discoveryIssues + issues
            return .setupRequired(context, resolvedCapabilities, allIssues)
        }
    }
    
    private func generateDiscoverySourceIssues(capabilities: [DiscoveredSourceCapability], registry: SourceRegistry) async -> [SourceIssue] {
        var issues: [SourceIssue] = []
        
        for capability in capabilities {
            // Generate issues from providers for discovery state
            if let provider = registry.providers[capability.kind] {
                let providerIssues = provider.generateIssues(for: capability)
                issues.append(contentsOf: providerIssues)
            }
        }
        
        return issues
    }
}
