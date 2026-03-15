import Foundation
import EventKit

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

final class CalendarWatcher {
    private let config: Config
    private let logger: Logger
    private let onPayload: (String) -> Void
    private let eventStore = EKEventStore()
    private let iso = ISO8601DateFormatter()
    private var snapshotByCalendar: [String: String] = [:]
    private var storeObserver: NSObjectProtocol?

    init(config: Config, logger: Logger, onPayload: @escaping (String) -> Void) {
        self.config = config
        self.logger = logger
        self.onPayload = onPayload
        self.iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    func start() {
        requestAccess()
    }

    private func requestAccess() {
        if #available(macOS 14.0, *) {
            eventStore.requestFullAccessToEvents { [weak self] granted, error in
                guard let self else { return }
                if let error {
                    self.logger.error("calendar access error: \(error.localizedDescription)")
                    return
                }
                guard granted else {
                    self.logger.error("calendar access denied")
                    return
                }
                self.startObserving()
                self.refetchAndEmitChanges()
            }
        } else {
            logger.error("requestFullAccessToEvents requires macOS 14+")
            exit(1)
        }
    }

    private func startObserving() {
        storeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: eventStore,
            queue: nil
        ) { [weak self] _ in
            self?.handleStoreChanged()
        }
        logger.info("calendar observer registered")
    }

    private func handleStoreChanged() {
        logger.info("calendar store changed")
        refetchAndEmitChanges()
    }

    private func refetchAndEmitChanges() {
        let now = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -7, to: now),
              let end = Calendar.current.date(byAdding: .day, value: 30, to: now) else {
            logger.error("calendar date range generation failed")
            return
        }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = eventStore.events(matching: predicate)

        let grouped = Dictionary(grouping: events, by: { $0.calendar.calendarIdentifier })

        for calendar in eventStore.calendars(for: .event) {
            let calendarEvents = grouped[calendar.calendarIdentifier] ?? []
            let payload = CalendarPayload(
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
            )

            do {
                let data = try JSONEncoder().encode(payload)
                guard let json = String(data: data, encoding: .utf8) else { continue }
                if snapshotByCalendar[calendar.calendarIdentifier] != json {
                    snapshotByCalendar[calendar.calendarIdentifier] = json
                    logger.info(
                        "calendar payload sent calendar=\(calendar.title) calendarId=\(calendar.calendarIdentifier) eventCount=\(calendarEvents.count)"
                    )
                    onPayload(json)
                }
            } catch {
                logger.error("calendar encode error for \(calendar.title): \(error.localizedDescription)")
            }
        }
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
