import Foundation
import GRDB
import Testing
@testable import LoreKit

@Suite("Calendar snapshots keep every occurrence")
struct EventSnapshotOccurrenceTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.startOfDay(for: Date()) }
    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: today)!
    }
    private func weekly(_ dayOffset: Int, hour: Int = 10, title: String = "Weekly 1:1") -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: "weekly", title: title, startsAt: at(dayOffset, hour), endsAt: at(dayOffset, hour, 30), calendarTitle: "Work")
    }
    private func dayInterval(_ dayOffset: Int) -> DateInterval { calendar.dateInterval(of: .day, for: at(dayOffset, 12))! }

    @Test("Each occurrence of a repeating event stays on its own day")
    func occurrencesStayOnTheirDays() async throws {
        let db = try await LoreDatabase.inMemory()
        try await db.lifeLog.replaceCalendarEvents([weekly(-7)], in: dayInterval(-7))
        try await db.lifeLog.replaceCalendarEvents([weekly(0, title: "Renamed 1:1")], in: dayInterval(0))

        #expect(try await db.lifeLog.day(at(-7, 12)).calendarEvents.map(\.title) == ["Weekly 1:1"])
        #expect(try await db.lifeLog.day(at(0, 12)).calendarEvents.map(\.title) == ["Renamed 1:1"])
        #expect(try await db.lifeLog.activity(start: dayInterval(-7).start, end: dayInterval(0).end)
            .values.map(\.calendarEventCount).reduce(0, +) == 2)
    }

    @Test("Reading a day again removes its deleted and moved events and keeps other days")
    func replaceRemovesDeletedAndMoved() async throws {
        let db = try await LoreDatabase.inMemory()
        let lunch = CalendarEventSnapshot(id: "lunch", title: "Lunch", startsAt: at(0, 12), endsAt: at(0, 13), calendarTitle: "Work")
        try await db.lifeLog.replaceCalendarEvents([weekly(-7)], in: dayInterval(-7))
        try await db.lifeLog.replaceCalendarEvents([weekly(0), lunch], in: dayInterval(0))

        try await db.lifeLog.replaceCalendarEvents([weekly(0, hour: 15)], in: dayInterval(0))

        let todayEvents = try await db.lifeLog.day(at(0, 12)).calendarEvents
        #expect(todayEvents.map(\.id) == ["weekly"])
        #expect(todayEvents.map(\.startsAt) == [at(0, 15)])
        #expect(try await db.lifeLog.day(at(-7, 12)).calendarEvents.map(\.startsAt) == [at(-7, 10)])
    }

    @Test("A note is checked against its own occurrence: moved or deleted marks it, another day's occurrence does not")
    func staleCheckUsesOwnOccurrence() async throws {
        let db = try await LoreDatabase.inMemory()
        try await db.lifeLog.replaceCalendarEvents([weekly(-7)], in: dayInterval(-7))
        try await db.lifeLog.replaceCalendarEvents([weekly(0)], in: dayInterval(0))
        let scope = GeneratedNoteScope.event(EventOccurrence(weekly(-7)))
        try await db.lifeLog.save(generatedNote: GeneratedNote(
            kind: .eventNotes, scope: scope, rangeStart: at(-7, 10), rangeEnd: at(-7, 10, 30), backend: .onDevice, model: "m",
            createdAt: at(-7, 11), sourceUtteranceIDs: [], sourceMemoIDs: [], sections: []
        ))
        #expect(try await db.lifeLog.generatedNote(kind: .eventNotes, scope: scope)?.staleReasons.isEmpty == true)

        try await db.lifeLog.replaceCalendarEvents([weekly(-7, hour: 11)], in: dayInterval(-7))
        #expect(try await db.lifeLog.generatedNote(kind: .eventNotes, scope: scope)?.staleReasons == [.eventChanged])

        try await db.lifeLog.replaceCalendarEvents([], in: dayInterval(-7))
        #expect(try await db.lifeLog.generatedNote(kind: .eventNotes, scope: scope)?.staleReasons == [.eventChanged])
    }
}

@Suite("v14-event-snapshot-per-occurrence migration")
struct EventSnapshotOccurrenceMigrationTests {
    private let calendar = Calendar.current
    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: calendar.startOfDay(for: Date()))!
    }
    private func encode(_ date: Date) -> String { PersistenceCoding.encode(date: date) }
    private func day(_ date: Date) -> String { LifeLogDateKey.string(for: date) }

    /// A v13 database where the weekly event's only row is today's, last week's occurrence has a note,
    /// and today's occurrence has a note made before the event moved later the same day.
    private func v13Database(at root: URL) throws -> URL {
        let url = root.appendingPathComponent("lore.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = try DatabaseQueue(path: url.path)
        try LoreDatabase.migrator.migrate(legacy, upTo: "v13-utterance-event-index")
        try legacy.write { db in
            try db.execute(sql: "UPDATE sync_control SET enabled = 1 WHERE id = 1")
            try db.execute(sql: "INSERT INTO calendar_event_snapshots VALUES ('weekly', NULL, 'Weekly 1:1', ?, ?, 'Work', 0, 'none')",
                           arguments: [encode(at(0, 11)), encode(at(0, 11, 30))])
            try db.execute(sql: "INSERT INTO life_log_utterances (id, started_at, ended_at, text, audio_chunk_id, calendar_event_id) VALUES ('u1', ?, ?, 'quarterly goals', NULL, 'weekly')",
                           arguments: [encode(at(-7, 10, 5)), encode(at(-7, 10, 6))])
            for (id, dayOffset, hour) in [("last-week", -7, 10), ("today", 0, 10)] {
                try db.execute(sql: """
                    INSERT INTO generated_notes (id, kind, scope_key, scope_day, event_id, range_start, range_end, provider, model,
                      created_at, source_utterance_ids, source_memo_ids, content)
                    VALUES (?, 'event_notes', ?, ?, 'weekly', ?, ?, 'onDevice', 'm', ?, '[]', '[]', '[]')
                    """, arguments: [id, "event:weekly@\(day(at(dayOffset, 0)))", day(at(dayOffset, 0)),
                                     encode(at(dayOffset, hour)), encode(at(dayOffset, hour, 30)), encode(at(dayOffset, hour, 31))])
            }
            try db.execute(sql: "DELETE FROM sync_outbox")
        }
        return url
    }

    @Test("The migration restores noted occurrences, keeps utterances, search, and sync triggers, and backs up first")
    func migrates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v14-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try v13Database(at: root)
        let backups = root.appendingPathComponent("Backups")
        let database = try await LoreDatabase.open(fileURL: url, backupDirectory: backups)

        #expect(try await database.lifeLog.day(at(-7, 12)).calendarEvents.map(\.startsAt) == [at(-7, 10)])
        #expect(try await database.lifeLog.day(at(0, 12)).calendarEvents.map(\.startsAt) == [at(0, 11)])
        let lastWeek = try #require(try await database.lifeLog.generatedNote(kind: .eventNotes, scope: .event(EventOccurrence(eventID: "weekly", day: day(at(-7, 0))))))
        #expect(lastWeek.staleReasons.isEmpty)
        let todayNote = try #require(try await database.lifeLog.generatedNote(kind: .eventNotes, scope: .event(EventOccurrence(eventID: "weekly", day: day(at(0, 0))))))
        #expect(todayNote.staleReasons == [.eventChanged])

        #expect(try await database.lifeLog.utterance(id: "u1")?.calendarEventID == "weekly")
        #expect(try await database.lifeLog.search("quarterly").map(\.text) == ["quarterly goals"])
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "u2", startedAt: at(0, 11, 5), endedAt: at(0, 11, 6), text: "new", audioChunkID: nil, calendarEventID: "weekly"))
        let queue = try DatabaseQueue(path: url.path)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT record_id FROM sync_outbox WHERE entity = 'utterance'") } == ["u2"])
        #expect(try await queue.read { try $0.indexes(on: "life_log_utterances").map(\.name) }.contains("life_log_utterances_event_started_at"))

        let backup = try #require(try FileManager.default.contentsOfDirectory(at: backups, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("pre-migration-") })
        let old = try DatabaseQueue(path: backup.path)
        #expect(try await old.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM calendar_event_snapshots") } == 1)
    }

    @Test("A failing migration leaves the database unchanged")
    func failureLeavesDatabaseUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v14-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try v13Database(at: root)
        do {
            let legacy = try DatabaseQueue(path: url.path)
            try await legacy.write { try $0.execute(sql: "CREATE TABLE life_log_utterances_new (conflict TEXT)") }
        }
        await #expect(throws: (any Error).self) {
            _ = try await LoreDatabase.open(fileURL: url, backupDirectory: root.appendingPathComponent("Backups"))
        }
        let queue = try DatabaseQueue(path: url.path)
        #expect(try await queue.read { try LoreDatabase.migrator.appliedIdentifiers($0).contains("v14-event-snapshot-per-occurrence") } == false)
        #expect(try await queue.read { try Int.fetchOne($0, sql: "SELECT count(*) FROM calendar_event_snapshots") } == 1)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT id FROM life_log_utterances") } == ["u1"])
    }
}
