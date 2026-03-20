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
        let discoveredCapabilities = await discoverSources(context: context, registry: sourceRegistry)
        
        // Layer C: Load enabled intents and attempt activation
        let (activeSources, activationIssues) = try await activateEnabledSources(context: context, capabilities: discoveredCapabilities, registry: sourceRegistry)
        
        // Layer D: Merge runtime activation state for UI (after activation)
        let mergedCapabilities = await mergeActivationState(capabilities: discoveredCapabilities, registry: sourceRegistry)
        
        // Layer E: Compute boot state from actual runtime plus issues
        let bootState = await computeBootState(context: context, capabilities: mergedCapabilities, activeSources: activeSources, issues: activationIssues, registry: sourceRegistry)
        
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
    @MainActor
    private func discoverSources(context: BootstrapContext, registry: SourceRegistry) async -> [SourceCapability] {
        var capabilities: [SourceCapability] = []
        
        // Discover all sources through registry providers
        for provider in registry.providers.values {
            let capability = await provider.discover(in: context)
            capabilities.append(capability)
        }
        
        return capabilities
    }
    
    // MARK: - Merge Runtime Activation State
    @MainActor
    private func mergeActivationState(
        capabilities: [SourceCapability],
        registry: SourceRegistry
    ) async -> [SourceCapability] {
        var mergedCapabilities: [SourceCapability] = []
        for capability in capabilities {
            let activation: SourceActivationStatus = await registry.isActive(capability.kind) ? .active : .inactive
            mergedCapabilities.append(SourceCapability(
                kind: capability.kind,
                displayName: capability.displayName,
                availability: capability.availability,
                authorization: capability.authorization,
                activation: activation,
                isRequiredForCoreValue: capability.isRequiredForCoreValue,
                canDefer: capability.canDefer
            ))
        }
        return mergedCapabilities
    }
    
    // MARK: - Layer C: Activate Enabled Sources
    @MainActor
    private func activateEnabledSources(
        context: BootstrapContext,
        capabilities: [SourceCapability],
        registry: SourceRegistry
    ) async throws -> ([SourceKind: ActiveSource], [SourceIssue]) {
        var sourceIssues: [SourceIssue] = []
        
        // Get enabled sources from persisted intent
        let enabledCapabilities = capabilities.filter { 
            context.activationStateStore.isEnabled($0.kind) && $0.availability.isAvailable
        }
        
        // Attempt activation only for sources not already active
        for capability in enabledCapabilities {
            // Skip if already active in registry
            if await registry.isActive(capability.kind) {
                continue
            }
            
            do {
                _ = try await registry.activate(capability.kind, in: context)
                // Registry manages active sources, we don't need to track them here
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
    
    // MARK: - Layer D: Compute Boot State
    @MainActor
    private func computeBootState(
        context: BootstrapContext,
        capabilities: [SourceCapability],
        activeSources: [SourceKind: ActiveSource],
        issues: [SourceIssue],
        registry: SourceRegistry
    ) async -> AppBootState {
        // Determine state based on actual active sources
        if !activeSources.isEmpty {
            // Include issues for enabled sources only (discovery + activation)
            let enabledKinds = Set(SourceKind.allCases.filter { context.activationStateStore.isEnabled($0) })
            let enabledDiscoveryIssues = await generateDiscoverySourceIssues(capabilities: capabilities, registry: registry)
                .filter { enabledKinds.contains($0.kind) }
            let allRuntimeIssues = enabledDiscoveryIssues + issues
            
            if !allRuntimeIssues.isEmpty {
                return .degraded(context, activeSources, allRuntimeIssues)
            } else {
                return .ready(context, activeSources)
            }
        } else {
            // No active sources - show setup
            // Include discovery issues for all sources
            let discoveryIssues = await generateDiscoverySourceIssues(capabilities: capabilities, registry: registry)
            let allIssues = discoveryIssues + issues
            return .setupRequired(context, capabilities, allIssues)
        }
    }
    
    @MainActor
    private func generateDiscoverySourceIssues(capabilities: [SourceCapability], registry: SourceRegistry) async -> [SourceIssue] {
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
