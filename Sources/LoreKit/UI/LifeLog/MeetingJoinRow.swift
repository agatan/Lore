import SwiftUI

/// Redraws the offered meetings only at the boundaries where they change, without reading the database.
struct UpcomingMeetingsTimeline<Content: View>: View {
    var meetings: UpcomingMeetings
    /// Other moments that change the content, such as the end of the event in progress.
    var extraBoundaries: [Date] = []
    @ViewBuilder var content: (Date, [UpcomingMeetings.Entry]) -> Content

    var body: some View {
        let now = Date()
        let boundaries = Set(meetings.boundaries(after: now) + extraBoundaries.filter { $0 > now })
        TimelineView(.explicit([now] + boundaries.sorted())) { context in
            content(context.date, meetings.entries(at: context.date))
        }
    }
}

/// One offered meeting: the title, the countdown, and "Join". The mini window and the menu bar panel share it.
struct MeetingJoinRow: View {
    var entry: UpcomingMeetings.Entry
    var accessibilityPrefix: String
    var join: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "video.fill")
                .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
                .foregroundStyle(LoreTheme.event)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.meeting.event.title)
                    .font(.system(size: LoreTheme.TextSize.callout, weight: .semibold))
                    .lineLimit(1)
                    .accessibilityIdentifier("\(accessibilityPrefix).title")
                MeetingCountdownText(countdown: entry.countdown)
                    .font(LoreTheme.captionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(accessibilityPrefix).countdown")
            }
            Spacer(minLength: 0)
            MeetingJoinButton(accessibilityIdentifier: "\(accessibilityPrefix).join", action: join)
        }
    }
}

struct MeetingCountdownText: View {
    var countdown: MeetingCountdown

    var body: some View {
        switch countdown {
        case .startsIn(let minutes): Text("\(minutes)分後")
        case .inProgress: Text("いま")
        }
    }
}

struct MeetingJoinButton: View {
    var accessibilityIdentifier: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("参加", systemImage: "video")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .help("会議のリンクを開く")
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}
