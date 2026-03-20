import Foundation
import SwiftUI
import EventKit

// MARK: - Calendar Source Provider
final class CalendarSourceProvider: SourceProvider {
    let kind: SourceKind = .calendar
    
    func discover(in context: BootstrapContext) async -> DiscoveredSourceCapability {
        // Calendar is always available on macOS
        let availability: SourceAvailability = .available
        
        // Check current authorization status without requesting
        let authorization = await checkCalendarAuthorizationStatus()
        
        // Discovery only reports discovery state, not runtime activation state
        let discoveryStatus: SourceDiscoveryStatus = .inactive
        
        return DiscoveredSourceCapability(
            kind: .calendar,
            displayName: "Calendar",
            availability: availability,
            authorization: authorization,
            discoveryStatus: discoveryStatus,
            isRequiredForCoreValue: false,
            canDefer: true
        )
    }
    
    func activate(in context: BootstrapContext) async throws -> ActiveSource {
        // Request permission if needed
        let currentStatus = await checkCalendarAuthorizationStatus()
        if !currentStatus.isAuthorized {
            try await requestCalendarAccess()
        }
        
        // Create calendar watcher
        let watcher = CalendarWatcher(config: context.config, logger: context.logger)
        
        // Start the watcher
        try await watcher.startObserving(onChange: { })
        
        // Mark onboarding as completed (actual enabled state managed by registry)
        context.activationStateStore.onboardingCompleted = true
        
        // Return active source with stop function
        return ActiveSource(
            kind: .calendar,
            stop: {
                await watcher.stopObserving()
            }
        )
    }
    
    // MARK: - Private Methods
    private func checkCalendarAuthorizationStatus() async -> SourceAuthorizationStatus {
        let status = EKEventStore.authorizationStatus(for: .event)
        
        switch status {
        case .authorized: return .authorized
        case .denied: return .denied
        case .restricted: return .restricted
        case .notDetermined: return .notDetermined
        case .fullAccess: return .authorized
        case .writeOnly: return .authorized
        @unknown default: return .notDetermined
        }
    }
    
    private func requestCalendarAccess() async throws {
        return try await withCheckedThrowingContinuation { continuation in
            let eventStore = EKEventStore()
            
            if #available(macOS 14.0, *) {
                eventStore.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if !granted {
                        continuation.resume(throwing: NSError(domain: "CalendarSourceProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access denied"]))
                        return
                    }
                    continuation.resume(returning: ())
                }
            } else {
                // For older macOS, use the older API
                eventStore.requestAccess(to: .event) { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if !granted {
                        continuation.resume(throwing: NSError(domain: "CalendarSourceProvider", code: 1, userInfo: [NSLocalizedDescriptionKey: "Calendar access denied"]))
                        return
                    }
                    continuation.resume(returning: ())
                }
            }
        }
    }
    
    // MARK: - Issue Generation
    func generateIssues(for capability: DiscoveredSourceCapability) -> [SourceIssue] {
        var issues: [SourceIssue] = []
        
        switch capability.authorization {
        case .denied:
            issues.append(SourceIssue(
                kind: .calendar,
                severity: .warning,
                category: .authorization,
                title: "Calendar Access Denied",
                description: "Blawby cannot access your calendar events",
                repairActions: [
                    .openSystemSettings(.calendar)
                ]
            ))
        case .restricted:
            issues.append(SourceIssue(
                kind: .calendar,
                severity: .warning,
                category: .authorization,
                title: "Calendar Access Restricted",
                description: "Calendar access is restricted by system policy",
                repairActions: [
                    .openSystemSettings(.calendar),
                    .contactSupport(.calendar)
                ]
            ))
        case .notDetermined:
            issues.append(SourceIssue(
                kind: .calendar,
                severity: .info,
                category: .authorization,
                title: "Calendar Access Available",
                description: "Enable calendar access for event scheduling",
                repairActions: [
                    .requestPermission(.calendar)
                ]
            ))
        case .authorized, .notRequired:
            break
        }
        
        return issues
    }
    
    func generateActivationFailureIssues(for error: Error) -> [SourceIssue] {
        return [SourceIssue(
            kind: .calendar,
            severity: .error,
            category: .activation,
            title: "Calendar Activation Failed",
            description: error.localizedDescription,
            repairActions: [
                .retryActivation(.calendar),
                .contactSupport(.calendar)
            ]
        )]
    }
}
