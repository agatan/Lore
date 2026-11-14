import SwiftUI

struct LifeLogCalendarSettingsView: View {
    var env: AppEnvironment

    private var settings: AppSettings { env.settings }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(
                title: "表示する予定",
                footnote: "選んだカレンダーの予定を、タイムラインと「この日」の一日の流れに並べます。"
            ) {
                SettingsToggle(
                    title: "参加する予定だけ",
                    caption: "参加済みと、返答のない自分の予定を含めます。Loreから参加可否は変更できません。",
                    isOn: Binding(
                        get: { settings.lifeLogParticipatingEventsOnly },
                        set: { value in
                            settings.lifeLogParticipatingEventsOnly = value
                            Task { await env.lifeLog.calendarFilterChanged() }
                        }
                    )
                )
                calendars
                SettingsRow(
                    title: "予定を再取得",
                    caption: "\(env.lifeLog.selectedDate.formatted(.dateTime.year().month().day()))の予定をCalendarから読み直します"
                ) {
                    Button {
                        Task { await env.lifeLog.refreshCalendar(selectedCalendars: selectedCalendars) }
                    } label: {
                        if env.lifeLog.isRefreshingCalendar {
                            ProgressView().controlSize(.small)
                        } else {
                            Label("再取得", systemImage: "arrow.clockwise")
                        }
                    }
                    .disabled(env.lifeLog.isRefreshingCalendar)
                    .accessibilityIdentifier("calendar.refresh")
                }
                if let refreshedAt = env.lifeLog.lastCalendarRefreshAt {
                    Text("最終取得: \(refreshedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .accessibilityIdentifier("calendar.settings.root")
        .toggleStyle(.switch)
        .task { await env.lifeLog.loadCalendars() }
    }

    @ViewBuilder
    private var calendars: some View {
        if env.lifeLog.availableCalendars.isEmpty {
            Label("利用できるカレンダーがありません", systemImage: "calendar.badge.exclamationmark")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                Text(selectionSummary)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("すべて") { selectAllCalendars() }
                    .buttonStyle(.borderless)
                    .disabled(settings.lifeLogCalendarTitles.isEmpty)
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                ForEach(Array(stride(from: 0, to: env.lifeLog.availableCalendars.count, by: 2)), id: \.self) { index in
                    GridRow {
                        calendarButton(env.lifeLog.availableCalendars[index])
                        if index + 1 < env.lifeLog.availableCalendars.count {
                            calendarButton(env.lifeLog.availableCalendars[index + 1])
                        } else {
                            Color.clear.frame(height: 36)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var selectedCalendars: Set<String> {
        settings.lifeLogCalendarTitles.isEmpty
            ? Set(env.lifeLog.availableCalendars)
            : Set(settings.lifeLogCalendarTitles)
    }

    private var selectionSummary: String {
        settings.lifeLogCalendarTitles.isEmpty ? "すべてのカレンダー" : "\(selectedCalendars.count)件を表示"
    }

    private func calendarButton(_ title: String) -> some View {
        let isSelected = selectedCalendars.contains(title)
        return Button { toggleCalendar(title) } label: {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? LoreTheme.accent : Color.secondary.opacity(0.45))
                Text(title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .background(isSelected ? LoreTheme.accent.opacity(0.10) : Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? LoreTheme.accent.opacity(0.28) : Color.secondary.opacity(0.08), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isSelected && selectedCalendars.count == 1)
    }

    private func toggleCalendar(_ title: String) {
        var selected = selectedCalendars
        if selected.contains(title) {
            guard selected.count > 1 else { return }
            selected.remove(title)
        } else {
            selected.insert(title)
        }
        settings.lifeLogCalendarTitles = selected.count == env.lifeLog.availableCalendars.count ? [] : selected.sorted()
        Task { await env.lifeLog.refreshCalendar(selectedCalendars: selected) }
    }

    private func selectAllCalendars() {
        settings.lifeLogCalendarTitles = []
        Task { await env.lifeLog.refreshCalendar(selectedCalendars: Set(env.lifeLog.availableCalendars)) }
    }
}
