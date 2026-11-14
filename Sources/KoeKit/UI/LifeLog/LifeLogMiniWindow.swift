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
                selectedDate: env.lifeLog.selectedDate
            )

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(items) { item in
                            switch item.kind {
                            case .utterance(let utterance): utteranceRow(utterance)
                            case .dictation(let dictation): dictationRow(dictation)
                            case .memo(let memo): memoRow(memo)
                            case .event(let event): eventRow(event)
                            }
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.vertical, 6)
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
                scheduleCaption: env.lifeLogScheduleCaption,
                accessibilityIdentifier: "life-log-mini.capture-toggle"
            ) {
                env.setLifeLogCaptureEnabled(!env.lifeLog.hasCaptureIntent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            LifeLogMemoComposer(
                text: $memoDraft,
                accessibilityPrefix: "life-log-mini",
                isVoiceMemoRecording: env.coordinator.isVoiceMemoRecording,
                isPreparingVoiceMemo: env.isPreparingVoiceMemo,
                canToggleVoiceMemo: env.canToggleVoiceMemo,
                voiceMemoShortcut: env.settings.voiceMemoHotkey.displayName,
                onToggleVoiceMemo: env.toggleVoiceMemo
            ) { value in
                Task { await env.lifeLog.addMemo(value) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 10)
        }
        .frame(minWidth: 340, minHeight: 360)
        .task {
            env.applyLifeLogMiniWindowLevel()
            await env.lifeLog.followCurrentDay()
        }
    }

    private enum ItemKind {
        case utterance(LifeLogUtterance)
        case dictation(LifeLogDictation)
        case memo(LifeLogMemo)
        case event(CalendarEventSnapshot)
    }
    private struct Item: Identifiable {
        var id: String
        var date: Date
        var kind: ItemKind
    }
    private var items: [Item] {
        (env.lifeLog.day.utterances.map { Item(id: "u-\($0.id)", date: $0.startedAt, kind: .utterance($0)) }
         + env.lifeLog.day.dictations.map { Item(id: "d-\($0.id)", date: $0.startedAt, kind: .dictation($0)) }
         + env.lifeLog.day.memos.map { Item(id: "m-\($0.id)", date: $0.createdAt, kind: .memo($0)) }
         + env.lifeLog.day.calendarEvents.filter { !$0.isAllDay }.map { Item(id: "e-\($0.id)", date: $0.startsAt, kind: .event($0)) })
            .sorted { $0.date < $1.date }
    }

    private func eventRow(_ event: CalendarEventSnapshot) -> some View {
        CalendarEventCard(event: event)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .id("e-\(event.id)")
    }

    private func dictationRow(_ dictation: LifeLogDictation) -> some View {
        TimelineEntryRow(date: dictation.startedAt, kind: .dictation, text: dictation.text, compact: true)
            .id("d-\(dictation.id)")
    }

    private func utteranceRow(_ utterance: LifeLogUtterance) -> some View {
        TimelineEntryRow(date: utterance.startedAt, kind: .utterance, text: utterance.text, compact: true)
            .id("u-\(utterance.id)")
    }

    private func memoRow(_ memo: LifeLogMemo) -> some View {
        TimelineEntryRow(
            date: memo.createdAt,
            kind: .memo,
            text: memo.text,
            compact: true,
            accessibilityPrefix: "life-log-mini.memo-\(memo.id)",
            onEdit: { text in await env.lifeLog.updateMemo(id: memo.id, text: text) }
        )
            .id("m-\(memo.id)")
    }
}
