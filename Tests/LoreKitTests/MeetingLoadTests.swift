import Foundation
import Testing

@testable import LoreKit

@Suite("会議の負荷")
struct MeetingLoadTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 14) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func event(
        _ id: String, _ start: Date, _ end: Date,
        allDay: Bool = false, status: CalendarParticipationStatus = .accepted
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: id, title: id, startsAt: start, endsAt: end, calendarTitle: "Work",
                              isAllDay: allDay, participationStatus: status)
    }

    private var workday: DateInterval { DateInterval(start: at(9), end: at(18)) }

    private func load(_ events: [CalendarEventSnapshot], participatingOnly: Bool = true, window: DateInterval? = nil) -> MeetingLoad? {
        MeetingLoad.calculate(events: events, on: at(12), workingWindow: window ?? workday,
                              participatingOnly: participatingOnly, calendar: calendar)
    }

    @Test("予定がない日、終日だけの日、辞退だけの日は何も返さない")
    func nothingWithoutMeetings() {
        #expect(load([]) == nil)
        #expect(load([event("holiday", at(0), at(23, 59), allDay: true)]) == nil)
        #expect(load([event("declined", at(10), at(11), status: .declined)]) == nil)
    }

    @Test("合計と空きの最長区間")
    func totalAndLongestFreeBlock() throws {
        let result = try #require(load([
            event("a", at(9, 30), at(10)),
            event("b", at(13), at(14)),
            event("c", at(16), at(16, 45)),
        ]))
        #expect(result.meetingCount == 3)
        #expect(result.totalDuration == 135 * 60)
        #expect(result.longestFreeBlock == DateInterval(start: at(10), end: at(13)))
        #expect(result.backToBackTransitions == 0)
        #expect(result.overlappingMeetingCount == 0)
    }

    @Test("5分未満の間で続く会議だけを連続と数え、ちょうど5分は数えない")
    func backToBackThreshold() throws {
        let result = try #require(load([
            event("a", at(10), at(11)),
            event("b", at(11), at(12)),
            event("c", at(12, 4), at(13)),
            event("d", at(13, 5), at(14)),
        ]))
        #expect(result.backToBackTransitions == 2)
    }

    @Test("重なる会議は連続に数えず、時間を二重に数えない")
    func overlapsAreNotDoubleCounted() throws {
        let result = try #require(load([
            event("a", at(10), at(12)),
            event("b", at(10, 30), at(11)),
            event("c", at(11, 30), at(12, 30)),
            event("d", at(12, 30), at(13)),
            event("e", at(15), at(16)),
        ]))
        #expect(result.meetingCount == 5)
        #expect(result.totalDuration == 4 * 3600)
        #expect(result.overlappingMeetingCount == 3)
        #expect(result.backToBackTransitions == 1)
        #expect(result.longestFreeBlock == DateInterval(start: at(13), end: at(15)))
    }

    @Test("日付をまたぐ予定は選択日に入る部分だけを数える")
    func crossingMidnight() throws {
        let evening = try #require(load([event("late", at(23), at(1, day: 15))]))
        #expect(evening.totalDuration == 3600)
        let morning = try #require(MeetingLoad.calculate(
            events: [event("late", at(23), at(1, day: 15))], on: at(12, day: 15),
            workingWindow: DateInterval(start: at(9, day: 15), end: at(18, day: 15)),
            participatingOnly: true, calendar: calendar))
        #expect(morning.totalDuration == 3600)
        #expect(morning.longestFreeBlock == DateInterval(start: at(9, day: 15), end: at(18, day: 15)))
    }

    @Test("参加フィルターが有効なら辞退・未定を除き、無効なら含める")
    func participationFilter() throws {
        let events = [
            event("accepted", at(10), at(11)),
            event("declined", at(11), at(12), status: .declined),
            event("tentative", at(14), at(15), status: .tentative),
            event("none", at(16), at(17), status: .none),
        ]
        let filtered = try #require(load(events))
        #expect(filtered.meetingCount == 2)
        #expect(filtered.totalDuration == 7200)
        #expect(filtered.backToBackTransitions == 0)
        let all = try #require(load(events, participatingOnly: false))
        #expect(all.meetingCount == 4)
        #expect(all.backToBackTransitions == 1)
    }

    @Test("作業時間帯が会議で埋まれば空きはなく、時間帯の外の会議は合計にだけ入る")
    func windowEdges() throws {
        let full = try #require(load([event("all", at(8), at(19))]))
        #expect(full.longestFreeBlock == nil)
        #expect(full.totalDuration == 11 * 3600)
        let early = try #require(load([event("early", at(7), at(8))]))
        #expect(early.longestFreeBlock == workday)
    }

    @Test("作業時間帯は予約録音が有効でその日に時間帯があればそれ、なければ9時から18時")
    func workingWindow() {
        let off = LifeLogSchedule(isEnabled: false, startMinute: 10 * 60, endMinute: 19 * 60)
        #expect(MeetingLoad.workingWindow(on: at(12), schedule: off, calendar: calendar) == workday)

        // 2026-11-14は土曜。平日だけの予約録音に時間帯はない。
        let weekdays = LifeLogSchedule(isEnabled: true, weekdays: [2, 3, 4, 5, 6], startMinute: 10 * 60, endMinute: 19 * 60)
        #expect(MeetingLoad.workingWindow(on: at(12), schedule: weekdays, calendar: calendar) == workday)
        #expect(MeetingLoad.workingWindow(on: at(12, day: 16), schedule: weekdays, calendar: calendar)
            == DateInterval(start: at(10, day: 16), end: at(19, day: 16)))
    }

    @Test("日付をまたぐ予約録音の時間帯は、その日の終わりで切る")
    func overnightScheduleIsCutAtMidnight() throws {
        let night = LifeLogSchedule(isEnabled: true, weekdays: [7], startMinute: 22 * 60, endMinute: 6 * 60)
        let window = MeetingLoad.workingWindow(on: at(12), schedule: night, calendar: calendar)
        #expect(window == DateInterval(start: at(22), end: at(6, day: 15)))
        let result = try #require(MeetingLoad.calculate(
            events: [event("late", at(23), at(23, 30))], on: at(12), workingWindow: window,
            participatingOnly: true, calendar: calendar))
        #expect(result.longestFreeBlock == DateInterval(start: at(22), end: at(23)))
    }
}
