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
                .font(.system(size: LoreTheme.TextSize.reading, weight: .semibold))
            Spacer()
            Button { moveMonth(-1) } label: { Image(systemName: "chevron.left") }
                .help("前の月")
            Button("今日") {
                let today = Date()
                displayedMonth = calendar.dateInterval(of: .month, for: today)?.start ?? today
                onMonthChanged(displayedMonth)
                onSelect(today)
            }
            .font(.system(size: LoreTheme.TextSize.caption, weight: .medium))
            Button { moveMonth(1) } label: { Image(systemName: "chevron.right") }
                .help("次の月")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
    }

    private var weekdayHeader: some View {
        HStack(spacing: 3) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.system(size: LoreTheme.TextSize.micro, weight: .medium))
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
                    .font(.system(size: LoreTheme.TextSize.callout, weight: today || selected ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(selected ? (today ? Color.white : LoreTheme.onAccent) : (today ? LoreTheme.recording : Color.primary))
                    .frame(width: 26, height: 26)
                    .background {
                        if selected {
                            Circle().fill(today ? LoreTheme.recording : LoreTheme.accent)
                        }
                    }
                HStack(spacing: 2) {
                    densityDot(intensity: value.eventIntensity, color: LoreTheme.event)
                    densityDot(intensity: value.voiceIntensity, color: LoreTheme.accent)
                }
                .frame(height: 5)
            }
            .frame(maxWidth: .infinity, minHeight: 36)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    private func densityDot(intensity: Double, color: Color) -> some View {
        Circle()
            .fill(intensity > 0 ? color.opacity(0.4 + intensity * 0.6) : .clear)
            .frame(width: 4, height: 4)
            .frame(width: 5, height: 5)
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
