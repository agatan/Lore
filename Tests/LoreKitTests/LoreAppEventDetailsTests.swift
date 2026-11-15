import Foundation
import Testing

@testable import LoreKit

@Suite("Event details from the running Lore app")
@MainActor
struct LoreAppEventDetailsTests {
    private let start = Date(timeIntervalSince1970: 1_787_792_400)

    private var request: Data {
        get throws { try JSONEncoder().encode(EventDetailsRequest(start: start, end: start.addingTimeInterval(3_600))) }
    }

    @Test("The app's reply carries every field, and the join link is rebuilt on the lore-mcp side")
    func roundTrip() throws {
        let mika = CalendarAttendee(name: "Mika Sato", email: "mika@example.com", status: .accepted, role: .chair, kind: .person)
        let room = CalendarAttendee(name: "Room 4A", email: "room-4a@resource.example.com", status: .accepted, role: .nonParticipant, kind: .room)
        let sent = [
            CalendarEventDetails(eventID: "review", startsAt: start, externalIdentifier: "review@example.com",
                                 notes: "Agenda", location: "https://example.zoom.us/j/81234567890", organizer: mika,
                                 attendees: [mika, room], isCanceled: true,
                                 googleCalendarURL: URL(string: "https://calendar.google.com/calendar/event?eid=ZGVtbw")),
            CalendarEventDetails(eventID: "lunch", startsAt: start.addingTimeInterval(1_800)),
        ]
        var asked: (Date, Date)?

        let reply = LoreAppEventDetailsServer.reply(to: try request) { from, to in
            asked = (from, to)
            return sent
        }
        let received = try LoreAppEventDetails.details(fromReply: reply)

        #expect(received == sent)
        #expect(received[0].conferenceLink?.provider == .zoom)
        #expect(asked?.0 == start && asked?.1 == start.addingTimeInterval(3_600))
    }

    @Test("Without calendar access in the app, lore-mcp gets noCalendarAccess")
    func noCalendarAccess() throws {
        let reply = LoreAppEventDetailsServer.reply(to: try request) { _, _ in nil }

        #expect(throws: EventDetailsUnavailable.noCalendarAccess) { try LoreAppEventDetails.details(fromReply: reply) }
    }

    @Test("A request or reply that does not decode is reported, not read as no events")
    func invalidMessages() {
        #expect(LoreAppEventDetailsServer.reply(to: Data("{}".utf8)) { _, _ in [] } == nil)
        #expect(throws: EventDetailsUnavailable.invalidReply) { try LoreAppEventDetails.details(fromReply: nil) }
        #expect(throws: EventDetailsUnavailable.invalidReply) { try LoreAppEventDetails.details(fromReply: Data("[]".utf8)) }
    }

    /// Evidence harness for a live `lore-mcp` with fictional data:
    /// `LORE_SERVE_FIXTURE_DATABASE=<home>/Library/Application Support/Lore/lore.sqlite LORE_SERVE_FIXTURE_SECONDS=60 swift test --filter serveFixture`
    /// seeds two fictional events into that database, then answers on the production port for that long, as Lore.app would.
    /// With `LORE_SERVE_APP_READ=1` it answers with the app's own EventKit read instead, which this process has no access for.
    @Test("Serve fixture details when asked", .enabled(if: ProcessInfo.processInfo.environment["LORE_SERVE_FIXTURE_SECONDS"] != nil))
    func serveFixture() async throws {
        let environment = ProcessInfo.processInfo.environment
        let day = Calendar.current.startOfDay(for: Date())
        let review = day.addingTimeInterval(10 * 3_600), lunch = day.addingTimeInterval(12 * 3_600)
        if let path = environment["LORE_SERVE_FIXTURE_DATABASE"] {
            let url = URL(fileURLWithPath: path)
            let database = try await LoreDatabase.open(fileURL: url, backupDirectory: url.deletingLastPathComponent().appending(path: "Backups"))
            try await database.lifeLog.save(calendarEvents: [
                CalendarEventSnapshot(id: "fixture-review", externalIdentifier: "review@example.com", title: "Launch review",
                                      startsAt: review, endsAt: review.addingTimeInterval(3_600), calendarTitle: "Work", participationStatus: .accepted),
                CalendarEventSnapshot(id: "fixture-lunch", title: "Lunch", startsAt: lunch, endsAt: lunch.addingTimeInterval(3_600),
                                      calendarTitle: "Work", participationStatus: .accepted),
            ])
        }
        let mika = CalendarAttendee(name: "Mika Sato", email: "mika@example.com", status: .accepted, role: .chair, kind: .person)
        let fixture = [
            CalendarEventDetails(eventID: "fixture-review", startsAt: review, externalIdentifier: "review@example.com",
                                 notes: "Agenda: launch checklist.", url: URL(string: "https://meet.google.com/abc-defg-hij"),
                                 organizer: mika, attendees: [mika, CalendarAttendee(name: "Ren Kato", status: .tentative, role: .optional)]),
        ]
        let appRead = environment["LORE_SERVE_APP_READ"] != nil
        let server = try #require(appRead
            ? LoreAppEventDetailsServer(settings: AppSettings(defaults: UserDefaults(suiteName: "lore-serve-\(UUID().uuidString)")!))
            : LoreAppEventDetailsServer { start, end in
                print("answered \(start.formatted(date: .omitted, time: .shortened))-\(end.formatted(date: .omitted, time: .shortened))")
                return fixture.filter { start <= $0.startsAt && $0.startsAt < end }
            })
        print("serving \(LoreAppEventDetails.portName)")
        runMainRunLoop(seconds: Double(environment["LORE_SERVE_FIXTURE_SECONDS"]!)!)
        withExtendedLifetime(server) {}
    }

    /// The port answers on the main run loop, which the test runner does not run by itself.
    private func runMainRunLoop(seconds: Double) {
        CFRunLoopRunInMode(.defaultMode, seconds, false)
    }

    @Test("With no process holding the port, lore-mcp reports that Lore is not running")
    func loreNotRunning() async {
        let reader = LoreAppEventDetails(portName: "dev.agatan.Lore.tests.\(UUID().uuidString)")

        await #expect(throws: EventDetailsUnavailable.loreNotRunning) {
            _ = try await reader.details(start: start, end: start.addingTimeInterval(60))
        }
    }
}
