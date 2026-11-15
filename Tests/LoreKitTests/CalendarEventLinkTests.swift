import Foundation
import Testing
@testable import LoreKit

@Suite("Open an event in Calendar or Google Calendar")
struct CalendarEventLinkTests {
    static let googleID = "k3v8q2m1abcd@google.com"
    static let email = "someone@example.com"
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    @Test("The Calendar app address percent-encodes the whole event identifier")
    func calendarApp() {
        #expect(CalendarEventLink.calendarApp(eventID: "A1B2-C3:D4/E5 F6")?.absoluteString
            == "ical://ekevent/A1B2-C3%3AD4%2FE5%20F6?method=show")
        #expect(CalendarEventLink.calendarApp(eventID: "") == nil)
    }

    @Test("A single Google event opens by its event id and the calendar email")
    func singleGoogleEvent() {
        let url = CalendarEventLink.googleCalendar(externalIdentifier: Self.googleID, calendarEmail: Self.email,
                                                   occurrenceStart: nil, isAllDay: false)
        // Base64 of "k3v8q2m1abcd someone@example.com".
        #expect(url?.absoluteString == "https://calendar.google.com/calendar/event?eid=azN2OHEybTFhYmNkIHNvbWVvbmVAZXhhbXBsZS5jb20")
    }

    @Test("An occurrence of a repeating event opens that occurrence: UTC start for timed, local date for all-day")
    func repeatingOccurrence() throws {
        let timed = try Date("2026-11-16T09:30:00+09:00", strategy: .iso8601)
        #expect(CalendarEventLink.googleCalendar(externalIdentifier: Self.googleID, calendarEmail: Self.email,
                                                 occurrenceStart: timed, isAllDay: false, timeZone: Self.tokyo)?.absoluteString
            // Base64 of "k3v8q2m1abcd_20261116T003000Z someone@example.com".
            == "https://calendar.google.com/calendar/event?eid=azN2OHEybTFhYmNkXzIwMjYxMTE2VDAwMzAwMFogc29tZW9uZUBleGFtcGxlLmNvbQ")
        let allDay = try Date("2026-11-16T00:00:00+09:00", strategy: .iso8601)
        #expect(CalendarEventLink.googleCalendar(externalIdentifier: Self.googleID, calendarEmail: Self.email,
                                                 occurrenceStart: allDay, isAllDay: true, timeZone: Self.tokyo)?.absoluteString
            // Base64 of "k3v8q2m1abcd_20261116 someone@example.com".
            == "https://calendar.google.com/calendar/event?eid=azN2OHEybTFhYmNkXzIwMjYxMTE2IHNvbWVvbmVAZXhhbXBsZS5jb20")
    }

    @Test("The eid uses the URL-safe alphabet without padding")
    func urlSafe() {
        let url = CalendarEventLink.googleCalendar(externalIdentifier: Self.googleID, calendarEmail: "x?@example.com",
                                                   occurrenceStart: nil, isAllDay: false)
        // Standard Base64 would be "azN2OHEybTFhYmNkIHg/QGV4YW1wbGUuY29t".
        #expect(url?.absoluteString == "https://calendar.google.com/calendar/event?eid=azN2OHEybTFhYmNkIHg_QGV4YW1wbGUuY29t")
    }

    @Test("Anything without the Google shape gets no Google address", arguments: [
        (nil, email),
        ("", email),
        ("k3v8q2m1abcd", email),
        ("k3v8q2m1abcd@google.com.example.net", email),
        ("k3v8q2m1abcd@calendar.example.com", email),
        ("040000008200E00074C5B7101A82E008@google.com", email),
        ("abc_R20261116T003000@google.com", email),
        ("k3v8w@google.com", email),
        ("abcd@google.com", email),
        ("@google.com", email),
        ("8F3C1B2A-6D4E-4A1F-9B7C-2E5D8A9F0C13", email),
        (googleID, nil),
        (googleID, ""),
        (googleID, "Work"),
        (googleID, "Google"),
        (googleID, "@example.com"),
        (googleID, "someone@example"),
        (googleID, "some one@example.com"),
        (googleID, "a@b@example.com"),
        (googleID, "someone@example..com"),
    ] as [(String?, String?)])
    func noGoogleShape(externalIdentifier: String?, calendarEmail: String?) {
        #expect(CalendarEventLink.googleCalendar(externalIdentifier: externalIdentifier, calendarEmail: calendarEmail,
                                                 occurrenceStart: nil, isAllDay: false) == nil)
    }

    @Test("The demo has one event with a Google address and one without")
    func demoLinks() async {
        let reader = DemoCalendarEventDetails(copy: .english)
        #expect(await reader.details(eventID: "demo-event-1", startsAt: Date())?.googleCalendarURL != nil)
        #expect(await reader.details(eventID: "demo-event-2", startsAt: Date())?.googleCalendarURL == nil)
    }

    @Test("A response read later replaces the pending snapshot, so the No Response tag goes away")
    func responseReplacesPending() async throws {
        let database = try await LoreDatabase.inMemory()
        let calendar = Calendar.current
        let day = try #require(calendar.dateInterval(of: .day, for: Date()))
        func invite(_ status: CalendarParticipationStatus) -> CalendarEventSnapshot {
            CalendarEventSnapshot(id: "invite", title: "Sync", startsAt: day.start.addingTimeInterval(11 * 3600),
                                  endsAt: day.start.addingTimeInterval(12 * 3600), calendarTitle: "Work", participationStatus: status)
        }

        try await database.lifeLog.replaceCalendarEvents([invite(.pending)], in: day)
        #expect(try await database.lifeLog.day(day.start).calendarEvents.map(\.participationStatus) == [.pending])
        #expect(try await database.lifeLog.day(day.start, participatingOnly: true).calendarEvents.map(\.participationStatus) == [.pending])

        try await database.lifeLog.replaceCalendarEvents([invite(.accepted)], in: day)
        #expect(try await database.lifeLog.day(day.start).calendarEvents.map(\.participationStatus) == [.accepted])
    }
}
