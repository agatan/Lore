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
