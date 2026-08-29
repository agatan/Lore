import SwiftUI

/// 予定と発話の「量」を読むための月間カレンダー。日付セルに説明や件数を置かず、
/// 予定はシアン、発話はインディゴのdotとして密度だけを伝える。
struct MonthActivityCalendar: View {
    @Binding var selectedDate: Date
    var activity: [String: LifeLogDayActivity]
    var onSelect: (Date) -> Void
    var onMonthChanged: (Date) -> Void

    @State private var displayedMonth: Date
    private let calendar = Calendar.current

    init(
        selectedDate: Binding<Date>,
        activity: [String: LifeLogDayActivity],
        onSelect: @escaping (Date) -> Void,
        onMonthChanged: @escaping (Date) -> Void
    ) {
        _selectedDate = selectedDate
        self.activity = activity
        self.onSelect = onSelect
        self.onMonthChanged = onMonthChanged
        _displayedMonth = State(initialValue: Calendar.current.dateInterval(of: .month, for: selectedDate.wrappedValue)?.start ?? selectedDate.wrappedValue)
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            weekdayHeader
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 7), spacing: 5) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, date in
                    if let date { dayCell(date) } else { Color.clear.frame(height: 38) }
                }
            }
        }
        .onChange(of: selectedDate) { _, value in
            guard let month = calendar.dateInterval(of: .month, for: value)?.start,
                  !calendar.isDate(month, equalTo: displayedMonth, toGranularity: .month) else { return }
            displayedMonth = month
            onMonthChanged(month)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(displayedMonth.formatted(.dateTime.year().month(.wide)))
                .font(.system(size: 15, weight: .semibold, design: .rounded))
            Spacer()
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
            Button {
                let today = Date()
                displayedMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
                onMonthChanged(displayedMonth)
                onSelect(today)
            } label: { Image(systemName: "scope") }
            .help("今日")
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
    }

    private var weekdayHeader: some View {
        HStack(spacing: 3) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let value = activity[LifeLogDateKey.string(for: date)] ?? LifeLogDayActivity()
        let selected = calendar.isDate(date, inSameDayAs: selectedDate)
        let today = calendar.isDateInToday(date)
        return Button { onSelect(date) } label: {
            VStack(spacing: 3) {
                Text(String(calendar.component(.day, from: date)))
                    .font(.system(size: 11.5, weight: today ? .bold : .medium, design: .rounded))
                    .foregroundStyle(today ? KoeTheme.accentSecondary : .primary)
                HStack(spacing: 3) {
                    densityDot(intensity: value.eventIntensity, color: KoeTheme.accentSecondary)
                    densityDot(intensity: value.voiceIntensity, color: KoeTheme.accent)
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 38)
            .contentShape(.rect)
            .overlay {
                if today {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(KoeTheme.accentSecondary.opacity(0.8), lineWidth: 1.5)
                }
            }
            .glassEffect(
                selected ? .regular.tint(KoeTheme.accent.opacity(0.24)).interactive() : .identity,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private func densityDot(intensity: Double, color: Color) -> some View {
        Circle()
            .fill(intensity > 0 ? color.opacity(0.35 + intensity * 0.65) : .clear)
            .frame(width: 3 + intensity * 3, height: 3 + intensity * 3)
            .frame(width: 7, height: 7)
    }

    private var days: [Date?] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth),
              let range = calendar.range(of: .day, in: .month, for: displayedMonth) else { return [] }
        let weekday = calendar.component(.weekday, from: interval.start)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        return Array(repeating: nil, count: leading) + range.compactMap {
            calendar.date(byAdding: .day, value: $0 - 1, to: interval.start)
        }
    }

    private var weekdaySymbols: [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let start = max(0, calendar.firstWeekday - 1)
        return Array(symbols[start...] + symbols[..<start])
    }

    private func moveMonth(_ value: Int) {
        guard let next = calendar.date(byAdding: .month, value: value, to: displayedMonth) else { return }
        displayedMonth = calendar.dateInterval(of: .month, for: next)?.start ?? next
        onMonthChanged(displayedMonth)
    }
}
