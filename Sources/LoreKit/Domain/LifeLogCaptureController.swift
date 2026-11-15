import Foundation

/// 利用者が始めた一時停止。再開時刻と、再開後に記録を誰が所有するかを持つ。
public struct LifeLogPause: Codable, Sendable, Equatable {
    public var resumesAt: Date
    /// 一時停止の前、記録を自動記録が所有していたか。
    public var scheduleOwnedCapture: Bool

    public init(resumesAt: Date, scheduleOwnedCapture: Bool) {
        self.resumesAt = resumesAt
        self.scheduleOwnedCapture = scheduleOwnedCapture
    }
}

/// メニューとApp Intentが選ぶ一時停止の長さ。
public enum LifeLogPauseLength: CaseIterable, Sendable {
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case untilEventEnds

    /// 再開時刻。「予定が終わるまで」は進行中の予定がなければnil。
    public func resumeDate(now: Date, currentEventEnd: Date?) -> Date? {
        switch self {
        case .fifteenMinutes: now.addingTimeInterval(15 * 60)
        case .thirtyMinutes: now.addingTimeInterval(30 * 60)
        case .oneHour: now.addingTimeInterval(60 * 60)
        case .untilEventEnds: currentEventEnd.flatMap { $0 > now ? $0 : nil }
        }
    }
}

/// 記録意図を保ったままマイクを止めている理由。
public enum LifeLogCaptureHold: Equatable, Sendable {
    case paused(resumesAt: Date)
    case event(title: String, endsAt: Date)
}

/// 記録意図を誰が所有し、一時停止しているかを決める状態機械。録音の実行や時刻の取得は呼び出し側が行う。
public struct LifeLogCaptureController: Sendable, Equatable {
    public enum Action: Sendable, Equatable {
        case start
        case stop
        /// 一時停止が終わった。記録意図を持ったまま録音を再開する。
        case resume
        case none
    }

    /// 現在の記録意図をscheduleが作ったか。手動で始めた記録はscheduleが止めない。
    public private(set) var ownsCapture = false
    /// 利用者が時間帯の途中で止めた場合、その時間帯の開始時刻。次の時間帯まで再開しない。
    public private(set) var suppressedWindowStart: Date?
    public private(set) var pause: LifeLogPause?

    public init() {}

    /// 前のprocessが残した一時停止を、所有者ごと引き継ぐ。
    public init(restoring pause: LifeLogPause?) {
        self.pause = pause
        ownsCapture = pause?.scheduleOwnedCapture ?? false
    }

    /// 現在時刻での望ましい遷移を決め、`.start`の場合はscheduleが記録を所有する。
    public mutating func evaluate(
        schedule: LifeLogSchedule,
        now: Date,
        hasCaptureIntent: Bool,
        calendar: Calendar = .current
    ) -> Action {
        let window = schedule.window(containing: now, calendar: calendar)
        if suppressedWindowStart != window?.start { suppressedWindowStart = nil }

        if let pause {
            // 一時停止は記録意図として扱う。時間帯が始まっても割り込まない。
            ownsCapture = pause.scheduleOwnedCapture
            if pause.scheduleOwnedCapture, window == nil {
                self.pause = nil
                ownsCapture = false
                return hasCaptureIntent ? .stop : .none
            }
            guard now >= pause.resumesAt else { return .none }
            self.pause = nil
            return .resume
        }

        guard window != nil else {
            guard ownsCapture else { return .none }
            ownsCapture = false
            return hasCaptureIntent ? .stop : .none
        }
        guard !hasCaptureIntent, suppressedWindowStart == nil else { return .none }
        ownsCapture = true
        return .start
    }

    /// 自動開始できなかった時間帯（同意がない等）を、時間帯の終わりまで再試行しない。
    public mutating func startFailed(schedule: LifeLogSchedule, now: Date, calendar: Calendar = .current) {
        ownsCapture = false
        suppressedWindowStart = schedule.window(containing: now, calendar: calendar)?.start
    }

    /// UI、hotkey、Shortcutsからの開始・停止。手動の記録はscheduleの所有から外し、一時停止も終える。
    public mutating func userChangedCapture(
        enabled: Bool,
        schedule: LifeLogSchedule,
        now: Date,
        calendar: Calendar = .current
    ) {
        ownsCapture = false
        pause = nil
        if enabled {
            suppressedWindowStart = nil
        } else {
            suppressedWindowStart = schedule.window(containing: now, calendar: calendar)?.start
        }
    }

    /// 一時停止する。一時停止中の再実行は再開時刻だけを置き換え、所有者は変えない。
    public mutating func pause(until resumesAt: Date) {
        pause = LifeLogPause(resumesAt: resumesAt, scheduleOwnedCapture: ownsCapture)
    }

    /// 利用者が早めに再開した。所有者は一時停止の前のまま。
    public mutating func resume() {
        pause = nil
    }

    /// 次に`evaluate`すべき時刻。時間帯の切替と再開時刻の早い方。
    public func nextWake(schedule: LifeLogSchedule, now: Date, calendar: Calendar = .current) -> Date? {
        [schedule.nextTransition(after: now, calendar: calendar), pause?.resumesAt].compactMap { $0 }.min()
    }
}
