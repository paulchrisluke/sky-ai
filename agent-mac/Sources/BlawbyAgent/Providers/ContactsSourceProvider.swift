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
        let currentStatus = await checkContactsAuthorizationStatus()
        if !currentStatus.isAuthorized {
            try await requestContactsAccess()
        }

        return ActiveSource(
            kind: .contacts,
            stop: { }
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
    
    func generateActivationFailureIssues(for error: Error) -> [SourceIssue] {
        let errorMessage = error.localizedDescription.lowercased()
        
        if errorMessage.contains("denied") || errorMessage.contains("restricted") {
            return [SourceIssue(
                kind: .contacts,
                severity: .error,
                category: .authorization,
                title: "Contacts Access Denied",
                description: "Blawby cannot access your contacts. Please check your privacy settings.",
                repairActions: [
                    .openSystemSettings(.contacts)
                ]
            )]
        } else {
            return [SourceIssue(
                kind: .contacts,
                severity: .error,
                category: .activation,
                title: "Contacts Activation Failed",
                description: error.localizedDescription,
                repairActions: [
                    .retryActivation(.contacts)
                ]
            )]
        }
    }
}
