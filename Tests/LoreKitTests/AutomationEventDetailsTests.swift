import Foundation
import Testing

@testable import LoreKit

/// Returns the details it was given that start inside the asked range, and remembers what it was asked.
private actor FakeEventDetails: CalendarEventDetailsRangeReading {
    private let known: [CalendarEventDetails]
    private(set) var selectedCalendars: [Set<String>] = []

    init(_ known: [CalendarEventDetails] = []) { self.known = known }

    func details(start: Date, end: Date, selectedCalendars: Set<String>) -> [CalendarEventDetails] {
        self.selectedCalendars.append(selectedCalendars)
        return known.filter { start <= $0.startsAt && $0.startsAt < end }
    }
}

@Suite("Event details in the MCP output")
@MainActor
struct AutomationEventDetailsTests {
    private let calendar: Calendar = {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 8, day: day, hour: hour, minute: minute))!
    }

    private func attendee(_ name: String?, _ email: String?, _ status: CalendarParticipationStatus,
                          _ role: CalendarAttendeeRole) -> CalendarAttendee {
        CalendarAttendee(name: name, email: email, status: status, role: role, kind: .person)
    }

    /// 8/27: a review with the full set of details, a lunch that EventKit no longer has, and an event whose
    /// details are all blank. 8/28 and 9/3: two occurrences of one weekly event that share an identifier.
    private func makeFixture(
        details: Bool = true,
        settings: AppSettings? = nil
    ) async throws -> (service: LoreAutomationService, reader: FakeEventDetails) {
        let defaults = UserDefaults(suiteName: "lore-event-details-\(UUID().uuidString)")!
        let mika = attendee("Mika Sato", "mika@example.com", .accepted, .chair)
        let all: [CalendarEventDetails] = [
            CalendarEventDetails(
                eventID: "review", startsAt: at(27, 10), externalIdentifier: "review@example.com",
                notes: "\n  Agenda: launch checklist.\nBring the numbers.  \n",
                location: "https://example.zoom.us/j/81234567890", organizer: mika,
                attendees: [mika, attendee("Ren Kato", nil, .tentative, .optional), attendee(nil, "sora@example.com", .pending, .required)]
            ),
            CalendarEventDetails(eventID: "blank", startsAt: at(27, 15), notes: " \n ", organizer: attendee(" ", nil, .accepted, .chair)),
            CalendarEventDetails(eventID: "weekly", startsAt: at(28, 9), externalIdentifier: "weekly@example.com", notes: "Week 1",
                                 url: URL(string: "https://meet.google.com/abc-defg-hij"), attendees: [mika]),
            CalendarEventDetails(eventID: "weekly", startsAt: at(28, 9).addingTimeInterval(7 * 86_400), externalIdentifier: "weekly@example.com",
                                 notes: "Week 2", attendees: [mika]),
        ]
        let reader = FakeEventDetails(details ? all : [])
        let service = LoreAutomationService(
            database: try await LoreDatabase.inMemory(),
            settings: settings ?? AppSettings(defaults: defaults),
            eventDetails: reader
        )
        try await service.database.lifeLog.save(calendarEvents: [
            CalendarEventSnapshot(id: "review", externalIdentifier: "review@example.com", title: "Launch review",
                                  startsAt: at(27, 10), endsAt: at(27, 11), calendarTitle: "Work", participationStatus: .accepted),
            CalendarEventSnapshot(id: "lunch", externalIdentifier: "lunch@example.com", title: "Lunch",
                                  startsAt: at(27, 12), endsAt: at(27, 13), calendarTitle: "Work", participationStatus: .accepted),
            CalendarEventSnapshot(id: "blank", title: "Focus time", startsAt: at(27, 15), endsAt: at(27, 16),
                                  calendarTitle: "Work", participationStatus: .accepted),
            CalendarEventSnapshot(id: "weekly", externalIdentifier: "weekly@example.com", title: "Weekly sync",
                                  startsAt: at(28, 9), endsAt: at(28, 10), calendarTitle: "Work", participationStatus: .accepted),
            CalendarEventSnapshot(id: "weekly", externalIdentifier: "weekly@example.com", title: "Weekly sync",
                                  startsAt: at(28, 9).addingTimeInterval(7 * 86_400), endsAt: at(28, 10).addingTimeInterval(7 * 86_400),
                                  calendarTitle: "Work", participationStatus: .accepted),
        ])
        return (service, reader)
    }

    private func keys(of entry: LifeLogEntry) throws -> Set<String> { try keys(ofJSON: LifeLogJSON.encode(entry)) }

    private func keys(ofJSON json: String) throws -> Set<String> {
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return Set(try #require(object).keys)
    }

    private func events(_ service: LoreAutomationService, day: Int) async throws -> [String: LifeLogEntry] {
        let entries = try await service.range(from: at(day, 0), calendar: calendar).filter { $0.kind == .event }
        return Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    @Test("A range event carries the identifier, join link, description, organizer, and attendees")
    func rangeEventHasDetails() async throws {
        let (service, _) = try await makeFixture()
        let review = try #require(try await events(service, day: 27)["review"])

        #expect(review.externalIdentifier == "review@example.com")
        #expect(review.conferenceURL == "https://example.zoom.us/j/81234567890")
        #expect(review.description == "Agenda: launch checklist.\nBring the numbers.")
        #expect(review.organizer == .init(name: "Mika Sato", email: "mika@example.com"))
        #expect(review.attendees == [
            .init(name: "Mika Sato", email: "mika@example.com", response: "accepted", role: "chair"),
            .init(name: "Ren Kato", email: nil, response: "tentative", role: "optional"),
            .init(name: nil, email: "sora@example.com", response: "pending", role: "required"),
        ])
        let json = try LifeLogJSON.encode(review)
        #expect(json.contains("\"nonParticipant\"") == false)
        #expect(json.contains("\"response\" : \"accepted\""))
    }

    @Test("A field that is unknown is absent from the JSON, never an empty string")
    func unknownFieldsAreAbsent() async throws {
        let (service, _) = try await makeFixture()
        let day = try await events(service, day: 27)
        let base: Set<String> = ["id", "kind", "day", "start", "end", "text", "title", "calendar", "allDay"]

        // EventKit no longer has the lunch: the snapshot fields and its saved identifier only.
        #expect(try keys(of: #require(day["lunch"])) == base.union(["externalIdentifier"]))
        // Blank description, an organizer without name or email, and no attendees are all left out.
        #expect(try keys(of: #require(day["blank"])) == base)
        #expect(try keys(of: #require(day["review"])) == base.union(["externalIdentifier", "conferenceURL", "description", "organizer", "attendees"]))
        let attendees = try #require(day["review"]?.attendees)
        let attendeeKeys = try attendees.map { try keys(ofJSON: LifeLogJSON.encode($0)) }
        #expect(attendeeKeys == [["name", "email", "response", "role"], ["name", "response", "role"], ["email", "response", "role"]].map(Set.init))
    }

    @Test("Each occurrence of a repeating event gets its own details")
    func occurrencesAreMatchedByStart() async throws {
        let (service, _) = try await makeFixture()
        let first = try #require(try await events(service, day: 28)["weekly"])
        let nextWeek = try await service.range(from: at(28, 0).addingTimeInterval(7 * 86_400), calendar: calendar).first { $0.kind == .event }

        #expect(first.description == "Week 1")
        #expect(first.conferenceURL == "https://meet.google.com/abc-defg-hij")
        #expect(nextWeek?.description == "Week 2")
        #expect(nextWeek?.conferenceURL == nil)
    }

    @Test("Without details the range keeps its snapshot fields and asks the calendars selected in Settings")
    func snapshotFieldsAndSelectedCalendars() async throws {
        let defaults = UserDefaults(suiteName: "lore-event-details-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        settings.lifeLogCalendarTitles = ["Work"]
        let (service, reader) = try await makeFixture(details: false, settings: settings)

        let review = try #require(try await events(service, day: 27)["review"])

        #expect(review.title == "Launch review")
        #expect(review.externalIdentifier == "review@example.com")
        #expect(review.description == nil && review.attendees == nil && review.organizer == nil && review.conferenceURL == nil)
        #expect(await reader.selectedCalendars == [["Work"]])
    }

    @Test("The range does not read the calendar for a selection without events")
    func noCalendarReadWithoutEvents() async throws {
        let (service, reader) = try await makeFixture()

        let memos = try await service.range(from: at(27, 0), options: .init(includesCalendarEvents: false), calendar: calendar)

        #expect(memos.allSatisfy { $0.kind != .event })
        #expect(await reader.selectedCalendars.isEmpty)
    }

    @Test("The day export is byte-identical without event-details, even when details exist")
    func exportIsUnchangedByDefault() async throws {
        let (withDetails, reader) = try await makeFixture()
        let (withoutDetails, _) = try await makeFixture(details: false)

        let plain = try await withoutDetails.exportDay(at(27, 0), options: .init(), calendar: calendar)
        let exported = try await withDetails.exportDay(at(27, 0), options: .init(), calendar: calendar)

        #expect(exported == plain)
        #expect(exported.contains("- **10:00–11:00 予定** Launch review（Work）\n"))
        #expect(!exported.contains("参加者") && !exported.contains("説明"))
        #expect(await reader.selectedCalendars.isEmpty)
    }

    @Test("event-details adds the description and attendees under each event and nothing for an event without them")
    func exportWithEventDetails() async throws {
        let (service, _) = try await makeFixture()

        let exported = try await service.exportDay(at(27, 0), options: .init(includesEventDetails: true), calendar: calendar)

        #expect(exported == """
        # 2026年8月27日のライフログ

        ## タイムライン
        - **10:00–11:00 予定** Launch review（Work）
          - 説明:
            Agenda: launch checklist.
            Bring the numbers.
          - 参加者:
            - Mika Sato <mika@example.com>（accepted, chair）
            - Ren Kato（tentative, optional）
            - <sora@example.com>（pending, required）
        - **12:00–13:00 予定** Lunch（Work）
        - **15:00–16:00 予定** Focus time（Work）

        """)
    }

    @Test("event-details needs calendar, and an empty selection is still an error")
    func exportValidation() async throws {
        let (service, _) = try await makeFixture()

        await #expect(throws: AutomationError.eventDetailsNeedCalendar) {
            _ = try await service.exportDay(at(27, 0), options: .init(includesCalendarEvents: false, includesEventDetails: true), calendar: calendar)
        }
        await #expect(throws: AutomationError.emptyExportSelection) {
            _ = try await service.exportDay(at(27, 0), options: .init(
                includesCalendarEvents: false, includesUtterances: false, includesDictations: false, includesMemos: false
            ), calendar: calendar)
        }
    }

    @Test("include names: event-details and ai-notes are for the day export only, and an unknown name is reported")
    func includeNames() {
        typealias Options = LifeLogTextExporter.Options

        #expect(Options.unknownIncludeNames(in: ["calendar", "speech", "voice-input", "memos"], isExport: false).isEmpty)
        #expect(Options.unknownIncludeNames(in: ["calendar", "event-details", "ai-notes"], isExport: true).isEmpty)
        #expect(Options.unknownIncludeNames(in: ["calendar", "event-details"], isExport: false) == ["event-details"])
        #expect(Options.unknownIncludeNames(in: ["event-detail", "attendees", "calendar"], isExport: true) == ["attendees", "event-detail"])

        let options = Options(includeNames: ["calendar", "event-details"])
        #expect(options.includesCalendarEvents && options.includesEventDetails)
        #expect(!options.includesUtterances && !options.includesAINotes)
        #expect(Options().includesEventDetails == false)
    }

    /// `LORE_PRINT_AUTOMATION_FIXTURE=1 swift test --filter printFixtureOutput` prints what the MCP tools return for the fixture.
    @Test("Print the fixture output when asked", .enabled(if: ProcessInfo.processInfo.environment["LORE_PRINT_AUTOMATION_FIXTURE"] != nil))
    func printFixtureOutput() async throws {
        let (service, _) = try await makeFixture()
        let entries = try await service.range(from: at(27, 0), calendar: calendar).filter { $0.kind == .event }
        print("--- life_log_range from=2026-08-27 (event entries) ---")
        print(try LifeLogJSON.encode(entries))
        print("--- life_log_export date=2026-08-27 include=[calendar,event-details] ---")
        print(try await service.exportDay(at(27, 0), options: .init(includeNames: ["calendar", "event-details"]), calendar: calendar))
    }
}
