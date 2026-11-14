import EventKit
import Foundation

public actor CalendarProvider {
    private let store = EKEventStore()
    public init() {}

    public func requestAccess() async throws -> Bool {
        try await store.requestFullAccessToEvents()
    }

    public func calendars() -> [String] {
        Array(Set(store.calendars(for: .event).map(\.title))).sorted()
    }

    public func events(start: Date, end: Date, selectedCalendars: Set<String>) throws -> [CalendarEventSnapshot] {
        let calendars = store.calendars(for: .event).filter { selectedCalendars.isEmpty || selectedCalendars.contains($0.title) }
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars)).map { event in
            CalendarEventSnapshot(
                id: event.eventIdentifier ?? UUID().uuidString,
                externalIdentifier: event.calendarItemExternalIdentifier,
                title: event.title ?? "(タイトルなし)", startsAt: event.startDate, endsAt: event.endDate,
                calendarTitle: event.calendar.title, isAllDay: event.isAllDay,
                participationStatus: participationStatus(of: event)
            )
        }
    }

    private func participationStatus(of event: EKEvent) -> CalendarParticipationStatus {
        guard let status = event.attendees?.first(where: \.isCurrentUser)?.participantStatus else { return .none }
        switch status {
        case .pending: return .pending
        case .accepted: return .accepted
        case .declined: return .declined
        case .tentative: return .tentative
        case .unknown, .delegated, .completed, .inProcess: return .unknown
        @unknown default: return .unknown
        }
    }
}
