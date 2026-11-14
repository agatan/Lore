import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct LifeLogWindow: View {
    var env: AppEnvironment
    /// 時刻列と縦線を含めた列の幅。広いwindowでは中央に置き、左右の余白を釣り合わせる。
    static let readableTimelineWidth: CGFloat = 720
    @State private var exportError: String?
    @State private var showsExportSheet = false
    @State private var showsSearchSheet = false
    @SceneStorage("lifeLog.showsInspector") private var showsInspector = true
    @State private var timelineIsAtBottom = true
    @State private var timelineFollowsLatest = true
    @State private var memoDraft = ""

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        timeline
            .frame(minWidth: 560, minHeight: 600)
            .toolbar { toolbarItems }
            .inspector(isPresented: $showsInspector) {
                LifeLogDayInspector(
                    day: env.lifeLog.day,
                    date: env.lifeLog.selectedDate,
                    onJump: { date in Task { await env.lifeLog.jumpToTime(date) } }
                )
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
            }
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
            Button { showsSearchSheet = true } label: { Label("ライフログを検索", systemImage: "magnifyingglass") }
                .help("ライフログを検索 (⌘F)")
                .keyboardShortcut("f", modifiers: .command)
                .accessibilityIdentifier("life-log.search")
            Button { showsExportSheet = true } label: { Label("この日を書き出す", systemImage: "square.and.arrow.up") }
                .help("この日を書き出す")
                .accessibilityIdentifier("life-log.export-day")
        }
        ToolbarItem(placement: .automatic) {
            Button { showsInspector.toggle() } label: { Label("この日の概要", systemImage: "sidebar.trailing") }
                .help(showsInspector ? "この日の概要を隠す" : "この日の概要を表示")
                .accessibilityIdentifier("life-log.inspector-toggle")
        }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(env.lifeLog.selectedDate) }

    /// Things 3のように、その日を大きな日付で始める。小さな見出しで今日か何年かを示し、
    /// 記録状態と終日の予定は日付の下に一列だけ置く。Scrollすると見出しごとtoolbarの下へ流れる。
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(isToday ? "今日" : env.lifeLog.selectedDate.formatted(.dateTime.year()))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isToday ? AnyShapeStyle(KoeTheme.accent) : AnyShapeStyle(.secondary))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(env.lifeLog.selectedDate.formatted(.dateTime.month(.wide).day()))
                    .font(KoeTheme.titleFont)
                Text(env.lifeLog.selectedDate.formatted(.dateTime.weekday(.wide)))
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if showsHeaderChips {
                HStack(spacing: 6) {
                    if isToday && env.lifeLog.isCapturing {
                        HeaderChip(text: "記録中", symbol: nil, tint: KoeTheme.recording, dot: true)
                    }
                    ForEach(allDayEvents) { event in
                        HeaderChip(text: event.title, symbol: "calendar", tint: KoeTheme.accentSecondary, dot: false)
                            .accessibilityIdentifier("life-log.timeline-event-\(event.id)")
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding(.leading, TimelineRowFrame<EmptyView>.timeWidth(compact: false) + TimelineRail.width(compact: false) + 6)
        .padding(.top, 8)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var allDayEvents: [CalendarEventSnapshot] { LifeLogTimelineLayout.allDayEvents(in: env.lifeLog.day) }
    private var showsHeaderChips: Bool { (isToday && env.lifeLog.isCapturing) || !allDayEvents.isEmpty }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(timelineRows) { row in
                            if let gap = row.gapBefore {
                                TimelineGapRow(interval: gap)
                            }
                            timelineRow(row)
                        }
                    }
                    if timelineRows.isEmpty {
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
                .frame(maxWidth: .infinity)
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
            .onChange(of: timelineRows.last?.id) { _, _ in
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
        .frame(maxWidth: Self.readableTimelineWidth - 40)
        .padding(.horizontal, 28)
        .padding(.bottom, 16)
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
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

    @ViewBuilder
    private func timelineRow(_ row: LifeLogTimelineLayout.Row) -> some View {
        Group {
            switch row.kind {
            case .utterance(let value):
                TimelineEntryRow(
                    date: value.startedAt,
                    kind: .utterance,
                    text: value.text,
                    above: row.above,
                    below: row.below,
                    isHighlighted: env.lifeLog.highlightedTimelineItemID == row.id
                )
            case .event(let value):
                CalendarEventCard(
                    event: value,
                    above: row.above,
                    below: row.below,
                    isCurrent: isToday && value.contains(Date())
                )
                .accessibilityIdentifier("life-log.timeline-event-\(value.id)")
            case .dictation(let value):
                TimelineEntryRow(
                    date: value.startedAt,
                    kind: .dictation,
                    text: value.text,
                    above: row.above,
                    below: row.below,
                    isHighlighted: env.lifeLog.highlightedTimelineItemID == row.id
                )
            case .memo(let value):
                TimelineEntryRow(
                    date: value.createdAt,
                    kind: .memo,
                    text: value.text,
                    above: row.above,
                    below: row.below,
                    isHighlighted: env.lifeLog.highlightedTimelineItemID == row.id,
                    accessibilityPrefix: "life-log.memo-\(value.id)",
                    onEdit: { text in await env.lifeLog.updateMemo(id: value.id, text: text) },
                    onDelete: { Task { await env.lifeLog.deleteMemo(id: value.id) } }
                )
            }
        }
        .id(row.id)
    }

    private var timelineRows: [LifeLogTimelineLayout.Row] { LifeLogTimelineLayout.rows(for: env.lifeLog.day) }

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

/// 予定の外で長く空いた区間。点線の続きに、空いた長さだけを小さく置く。
struct TimelineGapRow: View {
    var interval: TimeInterval
    var compact = false

    var body: some View {
        TimelineRowFrame(
            time: nil,
            node: .none,
            above: .gap,
            below: .gap,
            topPadding: compact ? 4 : 6,
            bottomPadding: compact ? 4 : 6,
            firstLineCenter: 6,
            compact: compact
        ) {
            Text(verbatim: CalendarEventCard.durationText(interval))
                .font(KoeTheme.captionFont.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.leading, compact ? 4 : 6)
        }
        .accessibilityLabel(Text("\(CalendarEventCard.durationText(interval))の空き"))
    }
}

/// 日付見出しの下に並べる小さな札。記録中と終日の予定に使う。
private struct HeaderChip: View {
    var text: String
    var symbol: String?
    var tint: Color
    var dot: Bool

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tint).frame(width: 6, height: 6) }
            if let symbol { Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold)) }
            Text(verbatim: text).lineLimit(1)
        }
        .font(.system(size: 11, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
    }
}
