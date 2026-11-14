import Foundation

/// 日別timelineの行の並びと、行をつなぐ縦線の意味を決める。SwiftUIはこの結果を描くだけにする。
public enum LifeLogTimelineLayout {
    /// 前の項目からこれ以上空いた区間は、空き時間として示す。
    public static let gapThreshold: TimeInterval = 60 * 60

    public enum Kind: Sendable {
        case event(CalendarEventSnapshot)
        case utterance(LifeLogUtterance)
        case dictation(LifeLogDictation)
        case memo(LifeLogMemo)
    }

    /// 行と行の間の縦線。予定の区間内か、長い空きか、ただの連続か。
    public enum Segment: Sendable, Equatable {
        case none
        case plain
        case event
        case gap
    }

    public struct Row: Identifiable, Sendable {
        /// `e-`/`u-`/`d-`/`m-`で始まる既存のtimeline item ID。
        public var id: String
        public var date: Date
        public var kind: Kind
        public var above: Segment
        public var below: Segment
        /// 直前の項目からの空き。`above == .gap`の時だけ値を持つ。
        public var gapBefore: TimeInterval?
    }

    /// 時刻のある予定、発話、音声入力、memoを時刻順に並べる。終日の予定は含めない。
    /// 同時刻では予定を先に置き、予定の行がその区間の見出しになるようにする。
    public static func rows(for day: LifeLogDay) -> [Row] {
        let timedEvents = day.calendarEvents.filter { !$0.isAllDay }
        let items: [(id: String, date: Date, order: Int, kind: Kind)] =
            timedEvents.map { ("e-\($0.id)", $0.startsAt, 0, .event($0)) }
            + day.utterances.map { ("u-\($0.id)", $0.startedAt, 1, .utterance($0)) }
            + day.dictations.map { ("d-\($0.id)", $0.startedAt, 1, .dictation($0)) }
            + day.memos.map { ("m-\($0.id)", $0.createdAt, 1, .memo($0)) }
        let sorted = items.sorted {
            ($0.date, $0.order, $0.id) < ($1.date, $1.order, $1.id)
        }

        var rows: [Row] = []
        rows.reserveCapacity(sorted.count)
        for (index, item) in sorted.enumerated() {
            let above = rows.last?.below ?? .none
            let below: Segment
            if index + 1 < sorted.count {
                below = segment(from: item.date, to: sorted[index + 1].date, events: timedEvents)
            } else {
                below = .none
            }
            let gap = above == .gap ? rows.last.map { item.date.timeIntervalSince($0.date) } : nil
            rows.append(Row(id: item.id, date: item.date, kind: item.kind, above: above, below: below, gapBefore: gap))
        }
        return rows
    }

    public static func allDayEvents(in day: LifeLogDay) -> [CalendarEventSnapshot] {
        day.calendarEvents.filter(\.isAllDay).sorted { $0.title < $1.title }
    }

    /// 両端が同じ予定の中なら予定の区間。予定の外で長く空いた時だけ空きとして示す。
    static func segment(from start: Date, to end: Date, events: [CalendarEventSnapshot]) -> Segment {
        if events.contains(where: { $0.startsAt <= start && end <= $0.endsAt }) { return .event }
        return end.timeIntervalSince(start) >= gapThreshold ? .gap : .plain
    }
}

/// Inspectorに出す、選択日の量の要約。
public struct LifeLogDaySummary: Sendable, Equatable {
    public var spokenDuration: TimeInterval
    public var utteranceCount: Int
    public var memoCount: Int
    public var dictationCount: Int

    public init(day: LifeLogDay) {
        spokenDuration = day.utterances.reduce(0) { $0 + max(0, $1.endedAt.timeIntervalSince($1.startedAt)) }
        utteranceCount = day.utterances.count
        memoCount = day.memos.count
        dictationCount = day.dictations.count
    }
}

/// Inspectorの「一日の流れ」で、どの時間範囲を縦軸にし、予定blockをどの列へ置くかを決める。
public struct LifeLogDayMapLayout: Sendable {
    /// 記録が少ない日でも、日中の位置関係が読める範囲は常に見せる。
    public static let minimumStartHour = 9
    public static let minimumEndHour = 18

    public struct Block: Identifiable, Sendable, Equatable {
        public var event: CalendarEventSnapshot
        public var column: Int
        public var columnCount: Int
        public var id: String { event.id }
    }

    public enum MarkKind: Sendable, Equatable {
        case utterance
        case dictation
        case memo
    }

    public struct Mark: Sendable, Equatable {
        public var kind: MarkKind
        public var start: Date
        public var end: Date
    }

    public var dayStart: Date
    /// 縦軸の範囲。`[startHour, endHour)`。
    public var startHour: Int
    public var endHour: Int
    public var blocks: [Block]
    public var marks: [Mark]

    public init(day: LifeLogDay, date: Date, calendar: Calendar = .current) {
        let dayStart = calendar.startOfDay(for: date)
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400)
        self.dayStart = dayStart

        let timed = day.calendarEvents
            .filter { !$0.isAllDay && $0.endsAt > dayStart && $0.startsAt < dayEnd }
            .sorted { ($0.startsAt, $0.endsAt, $0.id) < ($1.startsAt, $1.endsAt, $1.id) }
        marks = day.utterances.map { Mark(kind: .utterance, start: $0.startedAt, end: $0.endedAt) }
            + day.dictations.map { Mark(kind: .dictation, start: $0.startedAt, end: $0.endedAt) }
            + day.memos.map { Mark(kind: .memo, start: $0.createdAt, end: $0.createdAt) }

        let instants = marks.flatMap { [$0.start, $0.end] }
            + timed.flatMap { [max($0.startsAt, dayStart), min($0.endsAt, dayEnd)] }
        let hours = instants
            .filter { $0 >= dayStart && $0 <= dayEnd }
            .map { $0.timeIntervalSince(dayStart) / 3_600 }
        startHour = min(Self.minimumStartHour, Int((hours.min() ?? 24).rounded(.down)))
        endHour = max(Self.minimumEndHour, min(24, Int((hours.max() ?? 0).rounded(.up))))
        blocks = Self.columns(for: timed)
    }

    public var hourCount: Int { endHour - startHour }

    /// 縦軸上の位置。0が`startHour`、1が`endHour`。
    public func position(of date: Date) -> Double {
        let hours = date.timeIntervalSince(dayStart) / 3_600
        return min(1, max(0, (hours - Double(startHour)) / Double(hourCount)))
    }

    /// `position(of:)`の逆。Clickした位置の時刻を求める。
    public func date(at position: Double) -> Date {
        let clamped = min(1, max(0, position))
        return dayStart.addingTimeInterval((Double(startHour) + clamped * Double(hourCount)) * 3_600)
    }

    /// 重なる予定を連鎖ごとにまとめ、空いている最初の列へ置く。まとまり内の列数で幅を割る。
    static func columns(for events: [CalendarEventSnapshot]) -> [Block] {
        var result: [Block] = []
        var cluster: [Block] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let count = max(1, columnEnds.count)
            result += cluster.map { Block(event: $0.event, column: $0.column, columnCount: count) }
            cluster = []
            columnEnds = []
        }

        for event in events {
            if event.startsAt >= clusterEnd { flush() }
            if let free = columnEnds.firstIndex(where: { $0 <= event.startsAt }) {
                columnEnds[free] = event.endsAt
                cluster.append(Block(event: event, column: free, columnCount: 0))
            } else {
                columnEnds.append(event.endsAt)
                cluster.append(Block(event: event, column: columnEnds.count - 1, columnCount: 0))
            }
            clusterEnd = max(clusterEnd, event.endsAt)
        }
        flush()
        return result
    }
}
