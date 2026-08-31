import SwiftUI

struct LifeLogCalendarEventList: View {
    var events: [CalendarEventSnapshot]
    var onSelect: (CalendarEventSnapshot) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("この日の予定")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            Divider()
            if sortedEvents.isEmpty {
                ContentUnavailableView("予定はありません", systemImage: "calendar")
                    .frame(width: 320, height: 180)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(sortedEvents) { event in
                            Button { onSelect(event) } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    Text(timeLabel(for: event))
                                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 88, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack(spacing: 6) {
                                            Text(event.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .lineLimit(2)
                                            if event.contains(Date()) {
                                                Text("いま")
                                                    .font(.system(size: 10, weight: .semibold))
                                                    .foregroundStyle(KoeTheme.accent)
                                            }
                                        }
                                        Text(event.calendarTitle)
                                            .font(.system(size: 11))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                }
                                .padding(.horizontal, 4)
                                .padding(.vertical, 9)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("life-log.calendar-event-\(event.id)")
                            Divider()
                        }
                    }
                    .padding(10)
                }
                .frame(width: 340, height: min(420, CGFloat(sortedEvents.count * 82 + 20)))
            }
        }
    }

    private var sortedEvents: [CalendarEventSnapshot] {
        events.sorted { $0.startsAt < $1.startsAt }
    }

    private func timeLabel(for event: CalendarEventSnapshot) -> String {
        guard !event.isAllDay else { return "終日" }
        let start = event.startsAt.formatted(date: .omitted, time: .shortened)
        let end = event.endsAt.formatted(date: .omitted, time: .shortened)
        return "\(start)–\(end)"
    }
}
