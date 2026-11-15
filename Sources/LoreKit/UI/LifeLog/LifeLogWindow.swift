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
    /// Main windowはAppKitのwindowにhostしたviewでSwiftUIのsceneを持たないため、
    /// `SceneStorage`は値を保てず切り替えが効かない。表示状態は`AppStorage`に残す。
    @AppStorage("lifeLog.showsInspector") private var showsInspector = true
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
                    schedule: env.settings.lifeLogSchedule,
                    participatingOnly: env.settings.lifeLogParticipatingEventsOnly,
                    onJump: { date in Task { await env.lifeLog.jumpToTime(date) } },
                    onShowEvent: { occurrence in env.lifeLog.jumpToTimelineItem(occurrence.timelineItemID) }
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
            Button { showsExportSheet = true } label: { Label("書き出す", systemImage: "square.and.arrow.up") }
                .help("この日の記録を書き出す")
                .accessibilityIdentifier("life-log.export-day")
        }
        ToolbarItem(placement: .automatic) {
            Button { showsInspector.toggle() } label: { Label("概要", systemImage: "sidebar.trailing") }
                .help(Text(showsInspector ? "概要を隠す" : "概要を表示"))
                .accessibilityIdentifier("life-log.inspector-toggle")
        }
    }

    private var isToday: Bool { Calendar.current.isDateInToday(env.lifeLog.selectedDate) }

    /// Things 3のように、その日を大きな日付で始める。小さな見出しで今日か何年かを示し、
    /// 記録状態と終日の予定は日付の下に一列だけ置く。Scrollすると見出しごとtoolbarの下へ流れる。
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            (isToday ? Text("今日") : Text(verbatim: env.lifeLog.selectedDate.loreFormatted(.dateTime.year())))
                .font(.system(size: LoreTheme.TextSize.body, weight: .semibold))
                .foregroundStyle(isToday ? AnyShapeStyle(LoreTheme.recording) : AnyShapeStyle(.secondary))
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(env.lifeLog.selectedDate.loreFormatted(.dateTime.month(.wide).day()))
                    .font(LoreTheme.titleFont)
                Text(env.lifeLog.selectedDate.loreFormatted(.dateTime.weekday(.wide)))
                    .font(.system(size: LoreTheme.TextSize.title, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            if showsHeaderChips {
                HStack(spacing: 6) {
                    if isToday && env.lifeLog.isCapturing {
                        HeaderChip(text: "記録中", symbol: nil, tint: LoreTheme.recording, dot: true)
                    }
                    ForEach(allDayEvents) { event in
                        HeaderChip(text: "\(event.title)", symbol: "calendar", tint: LoreTheme.event, dot: false)
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
                    tint: LoreTheme.warning,
                    actionTitle: nil,
                    action: nil,
                    onDismiss: env.lifeLog.dismissError
                )
                .accessibilityIdentifier("life-log.notice")
            }
            if let error = env.lifeLogAI.errorMessage {
                NoticeBanner(
                    title: "ライフログAIの処理に失敗しました",
                    message: error,
                    tint: LoreTheme.warning,
                    actionTitle: nil,
                    action: nil,
                    onDismiss: env.lifeLogAI.dismissError
                )
                .accessibilityIdentifier("life-log-ai.notice")
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

    /// 空の日も、記録が並ぶはずの縦線の上に「ここから始まる」一行を置く。
    /// 画面中央の大きなplaceholderにせず、記録が入った時と同じ位置・同じ文法で待つ。
    private var timelineEmptyState: some View {
        let waiting = isToday && env.lifeLog.hasCaptureIntent
        return TimelineRowFrame(
            time: isToday ? Text("いま") : nil,
            node: .symbol(waiting ? "waveform" : (isToday ? "plus" : "moon.zzz"), waiting ? LoreTheme.recording : LoreTheme.accent),
            above: .none,
            below: isToday ? .gap : .none,
            topPadding: 4,
            bottomPadding: 48,
            firstLineCenter: 9.5
        ) {
            VStack(alignment: .leading, spacing: 5) {
                Text(waiting ? "発話を待っています" : (isToday ? "まだ記録はありません" : "この日の記録はありません"))
                    .font(.system(size: LoreTheme.TextSize.headline, weight: .semibold))
                if isToday {
                    Text(waiting
                         ? "話し始めると、ここに時刻順で並びます。"
                         : "下の録音ボタンで記録を始めると、話したことがここに時刻順で並びます。思いついたことは入力欄からメモにも残せます。")
                        .font(.system(size: LoreTheme.TextSize.body))
                        .lineSpacing(4)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.leading, 6)
        }
        .accessibilityElement(children: .combine)
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
                    isCurrent: isToday && value.contains(Date()),
                    recording: env.eventRecording(value),
                    lastTime: env.eventLastTime(value, in: env.lifeLog.day),
                    ai: CalendarEventCard.AI(
                        notes: AnyView(EventNotesView(env: env, event: value)),
                        isExcluded: env.lifeLogAI.excludedEventIDs.contains(value.id),
                        isCalendarExcluded: env.settings.lifeLogAI.excludedCalendars.contains(value.calendarTitle),
                        setExcluded: { excluded in Task { await env.lifeLogAI.setExcluded(excluded, eventID: value.id) } }
                    )
                )
                .accessibilityElement(children: .contain)
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
        await writeExport(text, filename: "Lore-LifeLog-\(LifeLogDateKey.string(for: date)).md", to: destination)
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
            CalendarEventCard.durationText(interval)
                .font(LoreTheme.captionFont.monospacedDigit())
                .foregroundStyle(.tertiary)
                .padding(.leading, compact ? 4 : 6)
        }
        .accessibilityLabel(Text("空き時間") + Text(verbatim: " ") + CalendarEventCard.durationText(interval))
    }
}

/// 日付見出しの下に並べる小さな札。記録中と終日の予定に使う。
private struct HeaderChip: View {
    var text: LocalizedStringKey
    var symbol: String?
    var tint: Color
    var dot: Bool

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(tint).frame(width: 6, height: 6) }
            if let symbol { Image(systemName: symbol).font(.system(size: LoreTheme.TextSize.micro, weight: .semibold)) }
            Text(text).lineLimit(1)
        }
        .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 3)
        .background(tint.opacity(0.13), in: Capsule())
    }
}
