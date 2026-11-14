import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct LifeLogWindow: View {
    var env: AppEnvironment
    static let readableTimelineWidth: CGFloat = 800
    @State private var exportError: String?
    @State private var showsExportSheet = false
    @State private var showsSearchSheet = false
    @State private var showsCalendarEvents = false
    @State private var timelineIsAtBottom = true
    @State private var timelineFollowsLatest = true
    @State private var memoDraft = ""

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        timeline
            .frame(minWidth: 560, minHeight: 600)
            .toolbar { toolbarItems }
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
                    onExport: exportSelectedDay
                )
            }
            .sheet(isPresented: $showsSearchSheet) {
                LifeLogSearchSheet(env: env)
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

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        // 操作はcontentの右肩へ寄せ、systemにglassの1グループとしてまとめさせる。
        ToolbarSpacer(.flexible)
        ToolbarItemGroup(placement: .automatic) {
            Button { showsCalendarEvents = true } label: { Label("この日の予定", systemImage: "calendar") }
                .help("この日の予定")
                .accessibilityIdentifier("life-log.calendar-events")
                .popover(isPresented: $showsCalendarEvents, arrowEdge: .bottom) {
                    LifeLogCalendarEventList(
                        events: env.lifeLog.day.calendarEvents,
                        onSelect: { event in
                            showsCalendarEvents = false
                            Task { await env.lifeLog.jumpToTime(event.startsAt) }
                        }
                    )
                }
            Button { showsSearchSheet = true } label: { Label("ライフログを検索", systemImage: "magnifyingglass") }
                .help("ライフログを検索 (⌘F)")
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityIdentifier("life-log.search")
            Button { showsExportSheet = true } label: { Label("この日を書き出す", systemImage: "square.and.arrow.up") }
                .help("この日を書き出す")
                .accessibilityIdentifier("life-log.export-day")
        }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(env.lifeLog.selectedDate) }

    /// Things 3のように、その日を大きな日付で始める。Scrollすると見出しごとtoolbarの下へ流れる。
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(env.lifeLog.selectedDate.formatted(.dateTime.month(.wide).day()))
                .font(KoeTheme.titleFont)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 8) {
                headerSubtitle
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                if isToday && env.lifeLog.isCapturing {
                    HStack(spacing: 5) {
                        Circle().fill(KoeTheme.recording).frame(width: 6, height: 6)
                        Text("記録中")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(KoeTheme.recording)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(KoeTheme.recording.opacity(0.12), in: Capsule())
                }
            }
        }
        .padding(.leading, Self.rowLeading)
        .padding(.top, 8)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerSubtitle: Text {
        let weekday = env.lifeLog.selectedDate.formatted(.dateTime.weekday(.wide))
        let day = env.lifeLog.day
        let count = day.utterances.count + day.dictations.count + day.memos.count
        let lead = isToday ? Text("今日 · \(weekday)") : Text(verbatim: weekday)
        return count == 0 ? lead : Text("\(lead) · \(Text("\(count)件"))")
    }

    /// Timeline行の本文左端と見出しを揃えるための余白。
    static let rowLeading: CGFloat = 16

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(timelineItems, id: \.id) { item in
                            timelineRow(item)
                        }
                    }
                    if timelineItems.isEmpty {
                        timelineEmptyState
                            .frame(maxWidth: .infinity, minHeight: 320)
                    }
                    Color.clear.frame(height: 1).id("timeline-bottom")
                }
                // 広いwindowでも1行が長くなりすぎないよう、本文を読みやすい幅に抑える。
                .frame(maxWidth: Self.readableTimelineWidth, alignment: .leading)
                .padding(.horizontal, 28)
                .padding(.top, 12)
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollEdgeEffectHidden(true, for: .top)
            .scrollEdgeEffectStyle(.soft, for: .bottom)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
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
        }
    }

    /// 最下部に浮かぶ通知とcomposer。Timelineと同じ読みやすい幅に揃える。
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let error = env.lifeLog.errorMessage {
                NoticeBanner(
                    title: "ライフログを継続しています",
                    message: error,
                    tint: KoeTheme.warning,
                    actionTitle: nil,
                    action: nil,
                    onDismiss: env.lifeLog.dismissError
                )
                .accessibilityIdentifier("life-log.notice")
            }
            LifeLogComposerBar(
                env: env,
                memoDraft: $memoDraft,
                accessibilityPrefix: "life-log",
                acceptsMemo: isToday
            )
        }
        .frame(maxWidth: Self.readableTimelineWidth)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .accessibilityIdentifier("life-log.timeline-event-\(value.id)")
        case .dictation(let value):
            TimelineEntryRow(date: value.startedAt, kind: .dictation, text: value.text)
        case .memo(let value):
            TimelineEntryRow(
                date: value.createdAt,
                kind: .memo,
                text: value.text,
                isHighlighted: env.lifeLog.highlightedTimelineItemID == "m-\(value.id)",
                accessibilityPrefix: "life-log.memo-\(value.id)",
                onEdit: { text in await env.lifeLog.updateMemo(id: value.id, text: text) },
                onDelete: { Task { await env.lifeLog.deleteMemo(id: value.id) } }
            )
        }
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

    private func exportSelectedDay(_ text: String, date: Date, to destination: LifeLogExportDestination) async -> Bool {
        await writeExport(text, filename: "Koe-LifeLog-\(LifeLogDateKey.string(for: date)).md", to: destination)
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

struct DayRhythmView: View {
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
