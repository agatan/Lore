import Foundation

/// 端末上で実際に録音した時間の日別集計。
public struct DailyRecordingDuration: Sendable, Equatable, Identifiable {
    public var id: String { day }
    public let day: String
    public let seconds: TimeInterval

    public init(day: String, seconds: TimeInterval) {
        self.day = day
        self.seconds = seconds
    }
}

extension DailyRecordingDuration {
    /// 日をまたぐ録音は午前0時で分割し、各日の実時間として集計する。
    static func aggregate(
        intervals: [(start: Date, end: Date)],
        calendar: Calendar
    ) -> [DailyRecordingDuration] {
        var secondsByDay: [String: TimeInterval] = [:]
        for interval in intervals where interval.end > interval.start {
            var cursor = interval.start
            while cursor < interval.end {
                let startOfDay = calendar.startOfDay(for: cursor)
                guard let startOfNextDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { break }
                let segmentEnd = min(interval.end, startOfNextDay)
                secondsByDay[LifeLogDateKey.string(for: cursor, calendar: calendar), default: 0]
                    += segmentEnd.timeIntervalSince(cursor)
                cursor = segmentEnd
            }
        }
        return secondsByDay.map { DailyRecordingDuration(day: $0.key, seconds: $0.value) }
            .sorted { $0.day > $1.day }
    }
}
