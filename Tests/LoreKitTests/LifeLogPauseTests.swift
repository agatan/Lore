import Foundation
import Testing
@testable import LoreKit

@Suite("ライフログの一時停止の判断")
struct LifeLogPauseControllerTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 16) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    /// 平日9:00〜18:00。2026-11-16は月曜。
    private let schedule = LifeLogSchedule(isEnabled: true)
    private let noSchedule = LifeLogSchedule(isEnabled: false)

    private func scheduledRecording(at now: Date) -> LifeLogCaptureController {
        var controller = LifeLogCaptureController()
        #expect(controller.evaluate(schedule: schedule, now: now, hasCaptureIntent: false, calendar: calendar) == .start)
        return controller
    }

    @Test("一時停止は再開時刻まで何もせず、再開時刻で再開する")
    func pauseResumesAtExpiry() {
        var controller = LifeLogCaptureController()
        controller.userChangedCapture(enabled: true, schedule: noSchedule, now: date(10), calendar: calendar)
        controller.pause(until: date(10, 30))
        #expect(controller.pause == LifeLogPause(resumesAt: date(10, 30), scheduleOwnedCapture: false))
        #expect(controller.evaluate(schedule: noSchedule, now: date(10, 29), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: noSchedule, now: date(10, 30), hasCaptureIntent: true, calendar: calendar) == .resume)
        #expect(controller.pause == nil)
        #expect(controller.evaluate(schedule: noSchedule, now: date(10, 31), hasCaptureIntent: true, calendar: calendar) == .none)
    }

    @Test("スリープ中に再開時刻を過ぎていたら、次の評価で再開する")
    func expiryDuringSleepResumesOnNextEvaluation() {
        var controller = LifeLogCaptureController()
        controller.userChangedCapture(enabled: true, schedule: noSchedule, now: date(10), calendar: calendar)
        controller.pause(until: date(10, 15))
        #expect(controller.evaluate(schedule: noSchedule, now: date(14), hasCaptureIntent: true, calendar: calendar) == .resume)
    }

    @Test("早めに再開すると一時停止が消え、自動記録の所有は変わらない")
    func resumeEarlyKeepsOwner() {
        var controller = scheduledRecording(at: date(9))
        controller.pause(until: date(11))
        controller.resume()
        #expect(controller.pause == nil)
        #expect(controller.ownsCapture)
        #expect(controller.evaluate(schedule: schedule, now: date(10), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: schedule, now: date(18), hasCaptureIntent: true, calendar: calendar) == .stop)
    }

    @Test("一時停止中に利用者が止めると一時停止が終わり、再開しない")
    func userStopClearsPause() {
        var controller = LifeLogCaptureController()
        controller.userChangedCapture(enabled: true, schedule: noSchedule, now: date(10), calendar: calendar)
        controller.pause(until: date(10, 30))
        controller.userChangedCapture(enabled: false, schedule: noSchedule, now: date(10, 10), calendar: calendar)
        #expect(controller.pause == nil)
        #expect(controller.evaluate(schedule: noSchedule, now: date(10, 30), hasCaptureIntent: false, calendar: calendar) == .none)
    }

    @Test("一時停止中に時間帯が始まっても記録を始めない")
    func scheduledStartDoesNotEndPause() {
        var controller = LifeLogCaptureController()
        controller.userChangedCapture(enabled: true, schedule: schedule, now: date(8, 50), calendar: calendar)
        controller.pause(until: date(9, 20))
        #expect(controller.evaluate(schedule: schedule, now: date(9), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(controller.pause != nil)
        #expect(controller.evaluate(schedule: schedule, now: date(9, 20), hasCaptureIntent: true, calendar: calendar) == .resume)
        // 手動の記録のままなので、時間帯の終わりでも止めない。
        #expect(!controller.ownsCapture)
        #expect(controller.evaluate(schedule: schedule, now: date(18), hasCaptureIntent: true, calendar: calendar) == .none)
    }

    @Test("自動記録の一時停止中に時間帯が終わると止め、再開を取り消す")
    func windowEndCancelsScheduleOwnedPause() {
        var controller = scheduledRecording(at: date(17))
        controller.pause(until: date(18, 30))
        #expect(controller.evaluate(schedule: schedule, now: date(17, 59), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: schedule, now: date(18), hasCaptureIntent: true, calendar: calendar) == .stop)
        #expect(controller.pause == nil)
        #expect(!controller.ownsCapture)
        #expect(controller.evaluate(schedule: schedule, now: date(18, 30), hasCaptureIntent: false, calendar: calendar) == .none)
    }

    @Test("手動の記録の一時停止は時間帯が終わっても続き、再開時刻で再開する")
    func windowEndKeepsManualPause() {
        var controller = LifeLogCaptureController()
        controller.userChangedCapture(enabled: true, schedule: schedule, now: date(17), calendar: calendar)
        controller.pause(until: date(18, 30))
        #expect(controller.evaluate(schedule: schedule, now: date(18), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(controller.pause != nil)
        #expect(controller.evaluate(schedule: schedule, now: date(18, 30), hasCaptureIntent: true, calendar: calendar) == .resume)
    }

    @Test("再度の一時停止は再開時刻だけを置き換え、所有者を保つ")
    func rePauseKeepsOwner() {
        var controller = scheduledRecording(at: date(9))
        controller.pause(until: date(9, 30))
        controller.pause(until: date(10))
        #expect(controller.pause == LifeLogPause(resumesAt: date(10), scheduleOwnedCapture: true))
        #expect(controller.evaluate(schedule: schedule, now: date(9, 30), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: schedule, now: date(10), hasCaptureIntent: true, calendar: calendar) == .resume)
        #expect(controller.ownsCapture)
    }

    @Test("再起動後、再開時刻の前なら一時停止を続け、過ぎていれば再開し、所有者を戻す")
    func restoresStoredPauseAfterRelaunch() {
        let stored = LifeLogPause(resumesAt: date(10, 30), scheduleOwnedCapture: true)

        var before = LifeLogCaptureController(restoring: stored)
        #expect(before.evaluate(schedule: schedule, now: date(10, 10), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(before.pause == stored)
        #expect(before.evaluate(schedule: schedule, now: date(10, 30), hasCaptureIntent: true, calendar: calendar) == .resume)
        #expect(before.ownsCapture)
        #expect(before.evaluate(schedule: schedule, now: date(18), hasCaptureIntent: true, calendar: calendar) == .stop)

        var after = LifeLogCaptureController(restoring: stored)
        #expect(after.evaluate(schedule: schedule, now: date(11), hasCaptureIntent: true, calendar: calendar) == .resume)
        #expect(after.ownsCapture)

        var manual = LifeLogCaptureController(restoring: LifeLogPause(resumesAt: date(10, 30), scheduleOwnedCapture: false))
        #expect(manual.evaluate(schedule: schedule, now: date(19), hasCaptureIntent: true, calendar: calendar) == .resume)
        #expect(!manual.ownsCapture)
    }

    @Test("再起動後、自動記録の時間帯が終わっていれば再開せず止める")
    func restoredScheduleOwnedPauseStopsAfterWindow() {
        var controller = LifeLogCaptureController(
            restoring: LifeLogPause(resumesAt: date(17, 30), scheduleOwnedCapture: true)
        )
        #expect(controller.evaluate(schedule: schedule, now: date(19), hasCaptureIntent: true, calendar: calendar) == .stop)
        #expect(controller.pause == nil)
    }

    @Test("次に起きる時刻は時間帯の切替と再開時刻の早い方")
    func nextWake() {
        var controller = scheduledRecording(at: date(17))
        #expect(controller.nextWake(schedule: schedule, now: date(17), calendar: calendar) == date(18))
        controller.pause(until: date(17, 30))
        #expect(controller.nextWake(schedule: schedule, now: date(17), calendar: calendar) == date(17, 30))
        controller.pause(until: date(18, 30))
        #expect(controller.nextWake(schedule: schedule, now: date(17), calendar: calendar) == date(18))

        var manual = LifeLogCaptureController()
        #expect(manual.nextWake(schedule: noSchedule, now: date(17), calendar: calendar) == nil)
        manual.pause(until: date(17, 15))
        #expect(manual.nextWake(schedule: noSchedule, now: date(17), calendar: calendar) == date(17, 15))
    }

    @Test("一時停止の長さは再開時刻になり、予定がなければ「予定が終わるまで」は選べない")
    func pauseLengths() {
        let now = date(10)
        #expect(LifeLogPauseLength.fifteenMinutes.resumeDate(now: now, currentEventEnd: nil) == date(10, 15))
        #expect(LifeLogPauseLength.thirtyMinutes.resumeDate(now: now, currentEventEnd: nil) == date(10, 30))
        #expect(LifeLogPauseLength.oneHour.resumeDate(now: now, currentEventEnd: nil) == date(11))
        #expect(LifeLogPauseLength.untilEventEnds.resumeDate(now: now, currentEventEnd: date(10, 45)) == date(10, 45))
        #expect(LifeLogPauseLength.untilEventEnds.resumeDate(now: now, currentEventEnd: nil) == nil)
        #expect(LifeLogPauseLength.untilEventEnds.resumeDate(now: now, currentEventEnd: date(9, 45)) == nil)
    }
}

@Suite("ライフログを記録しない予定")
struct LifeLogRecordingExclusionsTests {
    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 16) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func event(
        _ id: String, _ start: Date, _ end: Date, calendar: String = "Work", allDay: Bool = false
    ) -> CalendarEventSnapshot {
        CalendarEventSnapshot(id: id, title: id, startsAt: start, endsAt: end, calendarTitle: calendar, isAllDay: allDay)
    }

    @Test("記録しないカレンダーの予定は、進行中の間だけ録音を止める")
    func calendarMatchHoldsWhileInProgress() {
        let exclusions = LifeLogRecordingExclusions(calendarTitles: ["Private"])
        let therapy = event("therapy", date(10), date(11), calendar: "Private")
        let standup = event("standup", date(10), date(10, 30))
        let events = [standup, therapy]
        #expect(exclusions.excludes(therapy))
        #expect(!exclusions.excludes(standup))
        #expect(exclusions.holdingEvent(in: events, at: date(9, 59)) == nil)
        #expect(exclusions.holdingEvent(in: events, at: date(10)) == therapy)
        #expect(exclusions.holdingEvent(in: events, at: date(10, 59)) == therapy)
        #expect(exclusions.holdingEvent(in: events, at: date(11)) == nil)
    }

    @Test("一回の予定の印は、同じ繰り返し予定の別の回には効かない")
    func singleEventMatchesOnlyThatOccurrence() {
        let today = event("weekly", date(10), date(11))
        let nextWeek = event("weekly", date(10, day: 23), date(11, day: 23))
        var exclusions = LifeLogRecordingExclusions()
        exclusions.setSkipped(true, event: today)
        #expect(exclusions.excludes(today))
        #expect(!exclusions.excludes(nextWeek))
        #expect(exclusions.holdingEvent(in: [today, nextWeek], at: date(10, 30)) == today)
        #expect(exclusions.holdingEvent(in: [today, nextWeek], at: date(10, 30, day: 23)) == nil)

        exclusions.setSkipped(true, event: today)
        #expect(exclusions.events.count == 1)
        exclusions.setSkipped(false, event: today)
        #expect(exclusions.isEmpty)
    }

    @Test("終日の予定は録音を止めない")
    func allDayNeverHolds() {
        let allDay = event("offsite", date(0), date(0, day: 17), calendar: "Private", allDay: true)
        var exclusions = LifeLogRecordingExclusions(calendarTitles: ["Private"])
        exclusions.setSkipped(true, event: allDay)
        #expect(!exclusions.excludes(allDay))
        #expect(exclusions.holdingEvent(in: [allDay], at: date(12)) == nil)
        #expect(exclusions.nextBoundary(in: [allDay], after: date(12)) == nil)
    }

    @Test("連続・重複する予定は、最後に終わる予定まで止め続ける")
    func backToBackEventsHoldUntilTheLastEnds() {
        let exclusions = LifeLogRecordingExclusions(calendarTitles: ["Private"])
        let first = event("first", date(10), date(11), calendar: "Private")
        let second = event("second", date(11), date(12), calendar: "Private")
        let overlapping = event("overlapping", date(10, 30), date(11, 30), calendar: "Private")
        let events = [first, second, overlapping]
        #expect(exclusions.holdingEvent(in: events, at: date(10, 45)) == overlapping)
        #expect(exclusions.holdingEvent(in: events, at: date(11)) == second)
        #expect(exclusions.holdingEvent(in: events, at: date(11, 59)) == second)
        #expect(exclusions.holdingEvent(in: events, at: date(12)) == nil)
    }

    @Test("次の境界は対象の予定の開始と終了だけを見る")
    func nextBoundary() {
        let exclusions = LifeLogRecordingExclusions(calendarTitles: ["Private"])
        let events = [
            event("standup", date(9), date(9, 30)),
            event("therapy", date(10), date(11), calendar: "Private"),
        ]
        #expect(exclusions.nextBoundary(in: events, after: date(8)) == date(10))
        #expect(exclusions.nextBoundary(in: events, after: date(10)) == date(11))
        #expect(exclusions.nextBoundary(in: events, after: date(11)) == nil)
    }

    @Test("終わった予定の印だけを捨てる")
    func pruning() {
        var exclusions = LifeLogRecordingExclusions(calendarTitles: ["Private"])
        exclusions.setSkipped(true, event: event("past", date(8), date(9)))
        exclusions.setSkipped(true, event: event("current", date(10), date(11)))
        exclusions.setSkipped(true, event: event("future", date(15), date(16)))
        let pruned = exclusions.pruned(endedBefore: date(10, 30))
        #expect(pruned.events.map(\.eventID) == ["current", "future"])
        #expect(pruned.calendarTitles == ["Private"])
    }

    @Test("保存して読み直しても同じ予定を指す")
    func codableRoundTrip() throws {
        let skipped = event("weekly", date(10), date(11))
        var exclusions = LifeLogRecordingExclusions(calendarTitles: ["Private", "家族"])
        exclusions.setSkipped(true, event: skipped)
        let decoded = try JSONDecoder().decode(
            LifeLogRecordingExclusions.self, from: JSONEncoder().encode(exclusions)
        )
        #expect(decoded == exclusions)
        #expect(decoded.excludes(skipped))
    }
}

@Suite("ライフログのhold")
@MainActor
struct LifeLogCoordinatorHoldTests {
    @Test("holdの間は記録意図を保ったまま一時停止と表示し、録音を始めない")
    func holdKeepsIntentWithoutCapturing() {
        let coordinator = LifeLogCoordinator()
        coordinator.setHold(.paused(resumesAt: Date().addingTimeInterval(900)))
        coordinator.setCaptureEnabled(true)
        #expect(coordinator.hasCaptureIntent)
        #expect(coordinator.isHeld)
        #expect(!coordinator.isCapturing)
        #expect(coordinator.captureStatusText == "一時停止中")

        let eventEnd = Date().addingTimeInterval(600)
        coordinator.setHold(.event(title: "1on1", endsAt: eventEnd))
        #expect(coordinator.hold == .event(title: "1on1", endsAt: eventEnd))
        #expect(coordinator.isHeld)

        coordinator.setCaptureEnabled(false)
        #expect(!coordinator.isHeld)
        #expect(coordinator.captureStatusText == "停止中")
    }

    @Test("記録意図がなければ、holdがあっても停止中のまま")
    func holdWithoutIntentStaysStopped() {
        let coordinator = LifeLogCoordinator()
        coordinator.setHold(.event(title: "1on1", endsAt: Date().addingTimeInterval(600)))
        #expect(!coordinator.hasCaptureIntent)
        #expect(!coordinator.isHeld)
        #expect(coordinator.captureStatusText == "停止中")
    }
}

@Suite("ライフログの一時停止の保存")
struct LifeLogPauseSettingsTests {
    @MainActor
    @Test("一時停止と記録しない予定は設定に保存され、keyがない保存済み設定は既定値で読める")
    func persistsAndDecodesMissingKeys() throws {
        let suite = "lore.tests.pause.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data(#"{"holdThresholdMs":400}"#.utf8), forKey: AppSettings.defaultsKey)
        let legacy = AppSettings(defaults: defaults)
        #expect(legacy.holdThresholdMs == 400)
        #expect(legacy.lifeLogPause == nil)
        #expect(legacy.lifeLogRecordingExclusions.isEmpty)

        let pause = LifeLogPause(resumesAt: Date(timeIntervalSince1970: 1_800_000_000), scheduleOwnedCapture: true)
        var exclusions = LifeLogRecordingExclusions(calendarTitles: ["Private"])
        exclusions.setSkipped(true, event: CalendarEventSnapshot(
            id: "weekly", title: "1on1",
            startsAt: Date(timeIntervalSince1970: 1_800_000_000), endsAt: Date(timeIntervalSince1970: 1_800_003_600),
            calendarTitle: "Work"
        ))
        legacy.lifeLogPause = pause
        legacy.lifeLogRecordingExclusions = exclusions

        let reloaded = AppSettings(defaults: defaults)
        #expect(reloaded.lifeLogPause == pause)
        #expect(reloaded.lifeLogRecordingExclusions == exclusions)

        reloaded.lifeLogPause = nil
        #expect(AppSettings(defaults: defaults).lifeLogPause == nil)
    }
}
