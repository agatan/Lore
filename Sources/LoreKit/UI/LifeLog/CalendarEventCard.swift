import SwiftUI

/// 予定はtimelineの縦線上の輪と、件名の見出しで描く。開始時刻は左の時刻列に任せ、
/// 見出しの下には長さとcalendar名だけを置く。区間の長さは縦線の色が示す。
struct CalendarEventCard: View {
    var event: CalendarEventSnapshot
    var above: LifeLogTimelineLayout.Segment = .none
    var below: LifeLogTimelineLayout.Segment = .none
    var isCurrent = false
    var compact = false

    private var titleSize: CGFloat { compact ? LoreTheme.TextSize.callout : LoreTheme.TextSize.reading }

    var body: some View {
        TimelineRowFrame(
            time: event.isAllDay ? Text("終日") : Text(event.startsAt.formatted(date: .omitted, time: .shortened)),
            node: .event,
            nodeLabel: "予定",
            above: above,
            below: below,
            topPadding: compact ? 8 : 14,
            bottomPadding: compact ? 5 : 8,
            firstLineCenter: titleSize * 0.62,
            compact: compact
        ) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Text(event.title)
                        .font(.system(size: titleSize, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if isCurrent {
                        Text("いま")
                            .font(.system(size: LoreTheme.TextSize.micro, weight: .semibold))
                            .foregroundStyle(LoreTheme.event)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(LoreTheme.event.opacity(0.14), in: Capsule())
                    }
                }
                detail
                    .font(LoreTheme.captionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.leading, compact ? 4 : 6)
        }
        .padding(.trailing, compact ? 12 : 8)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var detail: Text {
        guard !event.isAllDay else { return Text(verbatim: event.calendarTitle) }
        return Self.durationText(event.endsAt.timeIntervalSince(event.startsAt)) + Text(verbatim: " · \(event.calendarTitle)")
    }

    /// 「30分」「1時間」「1時間30分」。表示言語の書式で返す。
    static func durationText(_ interval: TimeInterval) -> Text {
        let minutes = max(0, Int((interval / 60).rounded()))
        let hours = minutes / 60
        let rest = minutes % 60
        if hours == 0 { return Text("\(rest)分") }
        return rest == 0 ? Text("\(hours)時間") : Text("\(hours)時間\(rest)分")
    }
}

/// 現在進行中の予定をscroll領域の外に置き、main / miniで同じ時刻判定を使う。
struct CurrentCalendarEventStrip: View {
    var events: [CalendarEventSnapshot]
    var selectedDate: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            if Calendar.current.isDateInToday(selectedDate), let event = currentEvent(at: context.date) {
                CalendarEventCard(event: event, isCurrent: true, compact: true)
                    .padding(.bottom, 6)
            }
        }
    }

    private func currentEvent(at date: Date) -> CalendarEventSnapshot? {
        events
            .filter { !$0.isAllDay && $0.contains(date) }
            .sorted { $0.startsAt < $1.startsAt }
            .first
    }
}
