@preconcurrency import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppSession: ObservableObject {
    @Published var bootState: AppBootState = .launching
    @Published var syncRequested: Bool

    private let bootstrapper: AppBootstrapper
    private let sourceRegistry = SourceRegistry() // Lives here, not in bootstrap
    private let activationStateStore = ActivationStateStore() // Shared store instance
    private nonisolated(unsafe) var terminationObserver: NSObjectProtocol?
    
    // MARK: - PreferencesView Compatibility
    var config: Config? { currentContext?.config }
    var startupError: String? {
        switch bootState {
        case .fatal(.storageInitializationFailed(let reason)): 
            return "Storage initialization failed: \(reason)"
        case .fatal(.configurationLoadFailed(let reason)): 
            return "Configuration load failed: \(reason)"
        case .fatal(.loggerInitializationFailed(let reason)): 
            return "Logger initialization failed: \(reason)"
        default: return nil
        }
    }

    init(bootstrapper: AppBootstrapper = AppBootstrapper()) {
        self.bootstrapper = bootstrapper
        // Initialize syncRequested from persisted value, defaulting to true like bootstrap
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Preferences.Keys.syncActivated) == nil {
            self.syncRequested = true
        } else {
            self.syncRequested = defaults.bool(forKey: Preferences.Keys.syncActivated)
        }

        Task { @MainActor in
            await boot()
        }

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.shutdown()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Sync Intent
    func toggleSync() async {
        syncRequested.toggle()
        
        // Persist sync preference to UserDefaults to affect bootstrap behavior
        UserDefaults.standard.set(syncRequested, forKey: Preferences.Keys.syncActivated)
        
        // Invalidate cache since syncPreference changed
        bootstrapper.invalidateCache()
        
        // Refresh boot state to pick up new sync preference
        await refreshBootState()
    }

    // MARK: - Source Activation Commands
    func enableSource(_ kind: SourceKind) async {
        // Persist desired state first - user wants this source enabled
        activationStateStore.setDesired(kind, desired: true)
        
        // Try to get current context, but work without it if unavailable
        if let context = currentContext {
            do {
                // Activate through registry if not already active
                if !sourceRegistry.isActive(kind) {
                    _ = try await sourceRegistry.activate(kind, in: context)
                }
                // Registry manages active sources - no need to persist separate enabled state
            } catch {
                // Activation failed - desired state remains but activation will be retried
            }
        } else {
            // No current context available (e.g., in fatal state)
            // Just persist desired state and let bootstrap handle activation on next refresh
        }
        
        // Recompute boot state
        await refreshBootState()
    }
    
    func disableSource(_ kind: SourceKind) async {
        // Deactivate through registry
        await sourceRegistry.deactivate(kind)
        
        // Update persisted desired state using shared store instance
        activationStateStore.setDesired(kind, desired: false)
        
        // Recompute boot state
        await refreshBootState()
    }
    
    func refreshBootState() async {
        do {
            bootState = try await bootstrapper.bootstrap(sourceRegistry: sourceRegistry)
        } catch {
            bootState = mapBootstrapError(error)
        }
    }
    
    func shutdown() async {
        await sourceRegistry.shutdown()
    }
    
    // MARK: - PreferencesView Methods
    func saveConnectionSettings(
        workerUrl: String,
        workspaceId: String,
        accountId: String,
        apiKey: String,
        openaiApiKey: String
    ) async throws {
        let defaults = UserDefaults.standard
        let keychain = KeychainStore()
        
        // Save to UserDefaults
        defaults.set(workerUrl.isEmpty ? nil : workerUrl, forKey: Preferences.Keys.workerUrl)
        defaults.set(workspaceId.isEmpty ? nil : workspaceId, forKey: Preferences.Keys.workspaceId)
        defaults.set(accountId.isEmpty ? nil : accountId, forKey: Preferences.Keys.accountId)
        
        // Save to Keychain
        if !apiKey.isEmpty {
            try keychain.write(apiKey, account: Preferences.Keys.keychainAPIKey)
        }
        if !openaiApiKey.isEmpty {
            try keychain.write(openaiApiKey, account: Preferences.Keys.keychainOpenAI)
        }
        
        // Invalidate cache since config changed
        bootstrapper.invalidateCache()
        
        // Refresh boot state to pick up new config
        await refreshBootState()
    }
    
    // MARK: - Private Helpers
    private func boot() async {
        do {
            bootState = try await bootstrapper.bootstrap(sourceRegistry: sourceRegistry)
        } catch {
            bootState = mapBootstrapError(error)
        }
    }
    
    private func mapBootstrapError(_ error: Error) -> AppBootState {
        // Map typed BootstrapError to appropriate FatalStartupIssue
        if let bootstrapError = error as? BootstrapError {
            switch bootstrapError {
            case .storageInitializationFailed(let reason):
                return .fatal(.storageInitializationFailed(reason))
            case .loggerInitializationFailed(let reason):
                return .fatal(.loggerInitializationFailed(reason))
            case .configurationLoadFailed(let reason):
                return .fatal(.configurationLoadFailed(reason))
            }
        } else {
            // Fallback for unknown errors - classify by error description
            let errorDescription = String(describing: error)
            
            // Use more robust error classification based on error content
            if error.localizedDescription.contains("storage") || error.localizedDescription.contains("database") {
                return .fatal(.storageInitializationFailed(errorDescription))
            } else if error.localizedDescription.contains("logger") || error.localizedDescription.contains("log") {
                return .fatal(.loggerInitializationFailed(errorDescription))
            } else {
                // Default to configuration load failed for unknown errors
                return .fatal(.configurationLoadFailed(errorDescription))
            }
        }
    }
    
    private var currentContext: BootstrapContext? {
        switch bootState {
        case .setupRequired(let context, _, _),
             .ready(let context, _, _),
             .degraded(let context, _, _, _):
            return context
        case .launching, .fatal:
            return nil
        }
    }
}
