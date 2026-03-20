import Foundation
import SwiftUI
import Contacts

// MARK: - Contacts Source Provider
final class ContactsSourceProvider: SourceProvider {
    let kind: SourceKind = .contacts
    
    func discover(in context: BootstrapContext) async -> SourceCapability {
        // Contacts is always available on macOS
        let availability: SourceAvailability = .available
        
        // Check current authorization status without requesting
        let authorization = await checkContactsAuthorizationStatus()
        
        // Discovery only reports availability/auth, not runtime activation state
        let activation: SourceActivationStatus = .inactive
        
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
    
    func activate(in context: BootstrapContext) async throws -> ActiveSource {
        // Request permission if needed
        let currentStatus = await checkContactsAuthorizationStatus()
        if !currentStatus.isAuthorized {
            try await requestContactsAccess()
        }
        
        // Create contacts watcher
        let watcher = ContactsWatcher(config: context.config, logger: context.logger)
        
        // Start the watcher
        try await watcher.startObserving()
        
        // Return active source with stop function
        return ActiveSource(
            kind: .contacts,
            stop: {
                await watcher.stopObserving()
            }
        )
    }
    
    // MARK: - Contacts Authorization
    private func checkContactsAuthorizationStatus() async -> SourceAuthorizationStatus {
        // Check current status WITHOUT requesting access
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }
    
    private func requestContactsAccess() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let contactStore = CNContactStore()
            
            contactStore.requestAccess(for: .contacts) { granted, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                if !granted {
                    continuation.resume(throwing: NSError(domain: "ContactsSourceProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Contacts access denied"]))
                    return
                }
                continuation.resume()
            }
        }
    }
    
    // MARK: - Issue Generation
    func generateIssues(for capability: SourceCapability) -> [SourceIssue] {
        var issues: [SourceIssue] = []
        
        switch capability.authorization {
        case .denied:
            issues.append(SourceIssue(
                kind: .contacts,
                severity: .warning,
                category: .authorization,
                title: "Contacts Access Denied",
                description: "Blawby cannot access your contacts for enrichment",
                repairActions: [
                    .openSystemSettings(.contacts)
                ]
            ))
        case .restricted:
            issues.append(SourceIssue(
                kind: .contacts,
                severity: .warning,
                category: .authorization,
                title: "Contacts Access Restricted",
                description: "Contacts access is restricted by system policy",
                repairActions: [
                    .openSystemSettings(.contacts),
                    .contactSupport(.contacts)
                ]
            ))
        case .notDetermined:
            issues.append(SourceIssue(
                kind: .contacts,
                severity: .info,
                category: .authorization,
                title: "Contacts Access Available",
                description: "Enable contacts for better task enrichment",
                repairActions: [
                    .requestPermission(.contacts)
                ]
            ))
        case .authorized, .notRequired:
            break
        }
        
        return issues
    }
}
