import Foundation

/// A timed event the user can join from Lore: it has a join link and is neither canceled nor declined.
public struct JoinableMeeting: Sendable, Hashable, Identifiable {
    public let event: CalendarEventSnapshot
    public let link: ConferenceLink

    /// One occurrence. Occurrences of a repeating event share the event identifier.
    public var id: String { "\(event.id)@\(event.startsAt.timeIntervalSinceReferenceDate)" }

    public init?(event: CalendarEventSnapshot, details: CalendarEventDetails?) {
        guard !event.isAllDay, event.participationStatus != .declined,
              let details, !details.isCanceled, let link = details.conferenceLink else { return nil }
        self.event = event
        self.link = link
    }
}

public enum MeetingCountdown: Sendable, Hashable {
    case startsIn(minutes: Int)
    case inProgress
}

/// Which meetings to offer at a moment, and when that answer changes.
public struct UpcomingMeetings: Sendable, Hashable {
    /// A meeting is offered from this long before its start until its end.
    public static let leadTime: TimeInterval = 10 * 60
    public static let reminderLeadTime: TimeInterval = 60

    public struct Entry: Sendable, Hashable, Identifiable {
        public let meeting: JoinableMeeting
        public let countdown: MeetingCountdown
        public var id: String { meeting.id }
    }

    public let meetings: [JoinableMeeting]

    public init(meetings: [JoinableMeeting] = []) {
        self.meetings = meetings
    }

    /// The meeting to join next comes first: upcoming ones by start, then those in progress, the latest start first.
    public func entries(at now: Date) -> [Entry] {
        let upcoming = meetings
            .filter { $0.event.startsAt > now && $0.event.startsAt.timeIntervalSince(now) <= Self.leadTime }
            .sorted { ($0.event.startsAt, $0.id) < ($1.event.startsAt, $1.id) }
            .map { Entry(meeting: $0, countdown: .startsIn(minutes: Int((($0.event.startsAt.timeIntervalSince(now)) / 60).rounded(.up)))) }
        let inProgress = meetings
            .filter { $0.event.contains(now) }
            .sorted { ($0.event.startsAt, $1.id) > ($1.event.startsAt, $0.id) }
            .map { Entry(meeting: $0, countdown: .inProgress) }
        return upcoming + inProgress
    }

    /// Every later moment at which `entries(at:)` changes: each minute of the countdown, the start, and the end.
    public func boundaries(after now: Date) -> [Date] {
        let minutes = Int(Self.leadTime / 60)
        let dates = meetings.flatMap { meeting in
            (1...minutes).map { meeting.event.startsAt.addingTimeInterval(-Double($0) * 60) }
                + [meeting.event.startsAt, meeting.event.endsAt]
        }
        return Set(dates.filter { $0 > now }).sorted()
    }

    /// Meetings in their last minute before the start that have no reminder yet.
    public func remindersDue(at now: Date, excluding sent: Set<String>) -> [JoinableMeeting] {
        meetings
            .filter { !sent.contains($0.id) && reminderTime($0) <= now && now < $0.event.startsAt }
            .sorted { ($0.event.startsAt, $0.id) < ($1.event.startsAt, $1.id) }
    }

    public func nextReminder(after now: Date) -> Date? {
        meetings.map(reminderTime).filter { $0 > now }.min()
    }

    private func reminderTime(_ meeting: JoinableMeeting) -> Date {
        meeting.event.startsAt.addingTimeInterval(-Self.reminderLeadTime)
    }
}
