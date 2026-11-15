import SwiftUI

struct LifeLogMiniWindow: View {
    var env: AppEnvironment
    @State private var memoDraft = ""
    @State private var timelineIsAtBottom = true
    @State private var timelineFollowsLatest = true

    var body: some View {
        VStack(spacing: 0) {
            CurrentCalendarEventStrip(
                events: env.lifeLog.day.calendarEvents,
                selectedDate: env.lifeLog.selectedDate,
                recording: env.eventRecording,
                lastTime: env.eventLastTime
            )

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items) { row in
                            if let gap = row.gapBefore {
                                TimelineGapRow(interval: gap, compact: true)
                            }
                            rowView(row)
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 6)
                }
                .scrollEdgeEffectStyle(.soft, for: .all)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    LifeLogComposerBar(
                        env: env,
                        memoDraft: $memoDraft,
                        accessibilityPrefix: "life-log-mini",
                        acceptsMemo: true,
                        compact: true
                    )
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                    .padding(.top, 4)
                }
                .task {
                    await Task.yield()
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .onChange(of: items.last?.id) { _, _ in
                    guard timelineFollowsLatest else { return }
                    Task { @MainActor in
                        await Task.yield()
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom", anchor: .bottom)
                        }
                    }
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
                .overlay {
                    if items.isEmpty && !env.lifeLog.isCapturing && !env.lifeLog.isTranscribing {
                        ContentUnavailableView("記録は停止中です", systemImage: "waveform.slash")
                            .foregroundStyle(.secondary)
                    }
                }
            }

        }
        // Title barを持たない小窓なので、traffic lightの高さだけ上を空ける。
        .padding(.top, 28)
        .background { VisualEffectBackground(material: .popover).ignoresSafeArea() }
        .ignoresSafeArea(edges: .top)
        .frame(minWidth: 360, minHeight: 360)
        .task {
            env.applyLifeLogMiniWindowLevel()
            await env.lifeLog.followCurrentDay()
        }
    }

    private var items: [LifeLogTimelineLayout.Row] { LifeLogTimelineLayout.rows(for: env.lifeLog.day) }

    @ViewBuilder
    private func rowView(_ row: LifeLogTimelineLayout.Row) -> some View {
        Group {
            switch row.kind {
            case .event(let event):
                CalendarEventCard(
                    event: event, above: row.above, below: row.below, compact: true,
                    recording: env.eventRecording(event)
                )
            case .dictation(let dictation):
                TimelineEntryRow(date: dictation.startedAt, kind: .dictation, text: dictation.text,
                                 above: row.above, below: row.below, compact: true)
            case .utterance(let utterance):
                TimelineEntryRow(date: utterance.startedAt, kind: .utterance, text: utterance.text,
                                 above: row.above, below: row.below, compact: true)
            case .memo(let memo):
                TimelineEntryRow(
                    date: memo.createdAt,
                    kind: .memo,
                    text: memo.text,
                    above: row.above,
                    below: row.below,
                    compact: true,
                    accessibilityPrefix: "life-log-mini.memo-\(memo.id)",
                    onEdit: { text in await env.lifeLog.updateMemo(id: memo.id, text: text) }
                )
            }
        }
        .id(row.id)
    }
}
