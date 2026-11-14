import SwiftUI

struct LifeLogCalendarSettingsView: View {
    var env: AppEnvironment

    private var settings: AppSettings { env.settings }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(
                title: "表示する予定",
                footnote: "選んだカレンダーの予定を、ライフログのタイムラインに表示します。"
            ) {
                SettingsToggle(
                    title: "参加する予定だけ",
                    caption: "承諾した予定と、まだ返答していない予定を表示します",
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
                    detail: "\(env.lifeLog.selectedDate.loreFormatted(.dateTime.year().month().day()))の予定をカレンダーから読み込み直します"
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
                    Text("最終取得: \(refreshedAt.loreFormatted(date: .omitted, time: .shortened))")
                        .font(.system(size: LoreTheme.TextSize.caption))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .accessibilityIdentifier("calendar.settings.root")
        .toggleStyle(.switch)
        .task {
            env.refreshPermissions()
            if env.isCalendarGranted { await env.lifeLog.loadCalendars() }
        }
    }

    @ViewBuilder
    private var calendars: some View {
        if !env.isCalendarGranted {
            SettingsRow(title: "カレンダーへのアクセスが許可されていません", caption: "許可すると、予定をタイムラインに表示できます") {
                Button("許可する") { Task { await env.requestCalendar() } }
                    .accessibilityIdentifier("calendar.request-access")
            }
        } else if env.lifeLog.availableCalendars.isEmpty {
            Label("カレンダーがありません", systemImage: "calendar.badge.exclamationmark")
                .font(.system(size: LoreTheme.TextSize.caption))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack {
                Text(selectionSummary)
                    .font(.system(size: LoreTheme.TextSize.caption, weight: .medium))
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

    private var selectionSummary: LocalizedStringKey {
        settings.lifeLogCalendarTitles.isEmpty ? "すべてのカレンダー" : "\(selectedCalendars.count)件を表示"
    }

    private func calendarButton(_ title: String) -> some View {
        let isSelected = selectedCalendars.contains(title)
        return Button { toggleCalendar(title) } label: {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? LoreTheme.accent : Color.secondary.opacity(0.45))
                Text(title).font(.system(size: LoreTheme.TextSize.caption, weight: .medium)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
            .background(isSelected ? LoreTheme.accent.opacity(0.10) : Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius)
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
