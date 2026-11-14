import Foundation

/// ライフログを自動で記録する曜日と時間帯。一つの時間帯だけを持つ。
///
/// 終了時刻が開始時刻以前なら日付をまたぐ時間帯とし、開始日の曜日に属する。
/// 時刻は「その日の何分目」で保持し、具体的な日時への変換はCalendarに任せてDSTを吸収する。
public struct LifeLogSchedule: Codable, Sendable, Equatable {
    /// `Calendar.component(.weekday, ...)`と同じ1(日)〜7(土)。
    public var weekdays: Set<Int>
    public var startMinute: Int
    public var endMinute: Int
    public var isEnabled: Bool

    public init(isEnabled: Bool = false, weekdays: Set<Int> = [2, 3, 4, 5, 6], startMinute: Int = 9 * 60, endMinute: Int = 18 * 60) {
        self.isEnabled = isEnabled
        self.weekdays = weekdays.filter { (1...7).contains($0) }
        self.startMinute = Self.clampedMinute(startMinute)
        self.endMinute = Self.clampedMinute(endMinute)
    }

    public static let `default` = LifeLogSchedule()

    /// `date`を含む時間帯。無効、または時間帯の外ならnil。
    public func window(containing date: Date, calendar: Calendar = .current) -> DateInterval? {
        guard isEnabled else { return nil }
        let today = calendar.startOfDay(for: date)
        // 日付をまたぐ時間帯は前日開始の可能性がある。
        for offset in [0, -1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today),
                  let window = window(startingOn: day, calendar: calendar) else { continue }
            if window.start <= date && date < window.end { return window }
        }
        return nil
    }

    /// `date`より後で最初に時間帯が始まる、または終わる時刻。
    public func nextTransition(after date: Date, calendar: Calendar = .current) -> Date? {
        windows(around: date, calendar: calendar)
            .flatMap { [$0.start, $0.end] }
            .filter { $0 > date }
            .min()
    }

    /// `date`より後で最初に始まる時間帯。
    public func nextWindow(after date: Date, calendar: Calendar = .current) -> DateInterval? {
        windows(around: date, calendar: calendar)
            .filter { $0.start > date }
            .min { $0.start < $1.start }
    }

    private func windows(around date: Date, calendar: Calendar) -> [DateInterval] {
        guard isEnabled, !weekdays.isEmpty else { return [] }
        let today = calendar.startOfDay(for: date)
        return (-1...8).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today)
                .flatMap { window(startingOn: $0, calendar: calendar) }
        }
    }

    private func window(startingOn day: Date, calendar: Calendar) -> DateInterval? {
        guard weekdays.contains(calendar.component(.weekday, from: day)),
              let start = time(startMinute, on: day, calendar: calendar) else { return nil }
        let endDay = endMinute > startMinute ? day : calendar.date(byAdding: .day, value: 1, to: day)
        guard let endDay, let end = time(endMinute, on: endDay, calendar: calendar), start < end else { return nil }
        return DateInterval(start: start, end: end)
    }

    /// DSTで存在しない時刻は次に存在する時刻へ進める。
    private func time(_ minute: Int, on day: Date, calendar: Calendar) -> Date? {
        calendar.date(
            bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day,
            matchingPolicy: .nextTime, repeatedTimePolicy: .first, direction: .forward
        )
    }

    private static func clampedMinute(_ value: Int) -> Int { min(max(value, 0), 24 * 60 - 1) }
}

/// 自動記録の判断だけを持つ状態機械。録音の実行や時刻の取得は呼び出し側が行う。
public struct LifeLogScheduleController: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case start
        case stop
        case none
    }

    /// 現在の記録意図をscheduleが作ったか。手動で始めた記録はscheduleが止めない。
    public private(set) var ownsCapture = false
    /// 利用者が時間帯の途中で止めた場合、その時間帯の開始時刻。次の時間帯まで再開しない。
    public private(set) var suppressedWindowStart: Date?

    public init() {}

    /// 現在時刻での望ましい遷移を決め、`.start`の場合はscheduleが記録を所有する。
    public mutating func evaluate(
        schedule: LifeLogSchedule,
        now: Date,
        hasCaptureIntent: Bool,
        calendar: Calendar = .current
    ) -> Action {
        guard let window = schedule.window(containing: now, calendar: calendar) else {
            suppressedWindowStart = nil
            guard ownsCapture else { return .none }
            ownsCapture = false
            return hasCaptureIntent ? .stop : .none
        }
        if suppressedWindowStart != window.start { suppressedWindowStart = nil }
        guard !hasCaptureIntent, suppressedWindowStart == nil else { return .none }
        ownsCapture = true
        return .start
    }

    /// 自動開始できなかった時間帯（同意がない等）を、時間帯の終わりまで再試行しない。
    public mutating func startFailed(schedule: LifeLogSchedule, now: Date, calendar: Calendar = .current) {
        ownsCapture = false
        suppressedWindowStart = schedule.window(containing: now, calendar: calendar)?.start
    }

    /// UI、hotkey、Shortcutsからの開始・停止。手動の記録はscheduleの所有から外す。
    public mutating func userChangedCapture(
        enabled: Bool,
        schedule: LifeLogSchedule,
        now: Date,
        calendar: Calendar = .current
    ) {
        ownsCapture = false
        if enabled {
            suppressedWindowStart = nil
        } else {
            suppressedWindowStart = schedule.window(containing: now, calendar: calendar)?.start
        }
    }
}
