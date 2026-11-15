import EventKit
import Foundation

/// Reads the details of one event occurrence. The app reads EventKit; the screenshot demo returns fixed details.
public protocol CalendarEventDetailsReading: Sendable {
    func details(eventID: String, startsAt: Date) async -> CalendarEventDetails?
}

public actor CalendarProvider: CalendarEventDetailsReading {
    private let store = EKEventStore()
    public init() {}

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func calendars() -> [String] {
        Array(Set(store.calendars(for: .event).map(\.title))).sorted()
    }

    public func events(start: Date, end: Date, selectedCalendars: Set<String>) throws -> [CalendarEventSnapshot] {
        store.events(matching: Self.predicate(in: store, start: start, end: end, selectedCalendars: selectedCalendars)).map { event in
            CalendarEventSnapshot(
                id: event.eventIdentifier ?? UUID().uuidString,
                externalIdentifier: event.calendarItemExternalIdentifier,
                title: event.title ?? "(タイトルなし)", startsAt: event.startDate, endsAt: event.endDate,
                calendarTitle: event.calendar.title, isAllDay: event.isAllDay,
                participationStatus: participationStatus(of: event)
            )
        }
    }

    /// Details of the events in a range. Empty without full calendar access; never asks for it.
    public func details(start: Date, end: Date, selectedCalendars: Set<String>) -> [CalendarEventDetails] {
        Self.details(in: store, start: start, end: end, selectedCalendars: selectedCalendars)
    }

    /// The same read for a caller that owns its store and must answer synchronously, such as `LoreAppEventDetailsServer`.
    static func details(in store: EKEventStore, start: Date, end: Date, selectedCalendars: Set<String>) -> [CalendarEventDetails] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [] }
        return store.events(matching: predicate(in: store, start: start, end: end, selectedCalendars: selectedCalendars))
            .compactMap(details(of:))
    }

    /// Details of one occurrence. `event(withIdentifier:)` would return the first occurrence of a series,
    /// so this reads the occurrences around `startsAt` and picks the one that starts then.
    public func details(eventID: String, startsAt: Date) -> CalendarEventDetails? {
        details(start: startsAt.addingTimeInterval(-1), end: startsAt.addingTimeInterval(1), selectedCalendars: [])
            .occurrence(eventID: eventID, startsAt: startsAt)
    }

    private static func predicate(in store: EKEventStore, start: Date, end: Date, selectedCalendars: Set<String>) -> NSPredicate {
        let calendars = store.calendars(for: .event).filter { selectedCalendars.isEmpty || selectedCalendars.contains($0.title) }
        return store.predicateForEvents(withStart: start, end: end, calendars: calendars)
    }

    private static func details(of event: EKEvent) -> CalendarEventDetails? {
        guard let eventID = event.eventIdentifier else { return nil }
        return CalendarEventDetails(
            eventID: eventID, startsAt: event.startDate,
            externalIdentifier: event.calendarItemExternalIdentifier,
            notes: event.notes, location: event.location, url: event.url,
            organizer: event.organizer.map(attendee),
            attendees: (event.attendees ?? []).map(attendee),
            isCanceled: event.status == .canceled
        )
    }

    private static func attendee(_ participant: EKParticipant) -> CalendarAttendee {
        CalendarAttendee(
            name: participant.name,
            email: CalendarAttendee.email(fromParticipantURL: participant.url),
            status: status(participant.participantStatus),
            role: role(participant.participantRole),
            kind: kind(participant.participantType),
            isCurrentUser: participant.isCurrentUser
        )
    }

    private func participationStatus(of event: EKEvent) -> CalendarParticipationStatus {
        guard let status = event.attendees?.first(where: \.isCurrentUser)?.participantStatus else { return .none }
        return Self.status(status)
    }

    private static func status(_ status: EKParticipantStatus) -> CalendarParticipationStatus {
        switch status {
        case .pending: .pending
        case .accepted: .accepted
        case .declined: .declined
        case .tentative: .tentative
        case .unknown, .delegated, .completed, .inProcess: .unknown
        @unknown default: .unknown
        }
    }

    private static func role(_ role: EKParticipantRole) -> CalendarAttendeeRole {
        switch role {
        case .required: .required
        case .optional: .optional
        case .chair: .chair
        case .nonParticipant: .nonParticipant
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }

    private static func kind(_ type: EKParticipantType) -> CalendarAttendeeKind {
        switch type {
        case .person: .person
        case .room: .room
        case .resource: .resource
        case .group: .group
        case .unknown: .unknown
        @unknown default: .unknown
        }
    }
}
