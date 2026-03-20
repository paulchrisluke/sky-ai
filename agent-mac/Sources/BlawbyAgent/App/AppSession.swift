@preconcurrency import AppKit
import Foundation
import ServiceManagement

@MainActor
final class AppSession: ObservableObject {
    @Published var bootState: AppBootState = .launching
    @Published var syncRequested: Bool = true

    private let bootstrapper: AppBootstrapper
    private let sourceRegistry = SourceRegistry() // Lives here, not in bootstrap
    private nonisolated(unsafe) var terminationObserver: NSObjectProtocol?

    init(bootstrapper: AppBootstrapper = AppBootstrapper()) {
        self.bootstrapper = bootstrapper
        boot()
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor in
                self?.shutdown()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    // MARK: - Sync Intent
    func toggleSync() {
        syncRequested.toggle()
    }

    // MARK: - Source Activation Commands
    func enableSource(_ kind: SourceKind) async {
        guard let context = currentContext else { return }
        
        // Persist enabled intent
        context.activationStateStore.setEnabled(kind, enabled: true)
        
        // Activate through registry if not already active
        if !sourceRegistry.isActive(kind) {
            do {
                _ = try await sourceRegistry.activate(kind, in: context)
            } catch {
                // Activation failed - will be reflected in next boot state
            }
        }
        
        // Recompute boot state
        await refreshBootState()
    }
    
    func disableSource(_ kind: SourceKind) async {
        // Deactivate through registry
        await sourceRegistry.deactivate(kind)
        
        // Update persisted intent
        if let context = currentContext {
            context.activationStateStore.setEnabled(kind, enabled: false)
        }
        
        // Recompute boot state
        await refreshBootState()
    }
    
    func refreshBootState() async {
        do {
            bootState = try await bootstrapper.bootstrap(sourceRegistry: sourceRegistry)
        } catch {
            bootState = .fatal(.configurationLoadFailed(String(describing: error)))
        }
    }
    
    func shutdown() {
        Task { @MainActor in
            await sourceRegistry.shutdown()
        }
    }
    
    // MARK: - Private Helpers
    private func boot() {
        Task { @MainActor in
            do {
                bootState = try await bootstrapper.bootstrap(sourceRegistry: sourceRegistry)
            } catch {
                bootState = .fatal(.configurationLoadFailed(String(describing: error)))
            }
        }
    }
    
    private var currentContext: BootstrapContext? {
        switch bootState {
        case .setupRequired(let context, _, _),
             .ready(let context, _),
             .degraded(let context, _, _):
            return context
        case .launching, .fatal:
            return nil
        }
    }
}
