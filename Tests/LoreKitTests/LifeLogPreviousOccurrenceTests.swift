import Foundation
import GRDB
import Testing
@testable import LoreKit

@Suite("Last time for a repeating event")
struct LifeLogPreviousOccurrenceTests {
    private let calendar = Calendar(identifier: .gregorian)
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))! }

    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: today)!
    }

    private func event(_ id: String, title: String = "Weekly sync", start: Date, minutes: Int = 30, allDay: Bool = false) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: id, title: title, startsAt: start, endsAt: start.addingTimeInterval(TimeInterval(minutes * 60)),
                              calendarTitle: "Work", isAllDay: allDay)
    }

    private func say(_ db: LoreDatabase, _ id: String, at date: Date, eventID: String?) async throws {
        try await db.lifeLog.save(utterance: LifeLogUtterance(id: id, startedAt: date, endedAt: date.addingTimeInterval(20),
                                                              text: "said \(id)", audioChunkID: nil, calendarEventID: eventID))
    }

    private func note(eventID: String, day: String, actions: [String], questions: [String]) -> GeneratedNote {
        GeneratedNote(
            kind: .eventNotes, scope: .event(EventOccurrence(eventID: eventID, day: day)),
            rangeStart: at(-7, 10), rangeEnd: at(-7, 10, 30), backend: .onDevice, model: "m", createdAt: at(-7, 11),
            sourceUtteranceIDs: [], sourceMemoIDs: [],
            sections: [
                GeneratedNoteSection(kind: .decisions, items: [GeneratedNoteItem(text: "decided", sources: ["u-x"])]),
                GeneratedNoteSection(kind: .actionItems, items: actions.map { GeneratedNoteItem(text: $0, sources: ["u-x"]) }),
                GeneratedNoteSection(kind: .openQuestions, items: questions.map { GeneratedNoteItem(text: $0, sources: ["u-x"]) }),
            ]
        )
    }

    @Test("The latest earlier day with speech for the same identifier, jumping to its first utterance")
    func findsLatestEarlierOccurrence() async throws {
        let db = try await LoreDatabase.inMemory()
        let sync = event("series", start: at(0, 10))
        try await db.lifeLog.save(calendarEvents: [sync])
        try await say(db, "two-weeks-ago", at: at(-14, 10, 5), eventID: "series")
        try await say(db, "last-week-first", at: at(-7, 10, 2), eventID: "series")
        try await say(db, "last-week-second", at: at(-7, 10, 20), eventID: "series")
        try await say(db, "today", at: at(0, 10, 3), eventID: "series")

        let previous = try #require(try await db.lifeLog.day(today, calendar: calendar).previousOccurrences[EventOccurrence(sync, calendar: calendar)])
        #expect(previous.occurrence == EventOccurrence(eventID: "series", day: LifeLogDateKey.string(for: at(-7, 0), calendar: calendar)))
        #expect(previous.firstUtteranceID == "last-week-first")
        #expect(previous.notes == nil)
    }

    @Test("Matching uses the event identifier, not the title")
    func matchesByIdentifierNotTitle() async throws {
        let db = try await LoreDatabase.inMemory()
        let renamed = event("series", title: "Renamed sync", start: at(0, 10))
        let sameTitle = event("other", title: "Renamed sync", start: at(0, 15))
        try await db.lifeLog.save(calendarEvents: [renamed, sameTitle])
        try await say(db, "last-week", at: at(-7, 10, 5), eventID: "series")
        try await say(db, "untagged", at: at(-7, 15, 5), eventID: nil)

        let day = try await db.lifeLog.day(today, calendar: calendar)
        #expect(day.previousOccurrences[EventOccurrence(renamed, calendar: calendar)]?.firstUtteranceID == "last-week")
        #expect(day.previousOccurrences[EventOccurrence(sameTitle, calendar: calendar)] == nil)
    }

    @Test("The first occurrence, an all-day event, and an event crossing midnight find nothing")
    func firstOccurrenceFindsNothing() async throws {
        let db = try await LoreDatabase.inMemory()
        let first = event("first", start: at(0, 9))
        let allDay = event("all-day", start: at(0, 0), minutes: 24 * 60, allDay: true)
        let overnight = event("overnight", start: at(-1, 23, 30), minutes: 60)
        try await db.lifeLog.save(calendarEvents: [first, allDay, overnight])
        try await say(db, "first-now", at: at(0, 9, 5), eventID: "first")
        try await say(db, "all-day-earlier", at: at(-1, 12), eventID: "all-day")
        try await say(db, "overnight-before-midnight", at: at(-1, 23, 40), eventID: "overnight")

        let day = try await db.lifeLog.day(today, calendar: calendar)
        #expect(day.calendarEvents.map(\.id).sorted() == ["all-day", "first", "overnight"])
        #expect(day.previousOccurrences.isEmpty)
    }

    @Test("The notes of the earlier occurrence give action items, then open questions, at most three")
    func followUpsFromNotes() async throws {
        let db = try await LoreDatabase.inMemory()
        let sync = event("series", start: at(0, 10))
        try await db.lifeLog.save(calendarEvents: [sync])
        try await say(db, "last-week", at: at(-7, 10, 5), eventID: "series")
        let lastWeek = LifeLogDateKey.string(for: at(-7, 0), calendar: calendar)
        try await db.lifeLog.save(generatedNote: note(eventID: "series", day: lastWeek, actions: ["a1", "a2"], questions: ["q1", "q2"]))

        let day = try await db.lifeLog.day(today, calendar: calendar)
        let lastTime = try #require(day.lastTime(for: sync, recordingExclusions: .init(), aiSettings: .init(), aiExcludedEventIDs: []))
        #expect(lastTime.followUps.map(\.text) == ["a1", "a2", "q1"])
        #expect(lastTime.previous.occurrence.day == lastWeek)
    }

    @Test("An event that holds capture shows nothing, and an AI-excluded event shows the date only")
    func exclusions() async throws {
        let db = try await LoreDatabase.inMemory()
        let sync = event("series", start: at(0, 10))
        try await db.lifeLog.save(calendarEvents: [sync])
        try await say(db, "last-week", at: at(-7, 10, 5), eventID: "series")
        let lastWeek = LifeLogDateKey.string(for: at(-7, 0), calendar: calendar)
        try await db.lifeLog.save(generatedNote: note(eventID: "series", day: lastWeek, actions: ["a1"], questions: []))
        let day = try await db.lifeLog.day(today, calendar: calendar)

        var skipped = LifeLogRecordingExclusions()
        skipped.setSkipped(true, event: sync)
        #expect(day.lastTime(for: sync, recordingExclusions: skipped, aiSettings: .init(), aiExcludedEventIDs: []) == nil)
        #expect(day.lastTime(for: sync, recordingExclusions: .init(calendarTitles: ["Work"]), aiSettings: .init(), aiExcludedEventIDs: []) == nil)

        let excludedEvent = try #require(day.lastTime(for: sync, recordingExclusions: .init(), aiSettings: .init(), aiExcludedEventIDs: ["series"]))
        #expect(excludedEvent.followUps.isEmpty)
        var aiSettings = LifeLogAISettings()
        aiSettings.excludedCalendars = ["Work"]
        let excludedCalendar = try #require(day.lastTime(for: sync, recordingExclusions: .init(), aiSettings: aiSettings, aiExcludedEventIDs: []))
        #expect(excludedCalendar.followUps.isEmpty)
        #expect(excludedCalendar.previous.firstUtteranceID == "last-week")
    }
}

@Suite("v13-utterance-event-index migration")
struct UtteranceEventIndexMigrationTests {
    private func v12Database(at root: URL) throws -> URL {
        let url = root.appendingPathComponent("lore.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = try DatabaseQueue(path: url.path)
        try LoreDatabase.migrator.migrate(legacy, upTo: "v12-life-log-ai")
        try legacy.write { db in
            try db.execute(sql: "INSERT INTO life_log_memos (id, created_at, text) VALUES ('keep', '2026-11-01T09:00:00.000Z', 'before v13')")
        }
        return url
    }

    @Test("The migration adds the index, keeps records, and the backup holds the old schema")
    func migrates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v13-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try v12Database(at: root)
        let backups = root.appendingPathComponent("Backups")
        let database = try await LoreDatabase.open(fileURL: url, backupDirectory: backups)
        #expect(try await database.lifeLog.memo(id: "keep")?.text == "before v13")
        let migrated = try DatabaseQueue(path: url.path)
        #expect(try await migrated.read { try $0.indexes(on: "life_log_utterances").map(\.name) }.contains("life_log_utterances_event_started_at"))

        let backup = try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("pre-migration-") })
        let queue = try DatabaseQueue(path: backup.path)
        #expect(try await queue.read { try $0.indexes(on: "life_log_utterances").map(\.name) }.contains("life_log_utterances_event_started_at") == false)
    }

    @Test("A failing migration leaves the database unchanged")
    func failureLeavesDatabaseUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v13-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try v12Database(at: root)
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try await legacy.write { try $0.execute(sql: "CREATE TABLE life_log_utterances_event_started_at (conflict TEXT)") }
        }
        await #expect(throws: (any Error).self) {
            _ = try await LoreDatabase.open(fileURL: url, backupDirectory: root.appendingPathComponent("Backups"))
        }
        let queue = try DatabaseQueue(path: url.path)
        #expect(try await queue.read { try LoreDatabase.migrator.appliedIdentifiers($0).contains("v13-utterance-event-index") } == false)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT text FROM life_log_memos") } == ["before v13"])
    }
}
