import SwiftUI

/// 予定の開始・終了範囲を一つの色面として示す、main / mini 共通の表示。
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
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.28), in: Capsule())
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
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(tint.opacity(isCurrent ? 0.34 : 0.20), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(tint.opacity(isCurrent ? 0.82 : 0.38), lineWidth: isCurrent ? 1.5 : 1)
        }
    }

    private var timeRange: String {
        "\(event.startsAt.formatted(date: .omitted, time: .shortened))–\(event.endsAt.formatted(date: .omitted, time: .shortened))"
    }

    private var tint: Color {
        KoeTheme.accent
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
