import Foundation

/// Inspectorに出す、選択日の会議の量。AIも通信も使わず、保存済みの予定だけから求める。
///
/// 会議は、参加フィルターを通った時刻付きの予定。終日の予定は数えない。
public struct MeetingLoad: Sendable, Equatable {
    /// この間隔より短い間で次の会議が始まれば、連続とみなす。
    public static let backToBackThreshold: TimeInterval = 5 * 60
    public static let defaultWindowStartHour = 9
    public static let defaultWindowEndHour = 18

    public var meetingCount: Int
    /// 選択日の中で、いずれかの会議が覆う時間。重なりは二重に数えない。
    public var totalDuration: TimeInterval
    /// 前の会議の終了から5分未満で次が始まった回数。重なる会議は含めない。
    public var backToBackTransitions: Int
    /// 作業時間帯の中で、会議が覆わない最長の区間。空きがなければnil。
    public var longestFreeBlock: DateInterval?
    /// 他の会議と重なっている会議の数。
    public var overlappingMeetingCount: Int

    /// 会議が一つもない日はnilを返し、呼び出し側は何も出さない。
    public static func calculate(
        events: [CalendarEventSnapshot],
        on date: Date,
        workingWindow: DateInterval,
        participatingOnly: Bool,
        calendar: Calendar = .current
    ) -> MeetingLoad? {
        let day = calendar.dateInterval(of: .day, for: date)
            ?? DateInterval(start: calendar.startOfDay(for: date), duration: 86_400)
        let meetings = events
            .filter { !$0.isAllDay && (!participatingOnly || $0.participationStatus.isParticipating) }
            .compactMap { event -> DateInterval? in
                let start = max(event.startsAt, day.start)
                let end = min(event.endsAt, day.end)
                return start < end ? DateInterval(start: start, end: end) : nil
            }
            .sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        guard !meetings.isEmpty else { return nil }

        // 開始が前の終了より前のものだけを一つにまとめる。接する会議は別のまま残し、連続として数える。
        var blocks: [DateInterval] = []
        var overlapping = Set<Int>()
        var reach: (end: Date, index: Int)?
        for (index, meeting) in meetings.enumerated() {
            if let current = reach, meeting.start < current.end {
                overlapping.insert(index)
                overlapping.insert(current.index)
                blocks[blocks.count - 1].end = max(current.end, meeting.end)
                if meeting.end > current.end { reach = (meeting.end, index) }
            } else {
                blocks.append(meeting)
                reach = (meeting.end, index)
            }
        }

        let gaps = zip(blocks, blocks.dropFirst()).map { $1.start.timeIntervalSince($0.end) }
        return MeetingLoad(
            meetingCount: meetings.count,
            totalDuration: blocks.reduce(0) { $0 + $1.duration },
            backToBackTransitions: gaps.filter { $0 < backToBackThreshold }.count,
            longestFreeBlock: longestFreeBlock(in: workingWindow.intersection(with: day), around: blocks),
            overlappingMeetingCount: overlapping.count
        )
    }

    /// 予約録音が有効でその日に時間帯があればそれ(日付をまたぐ分は翌日に属する)、なければ9:00から18:00。
    public static func workingWindow(
        on date: Date,
        schedule: LifeLogSchedule,
        calendar: Calendar = .current
    ) -> DateInterval {
        let dayStart = calendar.startOfDay(for: date)
        if let window = schedule.window(startingOn: dayStart, calendar: calendar) { return window }
        let start = calendar.date(byAdding: .hour, value: defaultWindowStartHour, to: dayStart) ?? dayStart
        let end = calendar.date(byAdding: .hour, value: defaultWindowEndHour, to: dayStart) ?? dayStart
        return DateInterval(start: start, end: end)
    }

    private static func longestFreeBlock(in window: DateInterval?, around blocks: [DateInterval]) -> DateInterval? {
        guard let window else { return nil }
        var best: DateInterval?
        var cursor = window.start
        for block in blocks + [DateInterval(start: window.end, end: window.end)] {
            let end = min(block.start, window.end)
            if end > cursor, end.timeIntervalSince(cursor) > (best?.duration ?? 0) {
                best = DateInterval(start: cursor, end: end)
            }
            cursor = max(cursor, block.end)
        }
        return best
    }
}
