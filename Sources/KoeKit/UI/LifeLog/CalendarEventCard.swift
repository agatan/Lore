import SwiftUI

/// 予定はtimelineを区切る静かな見出し行として描く。塗りは使わず、calendar色の小さな印と
/// 文字の強弱だけで発話と区別する。時刻の列は`TimelineEntryRow`と揃える。
struct CalendarEventCard: View {
    var event: CalendarEventSnapshot
    var isCurrent = false
    var compact = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 10 : 14) {
            Group {
                if event.isAllDay { Text("終日") } else { Text(event.startsAt.formatted(date: .omitted, time: .shortened)) }
            }
                .font(KoeTheme.timeFont)
                .foregroundStyle(.secondary)
                .frame(width: compact ? 52 : 60, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(KoeTheme.accentSecondary)
                        .frame(width: 7, height: 7)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    Text(event.title)
                        .font(.system(size: compact ? 12.5 : 13, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if isCurrent {
                        Text("いま")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(KoeTheme.accentSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(KoeTheme.accentSecondary.opacity(0.14), in: Capsule())
                    }
                }
                Text(verbatim: event.isAllDay ? event.calendarTitle : "\(timeRange) · \(event.calendarTitle)")
                    .font(KoeTheme.captionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.leading, 14)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.top, compact ? 10 : 18)
        .padding(.bottom, compact ? 4 : 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var timeRange: String {
        return "\(event.startsAt.formatted(date: .omitted, time: .shortened))–\(event.endsAt.formatted(date: .omitted, time: .shortened))"
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
