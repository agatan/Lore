import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct LifeLogWindow: View {
    var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @State private var exportError: String?
    @State private var showsExportSheet = false
    @State private var showsSearchSheet = false

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        HStack(spacing: 12) {
            left.frame(width: 306)
            timeline.frame(minWidth: 500, maxWidth: .infinity)
            right.frame(width: 336)
        }
        .padding(12)
        .frame(minWidth: 1_120, minHeight: 680)
        .background {
            LinearGradient(
                colors: [KoeTheme.accent.opacity(0.055), KoeTheme.accentSecondary.opacity(0.035), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ).ignoresSafeArea()
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { captureButton }
        }
        .task {
            await env.lifeLog.reload()
            await env.lifeLog.loadActivity(containing: env.lifeLog.selectedDate)
            if !AppEnvironment.usesScreenshotDemoData {
                await env.lifeLog.refreshCalendar(selectedCalendars: Set(env.settings.lifeLogCalendarTitles))
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

    private var captureButton: some View {
        Button {
            setCaptureEnabled(!env.lifeLog.isCapturing)
        } label: {
            Label(
                env.lifeLog.isCapturing ? "記録中" : "記録を開始",
                systemImage: env.lifeLog.isCapturing ? "waveform.circle.fill" : "waveform.circle"
            )
        }
        .buttonStyle(.borderedProminent)
        .labelStyle(.titleAndIcon)
        .tint(env.lifeLog.isCapturing ? KoeTheme.recording : KoeTheme.accent)
    }

    private var left: some View {
        VStack(alignment: .leading, spacing: 0) {
            MonthActivityCalendar(
                selectedDate: Binding(get: { env.lifeLog.selectedDate }, set: { _ in }),
                activity: env.lifeLog.monthActivity,
                onSelect: { date in Task { await env.lifeLog.select(date: date) } },
                onMonthChanged: { date in Task { await env.lifeLog.loadActivity(containing: date) } }
            )
            .padding(16)
            Divider().opacity(0.45)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(env.lifeLog.selectedDate.formatted(.dateTime.month(.abbreviated).day().weekday(.abbreviated)))
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer()
                    if let summary = env.lifeLog.day.summary, summary.isFinal {
                        Image(systemName: "checkmark.seal.fill").foregroundStyle(KoeTheme.success)
                    }
                }
                if let summary = env.lifeLog.day.summary {
                    Text(summary.summary).font(.system(size: 12.5)).textSelection(.enabled)
                    if !summary.commitments.isEmpty {
                        FlowLayout(spacing: 6) {
                            ForEach(summary.commitments, id: \.self) { value in
                                Pill(text: value, systemImage: "checkmark", tint: KoeTheme.accent)
                            }
                        }
                    }
                } else {
                    HStack(spacing: 8) { Image(systemName: "sparkles"); Text("Summary") }
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary.opacity(0.45))
                }
            }
            .padding(16)
            Spacer(minLength: 0)
        }
        .raisedGlass(cornerRadius: 22)
    }

    private var timeline: some View {
        VStack(spacing: 0) {
            panelHeader("Timeline", symbol: "calendar.day.timeline.left") {
                HStack(spacing: 10) {
                    Button { showsSearchSheet = true } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.plain).foregroundStyle(.secondary).help("ライフログを検索")
                    Text(env.lifeLog.selectedDate.formatted(.dateTime.year().month().day()))
                        .font(.system(size: 11, weight: .medium, design: .rounded)).foregroundStyle(.tertiary)
                }
            }
            Divider().opacity(0.4)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(timelineItems, id: \.id) { item in
                            timelineRow(item)
                            Divider().padding(.leading, 92).opacity(0.25)
                        }
                        if showsLiveCapture {
                            liveCaptureRow
                                .id("live-capture")
                        }
                    }.id("timeline-bottom")
                }
                .onChange(of: timelineItems.count) { old, new in
                    guard new > old else { return }
                    withAnimation { proxy.scrollTo("timeline-bottom", anchor: .bottom) }
                }
                .onChange(of: env.lifeLog.highlightedUtteranceID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
                .overlay { if timelineItems.isEmpty && !showsLiveCapture { timelineEmptyState } }
            }
            if let error = env.lifeLog.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(KoeTheme.recording).padding(8)
            }
        }
        .raisedGlass(cornerRadius: 22)
    }

    private var showsLiveCapture: Bool {
        Calendar.current.isDateInToday(env.lifeLog.selectedDate)
            && (env.lifeLog.isCapturing || env.lifeLog.isTranscribing)
    }

    private var liveCaptureRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(Date.now.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 64, alignment: .leading)
            HStack(spacing: 7) {
                LiveWaveform()
                Text(env.lifeLog.captureStatusText)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(KoeTheme.accent)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(KoeTheme.accent.opacity(0.055))
    }

    private var timelineEmptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: env.lifeLog.isCapturing ? "waveform" : "waveform.slash")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(env.lifeLog.isCapturing ? KoeTheme.accent : Color.secondary.opacity(0.42))
            if env.lifeLog.isCapturing {
                Text("Listening").font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.55))
            } else {
                Button { setCaptureEnabled(true) } label: { Label("Start", systemImage: "record.circle") }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private func timelineRow(_ item: TimelineItem) -> some View {
        switch item.kind {
        case .utterance(let value):
            HStack(alignment: .top, spacing: 12) {
                Text(value.startedAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary).frame(width: 64, alignment: .leading)
                Text(value.text).font(.system(size: 13)).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
            .background(env.lifeLog.highlightedUtteranceID == value.id ? KoeTheme.accent.opacity(0.12) : .clear)
            .id(value.id)
        case .event(let value):
            HStack(spacing: 10) {
                Text(value.startsAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 10.5, design: .monospaced))
                Circle().fill(KoeTheme.accentSecondary).frame(width: 5, height: 5)
                Text(value.title).font(.system(size: 11.5, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10).foregroundStyle(.secondary)
        case .memo(let value):
            HStack(alignment: .top, spacing: 12) {
                Text(value.createdAt.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary).frame(width: 64, alignment: .leading)
                Image(systemName: "note.text")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KoeTheme.accent)
                    .frame(width: 16)
                    .help("メモ")
                Text(value.text).font(.system(size: 13)).textSelection(.enabled)
                Spacer(minLength: 0)
                Button { Task { await env.lifeLog.deleteMemo(id: value.id) } } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain).foregroundStyle(.tertiary).help("メモを削除")
            }
            .padding(.horizontal, 16).padding(.vertical, 11)
        }
    }

    private var right: some View {
        VStack(spacing: 12) {
            todoPanel.frame(maxHeight: .infinity)
            insightsPanel.frame(height: 238)
            Button { showsExportSheet = true } label: {
                Label("この日を書き出す", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .help("予定・発話・メモをLLM向けテキストで書き出す")
        }
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
            panelHeader("TODO", symbol: "checkmark.circle") {
                HStack(spacing: 8) {
                    let count = env.lifeLog.todos.filter { $0.status == .open }.count
                    if count > 0 { Pill(text: "\(count)", tint: KoeTheme.accent) }
                    Button {
                        openWindow(id: KoeWindow.lifeLogTodos)
                        NSApp.activate()
                    } label: {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("すべてのTODO")
                    Menu {
                        Button("未実施TODOをコピー", systemImage: "doc.on.clipboard") {
                            exportOpenTodos(to: .clipboard)
                        }
                        Button("未実施TODOを保存…", systemImage: "doc.badge.arrow.up") {
                            exportOpenTodos(to: .file)
                        }
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("すべての未実施TODOを書き出す")
                }
            }
            Divider().opacity(0.4)
            if visibleTodos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark").font(.system(size: 25, weight: .light))
                    Text("Clear").font(.system(size: 11.5, weight: .medium, design: .rounded))
                }
                .foregroundStyle(.secondary.opacity(0.4)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleTodos) { todo in
                    HStack(alignment: .top) {
                        if todo.status == .draft {
                            Image(systemName: "sparkles").foregroundStyle(.secondary)
                        } else {
                            Button { toggle(todo) } label: {
                                Image(systemName: todo.status == .completed ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(todo.status == .completed ? KoeTheme.success : .secondary)
                            }.buttonStyle(.plain)
                        }
                        TextField("TODO", text: todoTitle(todo)).textFieldStyle(.plain).font(.system(size: 12))
                            .strikethrough(todo.status == .completed)
                        Spacer()
                        if todo.status == .draft {
                            Button { confirm(todo) } label: { Image(systemName: "checkmark") }
                                .buttonStyle(.plain).foregroundStyle(KoeTheme.success).help("TODOにする")
                            Button { Task { await env.lifeLog.delete(todoID: todo.id) } } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("棄却")
                        }
                        Button { Task { await env.lifeLog.jumpToSource(of: todo) } } label: { Image(systemName: "arrow.turn.down.left") }
                            .buttonStyle(.plain).foregroundStyle(.tertiary).disabled(todo.sourceUtteranceIDs.isEmpty).help("Source")
                        if todo.status != .draft {
                            Button { Task { await env.lifeLog.delete(todoID: todo.id) } } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).foregroundStyle(.tertiary).help("Delete")
                        }
                    }
                    .listRowBackground(todo.status == .draft ? KoeTheme.accent.opacity(0.055) : Color.clear)
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .raisedGlass(cornerRadius: 22)
    }

    private var visibleTodos: [LifeLogTodo] {
        env.lifeLog.todos.filter { $0.status != .completed }
    }

    private var insightsPanel: some View {
        VStack(spacing: 0) {
            panelHeader("Day", symbol: "chart.bar.xaxis") { EmptyView() }
            Divider().opacity(0.4)
            VStack(alignment: .leading, spacing: 18) {
                DayRhythmView(day: env.lifeLog.day)
                    .frame(minHeight: 80, maxHeight: 150)
                if let summary = env.lifeLog.day.summary, !summary.topics.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(summary.topics, id: \.self) { topic in
                            Pill(text: topic, tint: KoeTheme.accentSecondary)
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        Image(systemName: "circle.hexagongrid")
                        Text("No signals")
                    }
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary.opacity(0.35))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .raisedGlass(cornerRadius: 22)
    }

    private func panelHeader<Trailing: View>(_ title: String, symbol: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).foregroundStyle(KoeTheme.accent)
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
            Spacer()
            trailing()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private enum ItemKind { case utterance(LifeLogUtterance), memo(LifeLogMemo), event(CalendarEventSnapshot) }
    private struct TimelineItem { var id: String; var date: Date; var kind: ItemKind }
    private var timelineItems: [TimelineItem] {
        (env.lifeLog.day.utterances.map { TimelineItem(id: "u-\($0.id)", date: $0.startedAt, kind: .utterance($0)) }
         + env.lifeLog.day.memos.map { TimelineItem(id: "m-\($0.id)", date: $0.createdAt, kind: .memo($0)) }
         + env.lifeLog.day.calendarEvents.filter { !$0.isAllDay }.map { TimelineItem(id: "e-\($0.id)", date: $0.startsAt, kind: .event($0)) })
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

    private func exportSelectedDay(_ options: LifeLogTextExporter.Options, to destination: LifeLogExportDestination) -> Bool {
        let text = LifeLogTextExporter.render(
            date: env.lifeLog.selectedDate,
            day: env.lifeLog.day,
            todos: env.lifeLog.todos,
            options: options
        )
        return writeExport(text, filename: "Koe-LifeLog-\(LifeLogDateKey.string(for: env.lifeLog.selectedDate)).txt", to: destination)
    }

    private func exportOpenTodos(to destination: LifeLogExportDestination) {
        _ = writeExport(LifeLogTextExporter.renderOpenTodos(env.lifeLog.todos), filename: "Koe-Open-TODO.txt", to: destination)
    }

    private func writeExport(_ text: String, filename: String, to destination: LifeLogExportDestination) -> Bool {
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
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = filename
            guard panel.runModal() == .OK, let url = panel.url else { return false }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                return true
            } catch {
                exportError = error.localizedDescription
                return false
            }
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
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<24, id: \.self) { hour in
                    let value = intensity(hour)
                    Capsule()
                        .fill(value > 0 ? KoeTheme.voiceGradient : LinearGradient(colors: [.secondary.opacity(0.12)], startPoint: .bottom, endPoint: .top))
                        .frame(height: 5 + value * 35)
                        .frame(maxWidth: .infinity, alignment: .bottom)
                }
            }
            HStack {
                ForEach([0, 6, 12, 18, 24], id: \.self) { value in
                    Text("\(value)")
                    if value != 24 { Spacer() }
                }
            }
            .font(.system(size: 8.5, weight: .medium, design: .rounded))
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
