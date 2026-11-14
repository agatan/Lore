import Foundation
import Testing

@testable import LoreKit

@Suite("ライフログtimelineと一日の流れの配置")
struct LifeLogTimelineLayoutTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func event(_ id: String, _ start: Date, _ end: Date, allDay: Bool = false) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: id, title: id, startsAt: start, endsAt: end, calendarTitle: "Work", isAllDay: allDay)
    }

    private func utterance(_ id: String, _ start: Date, seconds: TimeInterval = 10) -> LifeLogUtterance {
        LifeLogUtterance(id: id, startedAt: start, endedAt: start.addingTimeInterval(seconds), text: id, audioChunkID: nil)
    }

    @Test("予定の区間内の線だけを予定として塗り、予定を同時刻の行より先に置く")
    func railFollowsEventSpan() {
        let day = LifeLogDay(
            utterances: [utterance("a", at(9, 30)), utterance("b", at(9, 45)), utterance("c", at(10, 20))],
            calendarEvents: [event("standup", at(9, 30), at(10))]
        )
        let rows = LifeLogTimelineLayout.rows(for: day)
        #expect(rows.map(\.id) == ["e-standup", "u-a", "u-b", "u-c"])
        #expect(rows.map(\.above) == [.none, .event, .event, .plain])
        #expect(rows.map(\.below) == [.event, .event, .plain, .none])
    }

    @Test("予定の外で1時間以上空いた所だけ空き時間を持つ")
    func gapOutsideEvents() {
        let day = LifeLogDay(
            utterances: [utterance("a", at(9)), utterance("b", at(9, 59)), utterance("c", at(11, 30)),
                         utterance("d", at(13, 10)), utterance("e", at(14, 40))],
            calendarEvents: [event("review", at(13), at(15))]
        )
        let rows = LifeLogTimelineLayout.rows(for: day)
        let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        #expect(byID["u-b"]?.gapBefore == nil)
        #expect(byID["u-c"]?.above == .gap)
        #expect(byID["u-c"]?.gapBefore == TimeInterval(91 * 60))
        // 予定の中は空いていても予定の区間として扱う。
        #expect(byID["u-e"]?.above == .event)
        #expect(byID["u-e"]?.gapBefore == nil)
    }

    @Test("終日の予定は行に入れず、別に返す")
    func allDayEventsAreSeparate() {
        let day = LifeLogDay(calendarEvents: [event("holiday", at(0), at(0, day: 15), allDay: true)])
        #expect(LifeLogTimelineLayout.rows(for: day).isEmpty)
        #expect(LifeLogTimelineLayout.allDayEvents(in: day).map(\.id) == ["holiday"])
    }

    @Test("話した時間は発話の長さの合計")
    func summary() {
        let day = LifeLogDay(
            utterances: [utterance("a", at(9), seconds: 90), utterance("b", at(10), seconds: 30)],
            memos: [LifeLogMemo(id: "m", createdAt: at(11), text: "m")]
        )
        let summary = LifeLogDaySummary(day: day)
        #expect(summary.spokenDuration == 120)
        #expect(summary.utteranceCount == 2)
        #expect(summary.memoCount == 1)
        #expect(summary.dictationCount == 0)
    }

    @Test("記録が少ない日も9〜18時を見せ、範囲外の記録に合わせて広げる")
    func dayMapRange() {
        let empty = LifeLogDayMapLayout(day: LifeLogDay(), date: at(12), calendar: calendar)
        #expect((empty.startHour, empty.endHour) == (9, 18))

        let wide = LifeLogDayMapLayout(
            day: LifeLogDay(utterances: [utterance("early", at(7, 40)), utterance("late", at(21, 5))]),
            date: at(12),
            calendar: calendar
        )
        #expect((wide.startHour, wide.endHour) == (7, 22))
        #expect(wide.position(of: at(7)) == 0)
        #expect(wide.position(of: at(22)) == 1)
        #expect(wide.date(at: 0.5) == at(14, 30))
    }

    @Test("日をまたぐ予定は選択日の中だけで範囲を決める")
    func dayMapClipsOvernightEvents() {
        let layout = LifeLogDayMapLayout(
            day: LifeLogDay(calendarEvents: [event("night", at(22), at(2, day: 15))]),
            date: at(12),
            calendar: calendar
        )
        #expect((layout.startHour, layout.endHour) == (9, 24))
        #expect(layout.blocks.map(\.id) == ["night"])
    }

    @Test("重なる予定は列に分け、重ならない予定は全幅に戻す")
    func overlappingEventsShareColumns() {
        let blocks = LifeLogDayMapLayout.columns(for: [
            event("a", at(9), at(10)),
            event("b", at(9, 30), at(11)),
            event("c", at(10), at(10, 30)),
            event("d", at(12), at(13)),
        ])
        let byID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        #expect(byID["a"].map { [$0.column, $0.columnCount] } == [0, 2])
        #expect(byID["b"].map { [$0.column, $0.columnCount] } == [1, 2])
        #expect(byID["c"].map { [$0.column, $0.columnCount] } == [0, 2])
        #expect(byID["d"].map { [$0.column, $0.columnCount] } == [0, 1])
    }
}
