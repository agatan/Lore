import SwiftUI

/// 時刻、件名、細い罫線で予定を示す、main / mini 共通の表示。
struct CalendarEventCard: View {
    var event: CalendarEventSnapshot
    var isCurrent = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(KoeTheme.accentSecondary.opacity(isCurrent ? 1 : 0.7))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .fixedSize(horizontal: false, vertical: true)
                    if isCurrent {
                        Text("いま")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(KoeTheme.accentSecondary)
                    }
                }
                Text("\(timeRange) · \(event.calendarTitle)")
                    .font(KoeTheme.captionFont.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            KoeTheme.accentSecondary.opacity(isCurrent ? 0.12 : 0.06),
            in: RoundedRectangle(cornerRadius: KoeTheme.cardCornerRadius, style: .continuous)
        )
        .fixedSize(horizontal: false, vertical: true)
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
