import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct LifeLogWindow: View {
    var env: AppEnvironment
    @State private var exportError: String?
    @State private var showsExportSheet = false
    @State private var showsSearchSheet = false
    @State private var showsCalendarEvents = false
    @State private var timelineIsAtBottom = true
    @State private var timelineFollowsLatest = true
    @State private var memoDraft = ""

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        HStack(spacing: 10) {
            left.frame(width: 288)
            timeline.frame(minWidth: 520, maxWidth: .infinity)
            right.frame(width: 320)
        }
        .padding(10)
        .frame(minWidth: 1_120, minHeight: 680)
        .task {
            await env.lifeLog.followCurrentDay()
            await env.lifeLog.loadActivity(containing: env.lifeLog.selectedDate)
            if !AppEnvironment.usesScreenshotDemoData {
                await env.lifeLog.refreshCalendarIfNeeded(selectedCalendars: Set(env.settings.lifeLogCalendarTitles))
            }
        }
        .sheet(isPresented: $showsExportSheet) {
            LifeLogExportSheet(
                date: env.lifeLog.selectedDate,
                day: env.lifeLog.day,
                todos: env.lifeLog.todos,
                onExport: exportSelectedDay
            )
        }
        .sheet(isPresented: $showsSearchSheet) {
            LifeLogSearchSheet(env: env)
        }
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonthActivityCalendar(
                selectedDate: Binding(get: { env.lifeLog.selectedDate }, set: { _ in }),
                activity: env.lifeLog.monthActivity,
                onSelect: { date in
                    Task {
                        await env.lifeLog.select(date: date)
                        if !AppEnvironment.usesScreenshotDemoData {
                            await env.lifeLog.refreshCalendar(selectedCalendars: Set(env.settings.lifeLogCalendarTitles))
                        }
                    }
                },
                onMonthChanged: { date in Task { await env.lifeLog.loadActivity(containing: date) } }
            )
            .padding(14)
            Divider().opacity(0.6)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    daySummary
                    dayRhythm
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .panelSurface()
    }

    private var daySummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                sectionLabel("まとめ")
                if let summary = env.lifeLog.day.summary, summary.isFinal {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(KoeTheme.success)
                        .help("確定済み")
                }
                Spacer()
                Button {
                    Task { await env.lifeLog.refreshSelectedDaySummary() }
                } label: {
                    if env.lifeLog.isDeriving {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise").font(.system(size: 11))
                    }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(env.lifeLog.isDeriving || !hasSummarySource)
                .help("要約とTODO案を更新")
                .accessibilityLabel("要約とTODO案を更新")
                .accessibilityIdentifier("life-log.refresh-summary")
            }
            if let summary = env.lifeLog.day.summary {
                LifeLogMarkdownSummary(markdown: summary.summary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !summary.topics.isEmpty {
                    FlowLayout(spacing: 5) {
                        ForEach(summary.topics, id: \.self) { topic in
                            Text(topic)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            } else {
                Text(hasSummarySource ? "更新するとこの日の要約を作ります" : "記録が増えると要約を作ります")
                    .font(KoeTheme.captionFont)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var dayRhythm: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("時間帯")
            DayRhythmView(day: env.lifeLog.day)
                .frame(height: 52)
        }
        .accessibilityIdentifier("life-log.day-insights")
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(LocalizedStringKey(title))
            .font(KoeTheme.sectionFont)
            .foregroundStyle(.secondary)
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            PanelHeader(
                title: env.lifeLog.selectedDate.formatted(.dateTime.month(.abbreviated).day().weekday(.wide)),
                subtitle: timelineSubtitle
            ) {
                HStack(spacing: 14) {
                    Button { showsCalendarEvents = true } label: { Image(systemName: "calendar") }
                        .help("この日の予定")
                        .accessibilityLabel("この日の予定")
                        .accessibilityIdentifier("life-log.calendar-events")
                        .popover(isPresented: $showsCalendarEvents, arrowEdge: .top) {
                            LifeLogCalendarEventList(
                                events: env.lifeLog.day.calendarEvents,
                                onSelect: { event in
                                    showsCalendarEvents = false
                                    Task { await env.lifeLog.jumpToTime(event.startsAt) }
                                }
                            )
                        }
                    Button { showsSearchSheet = true } label: { Image(systemName: "magnifyingglass") }
                        .help("ライフログを検索 (⌘F)")
                        .accessibilityLabel("ライフログを検索")
                        .keyboardShortcut("f", modifiers: .command)
                        .accessibilityIdentifier("life-log.search")
                    Button { showsExportSheet = true } label: { Image(systemName: "square.and.arrow.up") }
                        .help("この日を書き出す")
                        .accessibilityLabel("この日を書き出す")
                        .accessibilityIdentifier("life-log.export-day")
                }
                .font(.system(size: 13))
            }
            Divider().opacity(0.6)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(timelineItems, id: \.id) { item in
                            timelineRow(item)
                        }
                        Color.clear.frame(height: 1).id("timeline-bottom")
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: env.lifeLog.sourceNavigationRevision) { _, _ in
                    guard let id = env.lifeLog.highlightedTimelineItemID else { return }
                    timelineFollowsLatest = false
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
                .onChange(of: timelineItems.last?.id) { _, _ in
                    guard timelineFollowsLatest else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("timeline-bottom", anchor: .bottom)
                        }
                    }
                }
                .task {
                    await Task.yield()
                    proxy.scrollTo("timeline-bottom", anchor: .bottom)
                }
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    LifeLogTimelineScrollPolicy.isAtBottom(
                        contentOffsetY: geometry.contentOffset.y,
                        contentHeight: geometry.contentSize.height,
                        containerHeight: geometry.containerSize.height
                    )
                } action: { _, isAtBottom in
                    timelineIsAtBottom = isAtBottom
                }
                .onScrollPhaseChange { oldPhase, newPhase in
                    guard oldPhase.isScrolling, newPhase == .idle else { return }
                    timelineFollowsLatest = timelineIsAtBottom
                }
                .overlay { if timelineItems.isEmpty { timelineEmptyState } }
            }
            if let error = env.lifeLog.errorMessage {
                NoticeBanner(
                    title: "ライフログを継続しています",
                    message: error,
                    tint: KoeTheme.warning,
                    actionTitle: nil,
                    action: nil,
                    onDismiss: env.lifeLog.dismissError
                )
                .padding(8)
                .accessibilityIdentifier("life-log.notice")
            }
            if let startedAt = env.lifeLog.liveActivityStartedAt {
                Divider().opacity(0.6)
                LifeLogTranscriptionProgressRow(
                    startedAt: startedAt,
                    audioDuration: env.lifeLog.liveActivityAudioDuration,
                    isListening: env.lifeLog.isHearingSpeech,
                    transcript: env.lifeLog.liveTranscript
                )
            }
            Divider().opacity(0.6)
            LifeLogCaptureControl(
                lifeLog: env.lifeLog,
                accessibilityIdentifier: "life-log.capture-toggle"
            ) {
                setCaptureEnabled(!env.lifeLog.hasCaptureIntent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            if Calendar.current.isDateInToday(env.lifeLog.selectedDate) {
                LifeLogMemoComposer(
                    text: $memoDraft,
                    accessibilityPrefix: "life-log",
                    isVoiceMemoRecording: env.coordinator.isVoiceMemoRecording,
                    isPreparingVoiceMemo: env.isPreparingVoiceMemo,
                    canToggleVoiceMemo: env.canToggleVoiceMemo,
                    voiceMemoShortcut: env.settings.voiceMemoHotkey.displayName,
                    onToggleVoiceMemo: env.toggleVoiceMemo
                ) { value in
                    Task { await env.lifeLog.addMemo(value) }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .panelSurface()
    }

    private var timelineSubtitle: String? {
        let day = env.lifeLog.day
        let count = day.utterances.count + day.dictations.count + day.memos.count
        return count == 0 ? nil : "\(count)件"
    }

    private var timelineEmptyState: some View {
        ContentUnavailableView {
            Label(
                env.lifeLog.hasCaptureIntent ? "発話を待っています" : "この日の記録はありません",
                systemImage: env.lifeLog.hasCaptureIntent ? "waveform" : "text.bubble"
            )
        } description: {
            if !env.lifeLog.hasCaptureIntent, Calendar.current.isDateInToday(env.lifeLog.selectedDate) {
                Text("記録を開始すると、話した内容がここに時刻順で並びます。")
            }
        }
        .foregroundStyle(.secondary)
    }

    private func timelineRow(_ item: TimelineItem) -> some View {
        activityCell(item)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        .id(item.id)
    }

    @ViewBuilder
    private func activityCell(_ item: TimelineItem) -> some View {
        switch item.kind {
        case .utterance(let value):
            TimelineEntryRow(
                date: value.startedAt,
                kind: .utterance,
                text: value.text,
                isHighlighted: env.lifeLog.highlightedTimelineItemID == "u-\(value.id)"
            )
        case .event(let value):
            CalendarEventCard(event: value)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .accessibilityIdentifier("life-log.timeline-event-\(value.id)")
        case .dictation(let value):
            TimelineEntryRow(date: value.startedAt, kind: .dictation, text: value.text)
        case .memo(let value):
            TimelineEntryRow(
                date: value.createdAt,
                kind: .memo,
                text: value.text,
                isHighlighted: env.lifeLog.highlightedTimelineItemID == "m-\(value.id)",
                onDelete: { Task { await env.lifeLog.deleteMemo(id: value.id) } }
            )
        }
    }

    private var right: some View {
        todoPanel
            .alert("書き出せませんでした", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("閉じる") { exportError = nil }
            } message: {
                Text(exportError ?? "不明なエラー")
            }
    }

    private var todoPanel: some View {
        VStack(spacing: 0) {
            PanelHeader(title: "TODO", subtitle: openTodoCount > 0 ? "\(openTodoCount)件" : nil) {
                HStack(spacing: 14) {
                    Button {
                        env.onShowLifeLogTodos?()
                    } label: {
                        Image(systemName: "list.bullet")
                    }
                    .help("すべてのTODO")
                    .accessibilityLabel("すべてのTODO")
                    .accessibilityIdentifier("life-log.open-all-todos")
                    Menu {
                        Button("未実施TODOをコピー", systemImage: "doc.on.clipboard") {
                            exportOpenTodos(to: .clipboard)
                        }
                        Button("未実施TODOを保存…", systemImage: "doc.badge.arrow.up") {
                            exportOpenTodos(to: .file)
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .tint(.secondary)
                    .fixedSize()
                    .help("すべての未実施TODOを書き出す")
                }
                .font(.system(size: 13))
            }
            Divider().opacity(0.6)
            if visibleTodos.isEmpty {
                ContentUnavailableView {
                    Label("未実施のTODOはありません", systemImage: "checkmark.circle")
                } description: {
                    Text("要約を更新すると、会話からTODO案を提案します。")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleTodos) { todo in
                            todoRow(todo)
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
        }
        .panelSurface()
    }

    private var openTodoCount: Int {
        env.lifeLog.todos.filter { $0.status == .open }.count
    }

    private func todoRow(_ todo: LifeLogTodo) -> some View {
        LifeLogTodoRow(
            todo: todo,
            title: todoTitle(todo),
            onToggle: { toggle(todo) },
            onConfirm: { confirm(todo) },
            onDelete: { Task { await env.lifeLog.delete(todoID: todo.id) } }
        )
    }

    private var visibleTodos: [LifeLogTodo] {
        env.lifeLog.todos.filter { $0.status != .completed }
    }

    private var hasSummarySource: Bool {
        !env.lifeLog.day.utterances.isEmpty
            || !env.lifeLog.day.memos.isEmpty
            || !env.lifeLog.day.calendarEvents.isEmpty
    }

    private enum ItemKind {
        case event(CalendarEventSnapshot)
        case utterance(LifeLogUtterance)
        case dictation(LifeLogDictation)
        case memo(LifeLogMemo)
    }
    private struct TimelineItem { var id: String; var date: Date; var kind: ItemKind }
    private var timelineItems: [TimelineItem] {
        (env.lifeLog.day.calendarEvents.map { TimelineItem(id: "e-\($0.id)", date: $0.startsAt, kind: .event($0)) }
         + env.lifeLog.day.utterances.map { TimelineItem(id: "u-\($0.id)", date: $0.startedAt, kind: .utterance($0)) }
         + env.lifeLog.day.dictations.map { TimelineItem(id: "d-\($0.id)", date: $0.startedAt, kind: .dictation($0)) }
         + env.lifeLog.day.memos.map { TimelineItem(id: "m-\($0.id)", date: $0.createdAt, kind: .memo($0)) })
            .sorted { $0.date < $1.date }
    }

    private func setCaptureEnabled(_ enabled: Bool) {
        env.setLifeLogCaptureEnabled(enabled)
    }

    private func toggle(_ todo: LifeLogTodo) {
        var changed = todo
        changed.transition(to: todo.status == .open ? .completed : .open)
        Task { await env.lifeLog.update(todo: changed) }
    }

    private func confirm(_ todo: LifeLogTodo) {
        var changed = todo
        changed.transition(to: .open)
        Task { await env.lifeLog.update(todo: changed) }
    }

    private func todoTitle(_ todo: LifeLogTodo) -> Binding<String> {
        Binding(get: { todo.title }, set: { value in
            var changed = todo
            changed.title = value
            Task { await env.lifeLog.update(todo: changed) }
        })
    }

    private func exportSelectedDay(_ text: String, date: Date, to destination: LifeLogExportDestination) async -> Bool {
        await writeExport(text, filename: "Koe-LifeLog-\(LifeLogDateKey.string(for: date)).md", to: destination)
    }

    private func exportOpenTodos(to destination: LifeLogExportDestination) {
        let todos = env.lifeLog.todos
        Task {
            let text = await Task.detached(priority: .userInitiated) {
                LifeLogTextExporter.renderOpenTodos(todos)
            }.value
            _ = await writeExport(text, filename: "Koe-Open-TODO.md", to: destination)
        }
    }

    private func writeExport(_ text: String, filename: String, to destination: LifeLogExportDestination) async -> Bool {
        switch destination {
        case .clipboard:
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(text, forType: .string) else {
                exportError = "クリップボードへ書き込めませんでした。"
                return false
            }
            return true
        case .file:
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = filename
            let response = await withCheckedContinuation { continuation in
                panel.begin { continuation.resume(returning: $0) }
            }
            guard response == .OK, let url = panel.url else { return false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try text.write(to: url, atomically: true, encoding: .utf8)
                }.value
                return true
            } catch {
                exportError = error.localizedDescription
                return false
            }
        }
    }

}

private struct LifeLogMarkdownSummary: View {
    let markdown: String

    var body: some View {
        Text(rendered)
            .font(.system(size: 12.5))
            .lineSpacing(3.5)
            .textSelection(.enabled)
            .tint(KoeTheme.accent)
            .accessibilityIdentifier("life-log.summary-markdown")
    }

    private var rendered: AttributedString {
        do {
            return try AttributedString(
                markdown: markdown,
                options: .init(interpretedSyntax: .full)
            )
        } catch {
            // 生成済みデータは表示し続け、Markdown解釈の失敗で本文を失わない。
            return AttributedString(markdown)
        }
    }
}

struct LiveWaveform: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.22)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate * 4
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { index in
                    Capsule()
                        .fill(KoeTheme.voiceGradient)
                        .frame(width: 2.5, height: 5 + abs(sin(phase + Double(index))) * 8)
                }
            }
            .frame(width: 17, height: 14)
        }
    }
}

private struct DayRhythmView: View {
    var day: LifeLogDay

    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    let value = intensity(hour)
                    Capsule()
                        .fill(value > 0 ? AnyShapeStyle(KoeTheme.accent.opacity(0.45 + value * 0.55)) : AnyShapeStyle(Color.primary.opacity(0.08)))
                        .frame(height: 3 + value * 29)
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { value in
                    Text("\(value)")
                    if value != 24 { Spacer() }
                }
            }
            .font(.system(size: 9).monospacedDigit())
            .foregroundStyle(.tertiary)
        }
    }

    private func intensity(_ hour: Int) -> CGFloat {
        let calendar = Calendar.current
        let utterances = day.utterances.filter { calendar.component(.hour, from: $0.startedAt) == hour }.count
        let events = day.calendarEvents.filter { !$0.isAllDay && calendar.component(.hour, from: $0.startsAt) == hour }.count
        return min(1, CGFloat(utterances) / 4 + CGFloat(events) / 3)
    }
}
