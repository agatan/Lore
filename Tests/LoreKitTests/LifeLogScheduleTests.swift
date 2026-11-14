import Foundation
import Testing

@testable import LoreKit

@Suite("ライフログ自動記録の時間帯")
struct LifeLogScheduleTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }

    /// 2026-11-16は月曜日。
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 11, calendar: Calendar? = nil) -> Date {
        (calendar ?? self.calendar).date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    private let weekdays = LifeLogSchedule(isEnabled: true)

    @Test("平日9:00〜18:00の内外を判定する")
    func containsWeekdayWindow() {
        #expect(weekdays.window(containing: date(16, 9), calendar: calendar) == DateInterval(start: date(16, 9), end: date(16, 18)))
        #expect(weekdays.window(containing: date(16, 17, 59), calendar: calendar) != nil)
        #expect(weekdays.window(containing: date(16, 18), calendar: calendar) == nil)
        #expect(weekdays.window(containing: date(16, 8, 59), calendar: calendar) == nil)
        // 土曜日は対象外。
        #expect(weekdays.window(containing: date(21, 10), calendar: calendar) == nil)
    }

    @Test("無効または曜日なしなら時間帯も切替もない")
    func disabledHasNoTransitions() {
        let disabled = LifeLogSchedule(isEnabled: false)
        #expect(disabled.window(containing: date(16, 10), calendar: calendar) == nil)
        #expect(disabled.nextTransition(after: date(16, 10), calendar: calendar) == nil)
        let noDays = LifeLogSchedule(isEnabled: true, weekdays: [])
        #expect(noDays.nextTransition(after: date(16, 10), calendar: calendar) == nil)
        #expect(noDays.nextWindow(after: date(16, 10), calendar: calendar) == nil)
    }

    @Test("次の切替は時間帯の終わり、週末をまたいで次の月曜の開始")
    func nextTransitionSkipsWeekend() {
        #expect(weekdays.nextTransition(after: date(16, 10), calendar: calendar) == date(16, 18))
        #expect(weekdays.nextTransition(after: date(16, 7), calendar: calendar) == date(16, 9))
        // 金曜18時以降の次は月曜9時。
        #expect(weekdays.nextTransition(after: date(20, 18), calendar: calendar) == date(23, 9))
        #expect(weekdays.nextWindow(after: date(20, 19), calendar: calendar)?.start == date(23, 9))
    }

    @Test("終了が開始以前なら日付をまたぎ、開始日の曜日に属する")
    func overnightWindowBelongsToStartDay() {
        // 金曜22:00〜翌6:00だけ。
        let night = LifeLogSchedule(isEnabled: true, weekdays: [6], startMinute: 22 * 60, endMinute: 6 * 60)
        #expect(night.window(containing: date(21, 3), calendar: calendar) == DateInterval(start: date(20, 22), end: date(21, 6)))
        #expect(night.window(containing: date(20, 23), calendar: calendar) != nil)
        // 金曜の早朝は木曜開始の時間帯であり、木曜は対象外。
        #expect(night.window(containing: date(20, 3), calendar: calendar) == nil)
        #expect(night.nextTransition(after: date(21, 3), calendar: calendar) == date(21, 6))
    }

    @Test("開始と終了が同じなら24時間の時間帯")
    func equalStartAndEndIsFullDay() {
        let allDay = LifeLogSchedule(isEnabled: true, weekdays: [2], startMinute: 0, endMinute: 0)
        #expect(allDay.window(containing: date(16, 12), calendar: calendar) == DateInterval(start: date(16, 0), end: date(17, 0)))
    }

    @Test("DSTで存在しない開始時刻は次に存在する時刻へ進める")
    func daylightSavingGap() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        // 2026-03-08(日)は2:00が3:00へ進む。
        let schedule = LifeLogSchedule(isEnabled: true, weekdays: [1], startMinute: 2 * 60 + 30, endMinute: 5 * 60)
        let window = schedule.window(containing: date(8, 4, month: 3, calendar: newYork), calendar: newYork)
        #expect(window?.start == date(8, 3, month: 3, calendar: newYork))
        #expect(window?.end == date(8, 5, month: 3, calendar: newYork))
    }

    @MainActor
    @Test("設定は保存され、未保存なら既定の無効・平日9〜18時")
    func persistsSchedule() {
        let defaults = UserDefaults(suiteName: "lore-schedule-\(UUID().uuidString)")!
        let settings = AppSettings(defaults: defaults)
        #expect(settings.lifeLogSchedule == LifeLogSchedule(isEnabled: false, weekdays: [2, 3, 4, 5, 6], startMinute: 540, endMinute: 1080))
        settings.lifeLogSchedule = LifeLogSchedule(isEnabled: true, weekdays: [1, 7], startMinute: 600, endMinute: 120)
        #expect(AppSettings(defaults: defaults).lifeLogSchedule == settings.lifeLogSchedule)
    }
}

@Suite("ライフログ自動記録の判断")
struct LifeLogScheduleControllerTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        return value
    }

    private func date(_ hour: Int, _ minute: Int = 0, day: Int = 16) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private let schedule = LifeLogSchedule(isEnabled: true)

    @Test("時間帯の開始で記録を始め、終了で自分が始めた記録だけを止める")
    func startsAndStopsOwnCapture() {
        var controller = LifeLogScheduleController()
        #expect(controller.evaluate(schedule: schedule, now: date(8), hasCaptureIntent: false, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: schedule, now: date(9), hasCaptureIntent: false, calendar: calendar) == .start)
        #expect(controller.ownsCapture)
        // 時間帯の途中の再評価(wake等)では何もしない。
        #expect(controller.evaluate(schedule: schedule, now: date(12), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: schedule, now: date(18), hasCaptureIntent: true, calendar: calendar) == .stop)
        #expect(!controller.ownsCapture)
        #expect(controller.evaluate(schedule: schedule, now: date(19), hasCaptureIntent: false, calendar: calendar) == .none)
    }

    @Test("手動で始めた記録は時間帯の終わりでも止めない")
    func manualCaptureIsNeverStopped() {
        var controller = LifeLogScheduleController()
        controller.userChangedCapture(enabled: true, schedule: schedule, now: date(8), calendar: calendar)
        #expect(controller.evaluate(schedule: schedule, now: date(9), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: schedule, now: date(18), hasCaptureIntent: true, calendar: calendar) == .none)
    }

    @Test("時間帯の途中で手動停止したら、その時間帯では再開せず次の時間帯で再開する")
    func manualStopSuppressesUntilNextWindow() {
        var controller = LifeLogScheduleController()
        #expect(controller.evaluate(schedule: schedule, now: date(9), hasCaptureIntent: false, calendar: calendar) == .start)
        controller.userChangedCapture(enabled: false, schedule: schedule, now: date(10), calendar: calendar)
        #expect(!controller.ownsCapture)
        #expect(controller.evaluate(schedule: schedule, now: date(11), hasCaptureIntent: false, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: schedule, now: date(18), hasCaptureIntent: false, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: schedule, now: date(9, day: 17), hasCaptureIntent: false, calendar: calendar) == .start)
    }

    @Test("時間帯の中での起動や有効化では、記録していなければ始める")
    func startsWhenEnabledInsideWindow() {
        var controller = LifeLogScheduleController()
        #expect(controller.evaluate(schedule: schedule, now: date(13), hasCaptureIntent: false, calendar: calendar) == .start)
        var recording = LifeLogScheduleController()
        #expect(recording.evaluate(schedule: schedule, now: date(13), hasCaptureIntent: true, calendar: calendar) == .none)
        #expect(!recording.ownsCapture)
    }

    @Test("自動開始できなかった時間帯は終わるまで再試行しない")
    func failedStartIsNotRetriedInSameWindow() {
        var controller = LifeLogScheduleController()
        #expect(controller.evaluate(schedule: schedule, now: date(9), hasCaptureIntent: false, calendar: calendar) == .start)
        controller.startFailed(schedule: schedule, now: date(9), calendar: calendar)
        #expect(controller.evaluate(schedule: schedule, now: date(10), hasCaptureIntent: false, calendar: calendar) == .none)
        #expect(controller.evaluate(schedule: schedule, now: date(9, day: 17), hasCaptureIntent: false, calendar: calendar) == .start)
    }

    @Test("無効化すると自分が始めた記録を止める")
    func disablingStopsOwnedCapture() {
        var controller = LifeLogScheduleController()
        #expect(controller.evaluate(schedule: schedule, now: date(9), hasCaptureIntent: false, calendar: calendar) == .start)
        var disabled = schedule
        disabled.isEnabled = false
        #expect(controller.evaluate(schedule: disabled, now: date(10), hasCaptureIntent: true, calendar: calendar) == .stop)
    }
}

@Suite("ライフログ自動記録の起動境界", .serialized)
struct LifeLogScheduleEnvironmentTests {
    @MainActor
    @Test("録音保存に同意していなければ自動開始せず、手動開始を案内する")
    func requiresConsentBeforeScheduledStart() {
        let env = AppEnvironment()
        let previous = env.settings.lifeLogSchedule
        let previousConsent = env.settings.lifeLogAudioStorageConfirmed
        defer {
            env.settings.lifeLogSchedule = previous
            env.settings.lifeLogAudioStorageConfirmed = previousConsent
        }
        env.settings.lifeLogAudioStorageConfirmed = false
        // 現在時刻を必ず含む24時間・全曜日の時間帯。
        env.settings.lifeLogSchedule = LifeLogSchedule(isEnabled: true, weekdays: Set(1...7), startMinute: 0, endMinute: 0)

        env.applyLifeLogSchedule()

        #expect(!env.lifeLog.hasCaptureIntent)
        #expect(!env.presentsLifeLogAudioConsent)
        #expect(!env.lifeLogScheduleState.ownsCapture)
        #expect(env.lifeLog.errorMessage == String(lore: "自動記録を始められませんでした。録音の保存に同意するため、一度手動でライフログを開始してください"))
    }
}
