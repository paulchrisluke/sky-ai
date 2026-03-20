import Foundation
import SwiftUI

// MARK: - Mail Source Provider
final class MailSourceProvider: SourceProvider {
    let kind: SourceKind = .mail
    
    func discover(in context: BootstrapContext) async -> SourceCapability {
        // Check if Mail.app is available
        let mailUrl = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Mail")
        let availability: SourceAvailability = mailUrl != nil ? .available : .unavailable(reason: "Mail.app not installed")
        
        // Mail uses Apple Events - authorization state unknown until activation
        let authorization: SourceAuthorizationStatus = .notRequired
        
        // Discovery only reports availability/auth, not runtime activation state
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
    
    func activate(in context: BootstrapContext) async throws -> ActiveSource {
        // Create mail watcher - Apple Events permission will be checked during start
        let watcher = MailWatcher(configStore: context.configStore, logger: context.logger)
        
        // Start the watcher - this will fail if automation permission is denied
        do {
            try await watcher.startObserving(onChange: { })
        } catch {
            // Normalize runtime errors to appropriate activation errors
            let normalizedError = normalizeActivationError(error)
            throw normalizedError
        }
        
        // Return active source with stop function
        return ActiveSource(
            kind: .mail,
            stop: {
                await watcher.stopObserving()
            }
        )
    }
    
    // MARK: - Error Normalization
    private func normalizeActivationError(_ error: Error) -> SourceActivationError {
        let errorMessage = error.localizedDescription.lowercased()
        
        if errorMessage.contains("apple events") || errorMessage.contains("automation") || errorMessage.contains("permission denied") {
            return .automationDenied
        } else if errorMessage.contains("mail") || errorMessage.contains("watcher") || errorMessage.contains("monitoring") {
            return .watcherStartFailed(error.localizedDescription)
        } else {
            // Default to watcher failed for unknown errors
            return .watcherStartFailed("Mail activation failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Issue Generation
    func generateIssues(for capability: SourceCapability) -> [SourceIssue] {
        var issues: [SourceIssue] = []
        
        switch capability.availability {
        case .unavailable(let reason):
            issues.append(SourceIssue(
                kind: .mail,
                severity: .error,
                category: .availability,
                title: "Mail Not Available",
                description: "Mail.app could not be found: \(reason)",
                repairActions: [
                    .contactSupport(.mail)
                ]
            ))
        case .available:
            break
        }
        
        // No unconditional automation warning - issues come from activation failure
        return issues
    }
    
    // MARK: - Activation Failure Issues
    func generateActivationFailureIssues(for error: Error) -> [SourceIssue] {
        if let activationError = error as? SourceActivationError {
            switch activationError {
            case .automationDenied:
                return [SourceIssue(
                    kind: .mail,
                    severity: .error,
                    category: .authorization,
                    title: "Apple Events Required",
                    description: "Blawby needs Apple Events permission to access Mail",
                    repairActions: [
                        .enableAutomation(.mail),
                        .openSystemSettings(.mail),
                        .retryActivation(.mail)
                    ]
                )]
            case .watcherStartFailed(let reason):
                return [SourceIssue(
                    kind: .mail,
                    severity: .error,
                    category: .activation,
                    title: "Mail Activation Failed",
                    description: "Failed to start Mail monitoring: \(reason)",
                    repairActions: [
                        .retryActivation(.mail),
                        .contactSupport(.mail)
                    ]
                )]
            }
        }
        return []
    }
}

// MARK: - Mail Activation Errors
enum SourceActivationError: LocalizedError {
    case automationDenied
    case watcherStartFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .automationDenied:
            return "Apple Events access was denied"
        case .watcherStartFailed(let reason):
            return "Failed to start Mail watcher: \(reason)"
        }
    }
    
    var recoverySuggestion: String? {
        switch self {
        case .automationDenied:
            return "Open System Settings > Privacy & Security > Automation and enable Blawby for Mail"
        case .watcherStartFailed:
            return "Try restarting the application or checking Mail settings"
        }
    }
}
