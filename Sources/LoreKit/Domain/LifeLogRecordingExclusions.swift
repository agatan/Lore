import Foundation

/// 「記録しない」と印を付けた一回の予定。繰り返し予定の一回だけを指せるよう、開始時刻も鍵にする。
public struct LifeLogSkippedEvent: Codable, Sendable, Equatable {
    public var eventID: String
    public var startsAt: Date
    public var endsAt: Date

    public init(eventID: String, startsAt: Date, endsAt: Date) {
        self.eventID = eventID
        self.startsAt = startsAt
        self.endsAt = endsAt
    }

    /// EventKitから読んだ予定と、DBを経た予定では秒未満の表現が揃わないことがある。
    func matches(_ event: CalendarEventSnapshot) -> Bool {
        eventID == event.id && abs(startsAt.timeIntervalSince(event.startsAt)) < 1
    }
}

/// ライフログを記録しないカレンダーと予定。進行中の間だけ録音を止める判断を持つ。
public struct LifeLogRecordingExclusions: Codable, Sendable, Equatable {
    public var calendarTitles: Set<String>
    public var events: [LifeLogSkippedEvent]

    public init(calendarTitles: Set<String> = [], events: [LifeLogSkippedEvent] = []) {
        self.calendarTitles = calendarTitles
        self.events = events
    }

    public var isEmpty: Bool { calendarTitles.isEmpty && events.isEmpty }

    /// 終日の予定は一日中録音を止めてしまうため、対象にしない。
    public func excludes(_ event: CalendarEventSnapshot) -> Bool {
        guard !event.isAllDay else { return false }
        return calendarTitles.contains(event.calendarTitle) || events.contains { $0.matches(event) }
    }

    /// `date`に録音を止めている予定。連続・重複する場合は最後に終わるもの。
    public func holdingEvent(in candidates: [CalendarEventSnapshot], at date: Date) -> CalendarEventSnapshot? {
        candidates
            .filter { excludes($0) && $0.contains(date) }
            .max { $0.endsAt < $1.endsAt }
    }

    /// `date`より後で、対象の予定が最初に始まる、または終わる時刻。
    public func nextBoundary(in candidates: [CalendarEventSnapshot], after date: Date) -> Date? {
        candidates
            .filter(excludes)
            .flatMap { [$0.startsAt, $0.endsAt] }
            .filter { $0 > date }
            .min()
    }

    /// この一回の予定に「記録しない」の印があるか。カレンダー単位の指定は含めない。
    public func isSkipped(_ event: CalendarEventSnapshot) -> Bool {
        events.contains { $0.matches(event) }
    }

    public mutating func setSkipped(_ skipped: Bool, event: CalendarEventSnapshot) {
        events.removeAll { $0.matches(event) }
        if skipped {
            events.append(LifeLogSkippedEvent(eventID: event.id, startsAt: event.startsAt, endsAt: event.endsAt))
        }
    }

    /// 終わった予定の印を捨てる。
    public func pruned(endedBefore date: Date) -> LifeLogRecordingExclusions {
        var copy = self
        copy.events.removeAll { $0.endsAt <= date }
        return copy
    }
}
