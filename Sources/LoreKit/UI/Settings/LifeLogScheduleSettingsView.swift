import SwiftUI

/// 決まった曜日と時間帯だけライフログを自動で記録する設定。
struct LifeLogScheduleSettingsView: View {
    var env: AppEnvironment
    private var schedule: LifeLogSchedule { env.settings.lifeLogSchedule }

    /// 日曜始まり。値は`Calendar`のweekday(1=日)。
    private static let weekdays: [(value: Int, label: String)] = [
        (1, "日"), (2, "月"), (3, "火"), (4, "水"), (5, "木"), (6, "金"), (7, "土"),
    ]

    var body: some View {
        SettingsCard(
            title: "自動記録",
            footnote: schedule.isEnabled
                ? "時間帯の終わりに止まるのは、自動で始めた記録だけです。途中で手動で止めると、次の時間帯まで再開しません。"
                : nil
        ) {
            SettingsRow(title: "決まった時間に記録する", detail: captionText) {
                Toggle("", isOn: binding(\.isEnabled))
                    .labelsHidden()
                    .accessibilityIdentifier("life-log.schedule.enabled")
            }
            if schedule.isEnabled {
                SettingsRow(title: "曜日") {
                    HStack(spacing: 4) {
                        ForEach(Self.weekdays, id: \.value) { day in
                            weekdayButton(day.value, label: day.label)
                        }
                    }
                }
                SettingsRow(title: "時間帯", caption: schedule.endMinute <= schedule.startMinute ? "終了は翌日の時刻です" : nil) {
                    HStack(spacing: 6) {
                        timePicker(\.startMinute, identifier: "life-log.schedule.start")
                        Text(verbatim: "–").foregroundStyle(.secondary)
                        timePicker(\.endMinute, identifier: "life-log.schedule.end")
                    }
                }
            }
        }
    }

    private var captionText: LocalizedStringKey? {
        guard schedule.isEnabled else { return nil }
        let now = Date()
        if let window = schedule.window(containing: now) {
            return "現在の時間帯は\(AppEnvironment.scheduleTimeText(window.end, now: now))までです"
        }
        guard let next = schedule.nextWindow(after: now) else { return "曜日を選んでください" }
        return "次は\(AppEnvironment.scheduleTimeText(next.start, now: now))から\(AppEnvironment.scheduleTimeText(next.end, now: next.start))まで"
    }

    private func weekdayButton(_ value: Int, label: String) -> some View {
        let selected = schedule.weekdays.contains(value)
        return Button {
            var updated = schedule
            if selected { updated.weekdays.remove(value) } else { updated.weekdays.insert(value) }
            env.updateLifeLogSchedule(updated)
        } label: {
            Text(LocalizedStringKey(label))
                .font(.system(size: LoreTheme.TextSize.caption, weight: selected ? .semibold : .regular))
                .frame(width: 26, height: 22)
                .foregroundStyle(selected ? LoreTheme.onAccent : Color.primary)
                .background {
                    Capsule().fill(selected ? LoreTheme.accent : Color.primary.opacity(0.06))
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(label))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("life-log.schedule.weekday-\(value)")
    }

    private func timePicker(_ keyPath: WritableKeyPath<LifeLogSchedule, Int>, identifier: String) -> some View {
        DatePicker(
            "",
            selection: Binding(
                get: {
                    let minute = schedule[keyPath: keyPath]
                    return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
                },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    var updated = schedule
                    updated[keyPath: keyPath] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                    env.updateLifeLogSchedule(updated)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .datePickerStyle(.field)
        .fixedSize()
        .accessibilityIdentifier(identifier)
    }

    private func binding(_ keyPath: WritableKeyPath<LifeLogSchedule, Bool>) -> Binding<Bool> {
        Binding(
            get: { schedule[keyPath: keyPath] },
            set: { value in
                var updated = schedule
                updated[keyPath: keyPath] = value
                env.updateLifeLogSchedule(updated)
            }
        )
    }
}
