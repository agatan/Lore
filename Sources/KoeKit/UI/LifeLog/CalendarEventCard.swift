import SwiftUI

/// 時刻、件名、細い罫線で予定を示す、main / mini 共通の表示。
struct CalendarEventCard: View {
    var event: CalendarEventSnapshot
    var isCurrent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Text(timeRange)
                    .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                if isCurrent {
                    Text("いま")
                        .font(.system(size: 8.5, weight: .bold, design: .rounded))
                        .foregroundStyle(KoeTheme.accent)
                }
            }
            .foregroundStyle(.primary.opacity(0.72))

            Text(event.title)
                .font(.system(size: 11, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            Text(event.calendarTitle)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 10)
        .padding(.vertical, 4)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(KoeTheme.accent.opacity(isCurrent ? 0.9 : 0.45))
                .frame(width: isCurrent ? 2 : 1)
        }
    }

    private var timeRange: String {
        if event.isAllDay { return "終日" }
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
                VStack(spacing: 0) {
                    CalendarEventCard(event: event, isCurrent: true)
                        .padding(8)
                    Divider().opacity(0.35)
                }
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
