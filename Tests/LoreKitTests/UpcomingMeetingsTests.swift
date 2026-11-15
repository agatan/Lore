import Foundation
import Testing
@testable import LoreKit

@Suite("Joining the next meeting")
struct UpcomingMeetingsTests {
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let meet = "Join: https://meet.google.com/abc-defg-hij"

    static func event(_ id: String, startsIn minutes: Double, length: Double = 30, allDay: Bool = false,
                      status: CalendarParticipationStatus = .accepted) -> CalendarEventSnapshot {
        let start = now.addingTimeInterval(minutes * 60)
        return CalendarEventSnapshot(id: id, title: id, startsAt: start, endsAt: start.addingTimeInterval(length * 60),
                                     calendarTitle: "Work", isAllDay: allDay, participationStatus: status)
    }

    static func meeting(_ id: String, startsIn minutes: Double, length: Double = 30) -> JoinableMeeting {
        let event = event(id, startsIn: minutes, length: length)
        return JoinableMeeting(event: event, details: CalendarEventDetails(eventID: id, startsAt: event.startsAt, notes: meet))!
    }

    @Test("Only a timed event with a link that is not canceled or declined can be joined", arguments: [
        ("timed, accepted, link", event("a", startsIn: 5), meet, false, true),
        ("no RSVP", event("a", startsIn: 5, status: .none), meet, false, true),
        ("tentative", event("a", startsIn: 5, status: .tentative), meet, false, true),
        ("pending", event("a", startsIn: 5, status: .pending), meet, false, true),
        ("declined", event("a", startsIn: 5, status: .declined), meet, false, false),
        ("canceled", event("a", startsIn: 5), meet, true, false),
        ("all-day", event("a", startsIn: 5, allDay: true), meet, false, false),
        ("no link", event("a", startsIn: 5), "Room 4A", false, false),
    ])
    func joinable(_ name: String, _ event: CalendarEventSnapshot, _ notes: String, _ canceled: Bool, _ expected: Bool) {
        let details = CalendarEventDetails(eventID: event.id, startsAt: event.startsAt, notes: notes, isCanceled: canceled)
        let meeting = JoinableMeeting(event: event, details: details)
        #expect((meeting != nil) == expected, "\(name)")
        if let meeting { #expect(meeting.link.url == URL(string: "https://meet.google.com/abc-defg-hij")) }
    }

    @Test("An event whose details are gone cannot be joined")
    func noDetails() {
        #expect(JoinableMeeting(event: Self.event("a", startsIn: 5), details: nil) == nil)
    }

    @Test("A meeting is offered from 10 minutes before its start until its end, counting down whole minutes rounded up")
    func countdown() {
        let meetings = UpcomingMeetings(meetings: [Self.meeting("a", startsIn: 10, length: 30)])
        func countdown(atMinute minute: Double) -> MeetingCountdown? {
            meetings.entries(at: Self.now.addingTimeInterval(minute * 60)).first?.countdown
        }
        #expect(countdown(atMinute: -0.01) == nil)
        #expect(countdown(atMinute: 0) == .startsIn(minutes: 10))
        #expect(countdown(atMinute: 0.01) == .startsIn(minutes: 10))
        #expect(countdown(atMinute: 7) == .startsIn(minutes: 3))
        #expect(countdown(atMinute: 7.5) == .startsIn(minutes: 3))
        #expect(countdown(atMinute: 9.99) == .startsIn(minutes: 1))
        #expect(countdown(atMinute: 10) == .inProgress)
        #expect(countdown(atMinute: 39.99) == .inProgress)
        #expect(countdown(atMinute: 40) == nil)
    }

    @Test("Overlapping meetings: the one to join next comes first, then those in progress, the latest start first")
    func order() {
        let meetings = UpcomingMeetings(meetings: [
            Self.meeting("started-long-ago", startsIn: -50, length: 60),
            Self.meeting("starts-later", startsIn: 8),
            Self.meeting("just-started", startsIn: -5, length: 60),
            Self.meeting("starts-soon", startsIn: 2),
            Self.meeting("too-far", startsIn: 11),
            Self.meeting("ended", startsIn: -40, length: 30),
        ])
        let entries = meetings.entries(at: Self.now)
        #expect(entries.map(\.meeting.event.id) == ["starts-soon", "starts-later", "just-started", "started-long-ago"])
        #expect(entries.map(\.countdown) == [.startsIn(minutes: 2), .startsIn(minutes: 8), .inProgress, .inProgress])
    }

    @Test("Meetings that start together are ordered the same way every time")
    func tie() {
        let a = Self.meeting("a", startsIn: 3), b = Self.meeting("b", startsIn: 3)
        #expect(UpcomingMeetings(meetings: [b, a]).entries(at: Self.now).map(\.meeting.event.id) == ["a", "b"])
        let c = Self.meeting("c", startsIn: -3), d = Self.meeting("d", startsIn: -3)
        #expect(UpcomingMeetings(meetings: [d, c]).entries(at: Self.now).map(\.meeting.event.id) == ["c", "d"])
    }

    @Test("Two occurrences of one repeating event are separate meetings")
    func occurrences() {
        let first = Self.meeting("weekly", startsIn: -40, length: 30)
        let second = Self.meeting("weekly", startsIn: 5)
        #expect(first.id != second.id)
        #expect(UpcomingMeetings(meetings: [first, second]).entries(at: Self.now).map(\.id) == [second.id])
    }

    @Test("The boundaries are exactly the moments at which the offers change")
    func boundaries() {
        let meetings = UpcomingMeetings(meetings: [Self.meeting("a", startsIn: 12, length: 30), Self.meeting("b", startsIn: 12, length: 15)])
        let start = Self.now.addingTimeInterval(12 * 60)
        let expected = (1...10).reversed().map { start.addingTimeInterval(-Double($0) * 60) }
            + [start, start.addingTimeInterval(15 * 60), start.addingTimeInterval(30 * 60)]
        #expect(meetings.boundaries(after: Self.now) == expected)

        // Between two boundaries nothing changes, and at each boundary something does.
        let all = [Self.now] + expected
        for (index, boundary) in expected.enumerated() {
            let before = meetings.entries(at: boundary.addingTimeInterval(-0.5))
            #expect(before == meetings.entries(at: all[index].addingTimeInterval(0.001)))
            #expect(before != meetings.entries(at: boundary))
        }
        #expect(meetings.boundaries(after: start.addingTimeInterval(30 * 60)).isEmpty)
    }

    @Test("A reminder is due once, in the minute before the start, and never after the start")
    func reminders() {
        let meetings = UpcomingMeetings(meetings: [Self.meeting("a", startsIn: 5), Self.meeting("b", startsIn: 20)])
        let aStart = Self.now.addingTimeInterval(5 * 60)
        #expect(meetings.nextReminder(after: Self.now) == aStart.addingTimeInterval(-60))
        #expect(meetings.remindersDue(at: Self.now, excluding: []).isEmpty)
        #expect(meetings.remindersDue(at: aStart.addingTimeInterval(-60), excluding: []).map(\.event.id) == ["a"])
        #expect(meetings.remindersDue(at: aStart.addingTimeInterval(-1), excluding: []).map(\.event.id) == ["a"])
        let sent: Set = [meetings.meetings[0].id]
        #expect(meetings.remindersDue(at: aStart.addingTimeInterval(-30), excluding: sent).isEmpty)
        #expect(meetings.remindersDue(at: aStart, excluding: []).isEmpty)
        #expect(meetings.nextReminder(after: aStart.addingTimeInterval(-60)) == Self.now.addingTimeInterval(19 * 60))
    }

    @MainActor
    @Test("Join opens exactly the meeting's link and leaves the Life Log stopped")
    func joinOpensOnlyTheLink() {
        let env = AppEnvironment()
        var opened: [URL] = []
        env.openURL = { opened.append($0); return true }
        let meeting = Self.meeting("a", startsIn: 1)
        let wasCapturing = env.lifeLog.hasCaptureIntent

        env.joinMeeting(meeting)

        #expect(opened == [URL(string: "https://meet.google.com/abc-defg-hij")!])
        #expect(env.lifeLog.hasCaptureIntent == wasCapturing)
        #expect(env.lifeLog.hold == nil)
        #expect(env.lifeLog.errorMessage == nil)
    }

    @MainActor
    @Test("A link that nothing can open is reported")
    func joinFailureIsShown() {
        let env = AppEnvironment()
        env.openURL = { _ in false }
        env.joinMeeting(Self.meeting("a", startsIn: 1))
        #expect(env.lifeLog.errorMessage != nil)
    }
}
