import EventKit
import Foundation
import Testing
@testable import LoreKit

struct ConferenceLinkCase: CustomTestStringConvertible, Sendable {
    var name: String
    var url: String?
    var location: String?
    var notes: String?
    var expected: (ConferenceProvider, String)?

    var testDescription: String { name }
}

@Suite("Event details and join links")
struct CalendarEventDetailsTests {
    static let meet = "https://meet.google.com/abc-defg-hij"
    static let zoom = "https://us02web.zoom.us/j/81234567890?pwd=AbCd"
    static let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_ABC%40thread.v2/0?context=%7b%7d"
    static let webex = "https://example.webex.com/example/j.php?MTID=m0123abcd"

    static let cases: [ConferenceLinkCase] = [
        .init(name: "Google Meet in notes with surrounding text", notes: "Agenda: roadmap.\nJoin with Google Meet: \(meet)\nJoin by phone: +1 555-0100", expected: (.googleMeet, meet)),
        .init(name: "Google Meet in an HTML link", notes: "<p>Join: <a href=\"\(meet)\">\(meet)</a></p>", expected: (.googleMeet, meet)),
        .init(name: "Google Meet without a scheme in location", location: "meet.google.com/abc-defg-hij", expected: (.googleMeet, meet)),
        .init(name: "Google Meet in the URL field", url: meet, expected: (.googleMeet, meet)),
        .init(name: "Zoom on a company subdomain in location", location: "Zoom: \(zoom)", expected: (.zoom, zoom)),
        .init(name: "Zoom personal room", notes: "My room: https://zoom.us/my/aoi.mori.", expected: (.zoom, "https://zoom.us/my/aoi.mori")),
        .init(name: "Zoom over http becomes https", location: "http://zoom.us/j/123456789", expected: (.zoom, "https://zoom.us/j/123456789")),
        .init(name: "Microsoft Teams meetup-join in notes", notes: "Microsoft Teams meeting\nJoin on your computer: \(teams)\nMeeting ID: 123", expected: (.microsoftTeams, teams)),
        .init(name: "Microsoft Teams short meet link", notes: "Join: https://teams.microsoft.com/meet/2345678901?p=abc", expected: (.microsoftTeams, "https://teams.microsoft.com/meet/2345678901?p=abc")),
        .init(name: "Microsoft Teams for personal accounts", location: "https://teams.live.com/meet/9876543210", expected: (.microsoftTeams, "https://teams.live.com/meet/9876543210")),
        .init(name: "Webex j.php link in notes", notes: "Join meeting \(webex) Meeting number: 2600 000 000", expected: (.webex, webex)),
        .init(name: "Webex personal room", location: "https://example.webex.com/meet/aoi", expected: (.webex, "https://example.webex.com/meet/aoi")),
        .init(name: "Several links in one field: the first wins", notes: "Primary \(zoom)\nBackup \(meet)", expected: (.zoom, zoom)),
        .init(name: "Non-meeting link before a meeting link is skipped", notes: "Help: https://support.google.com/a/users/answer/9282720\nJoin: \(meet)", expected: (.googleMeet, meet)),
        .init(name: "URL field wins over location and notes", url: teams, location: zoom, notes: meet, expected: (.microsoftTeams, teams)),
        .init(name: "Location wins over notes", location: "Room 4A, \(zoom)", notes: "Join with Google Meet: \(meet)", expected: (.zoom, zoom)),
        .init(name: "A non-meeting URL field falls through to notes", url: "https://example.com/agenda", notes: meet, expected: (.googleMeet, meet)),
        .init(name: "Provider pages that are not meetings", notes: "https://zoom.us/download https://help.webex.com/en-us https://teams.microsoft.com/ https://meet.google.com/", expected: nil),
        .init(name: "Lookalike hosts", notes: "https://meet.google.com.example.net/abc https://notzoom.us/j/1 https://webex.com.example.net/meet/a", expected: nil),
        .init(name: "Text with no link", location: "Room 4A", notes: "Bring the printed agenda.", expected: nil),
        .init(name: "No fields", expected: nil),
    ]

    @Test("Join link extraction", arguments: cases)
    func extraction(_ testCase: ConferenceLinkCase) {
        let link = ConferenceLink.first(url: testCase.url.flatMap(URL.init(string:)), location: testCase.location, notes: testCase.notes)
        #expect(link?.provider == testCase.expected?.0)
        #expect(link?.url.absoluteString == testCase.expected?.1)
    }

    @Test("Details carry the extracted join link")
    func detailsExtractLink() {
        let details = CalendarEventDetails(eventID: "e", startsAt: Date(), location: "Zoom: \(Self.zoom)")
        #expect(details.conferenceLink == ConferenceLink(provider: .zoom, url: URL(string: Self.zoom)!))
    }

    @Test("Attendee email comes from a mailto URL only", arguments: [
        ("mailto:aoi@example.com", "aoi@example.com"),
        ("MAILTO:aoi@example.com", "aoi@example.com"),
        ("mailto:aoi%2Bwork@example.com", "aoi+work@example.com"),
        ("urn:uuid:5A5F6A2E-0000-0000-0000-000000000000", nil),
        ("mailto:", nil),
    ] as [(String, String?)])
    func attendeeEmail(_ raw: String, _ expected: String?) {
        #expect(CalendarAttendee.email(fromParticipantURL: URL(string: raw)!) == expected)
    }

    @Test("One occurrence of a repeating event gets that occurrence's details, not the series' first")
    func occurrenceOfRepeatingEvent() {
        let first = Date(timeIntervalSince1970: 1_800_000_000)
        let week: TimeInterval = 7 * 24 * 3600
        let occurrences = (0..<3).map { index in
            CalendarEventDetails(eventID: "weekly", startsAt: first.addingTimeInterval(Double(index) * week), notes: "Week \(index + 1)")
        } + [CalendarEventDetails(eventID: "other", startsAt: first.addingTimeInterval(week), notes: "Other event")]

        #expect(occurrences.occurrence(eventID: "weekly", startsAt: first.addingTimeInterval(week))?.notes == "Week 2")
        #expect(occurrences.occurrence(eventID: "weekly", startsAt: first.addingTimeInterval(week + 60)) == nil)
    }

    @Test("Without calendar access the provider returns no details and asks for nothing",
          .enabled(if: EKEventStore.authorizationStatus(for: .event) != .fullAccess))
    func noAccess() async {
        let provider = CalendarProvider()
        let now = Date()
        #expect(await provider.details(eventID: "any", startsAt: now) == nil)
        #expect(await provider.details(start: now.addingTimeInterval(-86_400), end: now, selectedCalendars: []).isEmpty)
        #expect(EKEventStore.authorizationStatus(for: .event) != .fullAccess)
    }
}

@Suite("The app reads event details on demand")
@MainActor
struct LifeLogEventDetailsTests {
    @Test("The coordinator asks the reader for this occurrence and writes nothing to the database")
    func coordinatorReadsWithoutSaving() async throws {
        let database = try await LoreDatabase.inMemory()
        let coordinator = LifeLogCoordinator()
        await coordinator.configure(database: database, engines: EngineRegistry(), vocabulary: { [] },
                                    participatingEventsOnly: { false }, audioProcessingCompleted: {})
        coordinator.useEventDetails(DemoCalendarEventDetails(copy: .english))
        let start = Calendar.current.date(bySettingHour: 9, minute: 30, second: 0, of: Date())!
        let event = CalendarEventSnapshot(id: "demo-event-1", title: "Product Standup", startsAt: start,
                                          endsAt: start.addingTimeInterval(1800), calendarTitle: "Work", participationStatus: .accepted)
        try await database.lifeLog.save(calendarEvents: [event])
        let before = try await database.lifeLog.day(start, participatingOnly: false).calendarEvents

        let details = try #require(await coordinator.eventDetails(for: event))

        #expect(details.eventID == event.id && details.startsAt == start)
        #expect(details.conferenceLink?.provider == .googleMeet)
        #expect(try await database.lifeLog.day(start, participatingOnly: false).calendarEvents == before)
    }

    @Test("The demo seed has details for every demo event, covering each provider and response")
    func demoDetails() async {
        let reader = DemoCalendarEventDetails(copy: .japanese)
        let ids = ["demo-event-1", "demo-event-2", "demo-event-3", "demo-event-weekly"]
        var all: [CalendarEventDetails] = []
        for id in ids { if let details = await reader.details(eventID: id, startsAt: Date()) { all.append(details) } }

        #expect(all.count == ids.count)
        #expect(Set(all.compactMap(\.conferenceLink?.provider)) == Set(ConferenceProvider.allCases))
        #expect(Set(all.flatMap(\.attendees).map(\.status)).isSuperset(of: [.accepted, .declined, .tentative, .pending]))
        #expect(all.flatMap(\.attendees).contains { $0.kind == .room })
        #expect(all.allSatisfy { $0.attendees.contains(where: \.isCurrentUser) })
        #expect(await reader.details(eventID: "unknown", startsAt: Date()) == nil)
    }
}
