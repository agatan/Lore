import Foundation
import Testing
@testable import LoreKit

@Suite("Two occurrences of one series on one day")
struct OvernightOccurrenceTests {
    private let calendar = Calendar.current
    private var today: Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 16))! }

    private func at(_ dayOffset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(byAdding: DateComponents(day: dayOffset, hour: hour, minute: minute), to: today)!
    }

    private func key(_ dayOffset: Int) -> String { LifeLogDateKey.string(for: at(dayOffset, 0), calendar: calendar) }

    private func night(_ dayOffset: Int, title: String) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: "nightly", title: title, startsAt: at(dayOffset, 23), endsAt: at(dayOffset + 1, 7), calendarTitle: "Work")
    }

    private func say(_ db: LoreDatabase, _ id: String, at date: Date) async throws {
        try await db.lifeLog.save(utterance: LifeLogUtterance(id: id, startedAt: date, endedAt: date.addingTimeInterval(20),
                                                              text: "said \(id)", audioChunkID: nil, calendarEventID: "nightly"))
    }

    @Test("A nightly event keeps each occurrence apart in rows, blocks, notes, and Last time")
    func occurrencesStayApart() async throws {
        let db = try await LoreDatabase.inMemory()
        let lastNight = night(-1, title: "Night (Sun)")
        let tonight = night(0, title: "Night (Mon)")
        try await db.lifeLog.save(calendarEvents: [lastNight, tonight])
        try await say(db, "two-nights-ago", at: at(-2, 23, 10))
        try await say(db, "last-night", at: at(-1, 23, 10))
        try await db.lifeLog.save(generatedNote: GeneratedNote(
            kind: .eventNotes, scope: .event(EventOccurrence(eventID: "nightly", day: key(0))),
            rangeStart: tonight.startsAt, rangeEnd: tonight.endsAt, backend: .onDevice, model: "m", createdAt: at(1, 8),
            sourceUtteranceIDs: [], sourceMemoIDs: [],
            sections: [GeneratedNoteSection(kind: .decisions, items: [GeneratedNoteItem(text: "decided", sources: ["u-x"])])]
        ))

        let day = try await db.lifeLog.day(today, calendar: calendar)
        #expect(day.calendarEvents.map(\.title) == ["Night (Sun)", "Night (Mon)"])

        let eventRowIDs = LifeLogTimelineLayout.rows(for: day).filter {
            if case .event = $0.kind { true } else { false }
        }.map(\.id)
        #expect(eventRowIDs.count == 2)
        #expect(Set(eventRowIDs).count == 2)
        let blockIDs = LifeLogDayMapLayout(day: day, date: today, calendar: calendar).blocks.map(\.id)
        #expect(blockIDs.count == 2)
        #expect(Set(blockIDs).count == 2)

        let export = LifeLogTextExporter.render(date: today, day: day, options: .init(includesAINotes: true), calendar: calendar)
        #expect(export.contains("### Night (Mon)（"))
        #expect(!export.contains("### Night (Sun)（"))

        let none = LifeLogRecordingExclusions()
        #expect(day.lastTime(for: lastNight, recordingExclusions: none, aiSettings: .init(), aiExcludedEventIDs: [])?.previous.firstUtteranceID == "two-nights-ago")
        #expect(day.lastTime(for: tonight, recordingExclusions: none, aiSettings: .init(), aiExcludedEventIDs: [])?.previous.firstUtteranceID == "last-night")
    }
}
