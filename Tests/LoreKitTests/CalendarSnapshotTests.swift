import Foundation
import GRDB
import Testing
@testable import LoreKit

@Suite("Calendar event snapshots")
struct CalendarSnapshotTests {
    private let day = Calendar.current.dateInterval(of: .day, for: Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 16))!)!

    private func event(_ id: String, hour: Double, dayOffset: Double = 0) -> CalendarEventSnapshot {
        let start = day.start.addingTimeInterval(dayOffset * 86_400 + hour * 3600)
        return CalendarEventSnapshot(id: id, title: "Event \(id)", startsAt: start, endsAt: start.addingTimeInterval(1800), calendarTitle: "Work")
    }

    @Test("An upcoming event moved or deleted from the fetched day leaves it")
    func upcomingEventLeavesItsOldDay() async throws {
        let database = try await LoreDatabase.inMemory()
        let moved = event("moved", hour: 15)
        let deleted = event("deleted", hour: 16)
        let kept = event("kept", hour: 17)
        try await database.lifeLog.save(calendarEvents: [moved, deleted, kept], replacingUnendedIn: day, now: day.start.addingTimeInterval(9 * 3600))

        let tomorrow = event("moved", hour: 15, dayOffset: 1)
        try await database.lifeLog.save(calendarEvents: [tomorrow], replacingUnendedIn: day.applying(days: 1), now: day.start.addingTimeInterval(10 * 3600))
        try await database.lifeLog.save(calendarEvents: [kept], replacingUnendedIn: day, now: day.start.addingTimeInterval(10 * 3600))

        #expect(try await database.lifeLog.day(day.start).calendarEvents.map(\.id) == ["kept"])
        #expect(try await database.lifeLog.day(tomorrow.startsAt).calendarEvents.map(\.id) == ["moved"])
    }

    @Test("An event that ended stays when the calendar no longer returns it")
    func endedEventStays() async throws {
        let database = try await LoreDatabase.inMemory()
        let morning = event("morning", hour: 9)
        try await database.lifeLog.save(calendarEvents: [morning], replacingUnendedIn: day, now: day.start.addingTimeInterval(8 * 3600))
        try await database.lifeLog.save(calendarEvents: [], replacingUnendedIn: day, now: day.start.addingTimeInterval(12 * 3600))
        try await database.lifeLog.save(calendarEvents: [], replacingUnendedIn: day, now: day.end.addingTimeInterval(3600))

        #expect(try await database.lifeLog.day(day.start).calendarEvents == [morning])
    }

    @Test("Two occurrences of a series on one day keep their own timeline item, map block, note title, and Last time")
    func twoOccurrencesOnOneDay() async throws {
        let database = try await LoreDatabase.inMemory()
        func nightly(_ dayOffset: Double) -> CalendarEventSnapshot {
            let start = day.start.addingTimeInterval(dayOffset * 86_400 + 23 * 3600)
            return CalendarEventSnapshot(id: "nightly", title: "Night shift", startsAt: start, endsAt: start.addingTimeInterval(8 * 3600), calendarTitle: "Work")
        }
        let (lastNight, tonight) = (nightly(-1), nightly(0))
        try await database.lifeLog.save(calendarEvents: [nightly(-2), lastNight, tonight])
        for (id, event) in [("two-nights-ago", nightly(-2)), ("last-night", lastNight)] {
            let spokenAt = event.startsAt.addingTimeInterval(1800)
            try await database.lifeLog.save(utterance: LifeLogUtterance(id: id, startedAt: spokenAt, endedAt: spokenAt.addingTimeInterval(20),
                                                                        text: id, audioChunkID: nil, calendarEventID: "nightly"))
        }
        try await database.lifeLog.save(generatedNote: GeneratedNote(
            kind: .eventNotes, scope: .event(EventOccurrence(tonight)), rangeStart: tonight.startsAt, rangeEnd: tonight.endsAt,
            backend: .onDevice, model: "m", createdAt: tonight.endsAt, sourceUtteranceIDs: [], sourceMemoIDs: [], sections: []))

        let loaded = try await database.lifeLog.day(day.start)
        #expect(loaded.calendarEvents == [lastNight, tonight])
        let eventRows = LifeLogTimelineLayout.rows(for: loaded).filter { if case .event = $0.kind { true } else { false } }
        #expect(Set(eventRows.map(\.id)).count == 2)
        #expect(Set(LifeLogDayMapLayout(day: loaded, date: day.start).blocks.map(\.id)).count == 2)
        #expect(loaded.event(of: try #require(loaded.generatedNotes.first)) == tonight)
        func lastTimeDay(_ event: CalendarEventSnapshot) -> String? {
            loaded.lastTime(for: event, recordingExclusions: .init(), aiSettings: .init(), aiExcludedEventIDs: [])?.previous.occurrence.day
        }
        #expect(lastTimeDay(lastNight) == EventOccurrence(nightly(-2)).day)
        #expect(lastTimeDay(tonight) == EventOccurrence(lastNight).day)
    }

    @Test("An occurrence saved again after a time zone change replaces its row under the old local day")
    func timeZoneChangeKeepsOneRow() async throws {
        let database = try await LoreDatabase.inMemory()
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        var losAngeles = Calendar(identifier: .gregorian)
        losAngeles.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let start = try PersistenceCoding.decodeDate("2026-11-08T23:00:00.000Z")
        let standup = CalendarEventSnapshot(id: "standup", title: "Standup", startsAt: start, endsAt: start.addingTimeInterval(1800), calendarTitle: "Work")
        try await database.lifeLog.save(calendarEvents: [standup], calendar: tokyo)
        try await database.lifeLog.save(calendarEvents: [standup], calendar: losAngeles)

        #expect(try await database.lifeLog.day(start, calendar: losAngeles).calendarEvents == [standup])
        #expect(try await database.queue.read { try String.fetchAll($0, sql: "SELECT start_day FROM calendar_event_snapshots") } == ["2026-11-08"])
    }
}

@Suite("v14-event-occurrence-snapshots migration")
struct EventOccurrenceSnapshotMigrationTests {
    private func legacyDatabase(at root: URL, startsAt: String = "2026-11-09T01:00:00.000Z") async throws -> URL {
        let url = root.appendingPathComponent("lore.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let legacy = try DatabaseQueue(path: url.path)
        try LoreDatabase.migrator.migrate(legacy, upTo: "v13-utterance-event-index")
        try await legacy.write { db in
            try db.execute(sql: """
                INSERT INTO calendar_event_snapshots (id, external_identifier, title, starts_at, ends_at, calendar_title, is_all_day, participation_status)
                  VALUES ('series', 'ext', 'Weekly sync', ?, '2026-11-09T01:30:00.000Z', 'Work', 0, 'accepted');
                INSERT INTO life_log_utterances (id, started_at, ended_at, text, audio_chunk_id, calendar_event_id)
                  VALUES ('spoken', '2026-11-09T01:05:00.000Z', '2026-11-09T01:05:20.000Z', 'before v14 utterance', NULL, 'series');
                """, arguments: [startsAt])
        }
        try await LifeLogStore(queue: legacy).save(generatedNote: try earlierNote())
        return url
    }

    private func earlierNote() throws -> GeneratedNote {
        let start = try PersistenceCoding.decodeDate("2026-11-02T01:00:00.000Z")
        return GeneratedNote(kind: .eventNotes, scope: .event(EventOccurrence(eventID: "series", day: LifeLogDateKey.string(for: start))),
                             rangeStart: start, rangeEnd: start.addingTimeInterval(1800), backend: .onDevice, model: "m", createdAt: start,
                             sourceUtteranceIDs: [], sourceMemoIDs: [], sections: [])
    }

    @Test("Existing snapshots and utterances survive, and occurrences of one series get their own rows")
    func migrates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v14-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await LoreDatabase.open(fileURL: try await legacyDatabase(at: root), backupDirectory: root.appendingPathComponent("Backups"))

        let migratedDay = try PersistenceCoding.decodeDate("2026-11-09T01:00:00.000Z")
        let migrated = try #require(try await database.lifeLog.day(migratedDay).calendarEvents.first)
        #expect(migrated.title == "Weekly sync")
        #expect(migrated.participationStatus == .accepted)
        #expect(try await database.lifeLog.search("before v14").map(\.id) == ["utterance-spoken"])
        #expect(try await database.lifeLog.utterance(id: "spoken")?.calendarEventID == "series")

        var nextWeek = migrated
        nextWeek.startsAt = migrated.startsAt.addingTimeInterval(7 * 86_400)
        nextWeek.endsAt = migrated.endsAt.addingTimeInterval(7 * 86_400)
        try await database.lifeLog.save(calendarEvents: [nextWeek])
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "after", startedAt: nextWeek.startsAt, endedAt: nextWeek.startsAt.addingTimeInterval(5),
                                                                    text: "after v14 utterance", audioChunkID: nil, calendarEventID: "series"))
        #expect(try await database.lifeLog.day(migratedDay).calendarEvents == [migrated])
        #expect(try await database.lifeLog.day(nextWeek.startsAt).calendarEvents == [nextWeek])
        #expect(try await database.lifeLog.search("after v14").map(\.id) == ["utterance-after"])
        #expect(try await database.queue.read { try Row.fetchAll($0, sql: "PRAGMA foreign_key_check").count } == 0)
    }

    @Test("A note of an occurrence the series row no longer held keeps its event title and is not stale")
    func backfillsNotedOccurrences() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v14-notes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await LoreDatabase.open(fileURL: try await legacyDatabase(at: root), backupDirectory: root.appendingPathComponent("Backups"))

        let earlier = try earlierNote()
        let note = try #require(try await database.lifeLog.generatedNote(kind: .eventNotes, scope: earlier.scope))
        #expect(note.staleReasons.isEmpty)
        let earlierDay = try await database.lifeLog.day(earlier.rangeStart)
        let event = try #require(earlierDay.event(of: note))
        #expect(event.title == "Weekly sync")
        #expect(event.startsAt == earlier.rangeStart)
        #expect(event.endsAt == earlier.rangeEnd)
        #expect(event.calendarTitle == "Work")
        #expect(event.participationStatus == .accepted)
    }

    @Test("A note made in another time zone does not add a second row for the occurrence the series row holds")
    func backfillSkipsHeldOccurrence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v14-zone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await legacyDatabase(at: root)
        let start = try PersistenceCoding.decodeDate("2026-11-09T01:00:00.000Z")
        let otherZoneDay = LifeLogDateKey.string(for: start.addingTimeInterval(-86_400))
        try await LifeLogStore(queue: try DatabaseQueue(path: url.path)).save(generatedNote: GeneratedNote(
            kind: .eventNotes, scope: .event(EventOccurrence(eventID: "series", day: otherZoneDay)),
            rangeStart: start, rangeEnd: start.addingTimeInterval(1800), backend: .onDevice, model: "m", createdAt: start,
            sourceUtteranceIDs: [], sourceMemoIDs: [], sections: []))
        let database = try await LoreDatabase.open(fileURL: url, backupDirectory: root.appendingPathComponent("Backups"))

        #expect(try await database.lifeLog.day(start).calendarEvents.count == 1)
    }

    @Test("Utterance changes still reach the sync outbox after the table is recreated")
    func keepsSyncTriggers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v14-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let database = try await LoreDatabase.open(fileURL: try await legacyDatabase(at: root), backupDirectory: root.appendingPathComponent("Backups"))
        try await database.queue.write { try $0.execute(sql: "UPDATE sync_control SET enabled = 1") }
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "synced", startedAt: Date(), endedAt: Date(), text: "x", audioChunkID: nil))
        try await database.queue.write { try $0.execute(sql: "DELETE FROM life_log_utterances WHERE id = 'spoken'") }
        let outbox = try await database.queue.read { try String.fetchAll($0, sql: "SELECT record_id FROM sync_outbox WHERE entity = 'utterance' ORDER BY record_id") }
        #expect(outbox == ["spoken", "synced"])
    }

    @Test("A failing migration leaves the database unchanged")
    func failureLeavesDatabaseUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("lore-v14-fail-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try await legacyDatabase(at: root, startsAt: "not a date")
        await #expect(throws: (any Error).self) {
            _ = try await LoreDatabase.open(fileURL: url, backupDirectory: root.appendingPathComponent("Backups"))
        }
        let queue = try DatabaseQueue(path: url.path)
        #expect(try await queue.read { try LoreDatabase.migrator.appliedIdentifiers($0).contains("v14-event-occurrence-snapshots") } == false)
        #expect(try await queue.read { try $0.columns(in: "calendar_event_snapshots").map(\.name) }.contains("start_day") == false)
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT title FROM calendar_event_snapshots") } == ["Weekly sync"])
        #expect(try await queue.read { try String.fetchAll($0, sql: "SELECT text FROM life_log_utterances") } == ["before v14 utterance"])
    }
}

private extension DateInterval {
    func applying(days: Int) -> DateInterval {
        Calendar.current.dateInterval(of: .day, for: start.addingTimeInterval(TimeInterval(days) * 86_400 + 3600))!
    }
}
