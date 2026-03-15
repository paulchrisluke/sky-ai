import Foundation
import EventKit

struct CalendarSourceDescriptor: Sendable {
    let id: String
    let sourceName: String
}

struct RawEvent: Sendable {
    let calendarId: String
    let calendarName: String
    let payload: CalendarEventPayload
}

struct CalendarEventPayload: Codable {
    let uid: String
    let title: String
    let description: String?
    let location: String?
    let startAt: String
    let endAt: String
    let allDay: Bool
    let recurrenceRule: String?
    let status: String
    let organizerEmail: String?
    let organizerName: String?
    let attendees: [[String: String?]]
    let rawIcal: String?
}

struct CalendarPayload: Codable {
    let type: String
    let workspaceId: String
    let accountId: String
    let calendarId: String
    let calendarName: String
    let sourceProvider: String
    let events: [CalendarEventPayload]
}

final class CalendarWatcher: @unchecked Sendable {
    private let config: Config
    private let logger: Logger
    private let eventStore = EKEventStore()
    private let iso = ISO8601DateFormatter()
    private var hasAccess = false
    private var observer: NSObjectProtocol?
    private var safetyTimer: DispatchSourceTimer?

    init(config: Config, logger: Logger) {
        self.config = config
        self.logger = logger
        self.iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func startObserving(onChange: @escaping @Sendable () -> Void) {
        Task {
            do {
                try await ensureAccess()
                observer = NotificationCenter.default.addObserver(
                    forName: .EKEventStoreChanged,
                    object: eventStore,
                    queue: nil
                ) { _ in
                    onChange()
                }

                let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
                timer.schedule(deadline: .now() + 900, repeating: 900)
                timer.setEventHandler {
                    onChange()
                }
                safetyTimer = timer
                timer.resume()
                logger.info("calendar observer started (EKEventStoreChanged + 15m safety)")
            } catch {
                logger.error("calendar observer start failed: \(error.localizedDescription)")
            }
        }
    }

    func stopObserving() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        safetyTimer?.cancel()
        safetyTimer = nil
        logger.info("calendar observer stopped")
    }

    func fetchUnsentPayloads(backfill: Bool) async throws -> [CalendarPayload] {
        try await ensureAccess()
        return buildPayloads(backfill: backfill)
    }

    func calendarSourceNames() async throws -> [String] {
        try await ensureAccess()
        let calendars = eventStore.calendars(for: .event)
        let names = calendars.map { calendar -> String in
            let source = calendar.source.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let title = calendar.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if source.isEmpty { return title }
            if title.isEmpty { return source }
            return "\(source) / \(title)"
        }
        return names
            .filter { !$0.isEmpty }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func discoverSources() async throws -> [CalendarSourceDescriptor] {
        try await ensureAccess()
        let calendars = eventStore.calendars(for: .event)
        
        // Deduplicate by calendarIdentifier to avoid duplicates from multiple accounts
        let uniqueCalendars = Dictionary(grouping: calendars, by: { $0.calendarIdentifier })
            .compactMapValues { $0.first } // Take the first occurrence of each unique calendar
        
        return uniqueCalendars.values
            .map { CalendarSourceDescriptor(id: $0.calendarIdentifier, sourceName: $0.title) }
            .sorted { $0.sourceName.localizedCaseInsensitiveCompare($1.sourceName) == .orderedAscending }
    }

    func fetchEvents(calendarId: String, since: Date, until: Date) async throws -> [RawEvent] {
        try await ensureAccess()
        guard let calendar = eventStore.calendars(for: .event).first(where: { $0.calendarIdentifier == calendarId }) else {
            return []
        }
        let start = min(since, until)
        let end = max(since, until)
        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        let events = eventStore.events(matching: predicate)
        return events.map { event in
            let attendees: [[String: String?]] = (event.attendees ?? []).map { attendee in
                [
                    "email": attendee.url.absoluteString,
                    "name": attendee.name,
                    "status": participantStatusString(attendee.participantStatus)
                ]
            }
            return RawEvent(
                calendarId: calendar.calendarIdentifier,
                calendarName: calendar.title,
                payload: CalendarEventPayload(
                    uid: event.calendarItemIdentifier,
                    title: event.title ?? "",
                    description: event.notes,
                    location: event.location,
                    startAt: iso.string(from: event.startDate),
                    endAt: iso.string(from: event.endDate),
                    allDay: event.isAllDay,
                    recurrenceRule: event.recurrenceRules?.first?.description,
                    status: "confirmed",
                    organizerEmail: event.organizer?.url.absoluteString,
                    organizerName: event.organizer?.name,
                    attendees: attendees,
                    rawIcal: nil
                )
            )
        }
    }

    private func ensureAccess() async throws {
        if hasAccess {
            return
        }
        if #available(macOS 14.0, *) {
            let granted: Bool = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, Error>) in
                eventStore.requestFullAccessToEvents { granted, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    continuation.resume(returning: granted)
                }
            }
            if !granted {
                throw NSError(
                    domain: "CalendarWatcher",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "calendar access denied"]
                )
            }
            hasAccess = true
        } else {
            throw NSError(
                domain: "CalendarWatcher",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "requestFullAccessToEvents requires macOS 14+"]
            )
        }
    }

    private func buildPayloads(backfill: Bool) -> [CalendarPayload] {
        let now = Date()
        let backDays = backfill ? -3650 : -7
        let forwardDays = backfill ? 365 : 30
        guard let start = Calendar.current.date(byAdding: .day, value: backDays, to: now),
              let end = Calendar.current.date(byAdding: .day, value: forwardDays, to: now) else {
            logger.error("calendar date range generation failed")
            return []
        }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)

        let grouped = Dictionary(grouping: events, by: { $0.calendar.calendarIdentifier })
        var out: [CalendarPayload] = []

        for calendar in eventStore.calendars(for: .event) {
            let calendarEvents = grouped[calendar.calendarIdentifier] ?? []
            if calendarEvents.isEmpty {
                continue
            }

            out.append(
                CalendarPayload(
                type: "calendar",
                workspaceId: config.workspaceId,
                accountId: config.accountId,
                calendarId: calendar.calendarIdentifier,
                calendarName: calendar.title,
                sourceProvider: "calendar_mac",
                events: calendarEvents.map { event in
                    let attendees: [[String: String?]] = (event.attendees ?? []).map { attendee in
                        [
                            "email": attendee.url.absoluteString,
                            "name": attendee.name,
                            "status": participantStatusString(attendee.participantStatus)
                        ]
                    }
                    return CalendarEventPayload(
                        uid: event.calendarItemIdentifier,
                        title: event.title ?? "",
                        description: event.notes,
                        location: event.location,
                        startAt: iso.string(from: event.startDate),
                        endAt: iso.string(from: event.endDate),
                        allDay: event.isAllDay,
                        recurrenceRule: event.recurrenceRules?.first?.description,
                        status: "confirmed",
                        organizerEmail: event.organizer?.url.absoluteString,
                        organizerName: event.organizer?.name,
                        attendees: attendees,
                        rawIcal: nil
                    )
                }
            ))
        }
        return out
    }

    private func participantStatusString(_ status: EKParticipantStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "in_process"
        @unknown default: return "unknown"
        }
    }
}
