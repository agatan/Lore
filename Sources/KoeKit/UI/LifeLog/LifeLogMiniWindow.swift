import SwiftUI

struct LifeLogMiniWindow: View {
    var env: AppEnvironment
    @State private var memoDraft = ""

    var body: some View {
        VStack(spacing: 0) {
            CurrentCalendarEventStrip(
                events: env.lifeLog.day.calendarEvents,
                selectedDate: env.lifeLog.selectedDate
            )

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
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
                }
                .onChange(of: items.count) { old, new in
                    guard new > old else { return }
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .task {
                    await Task.yield()
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
                .overlay {
                    if items.isEmpty && !env.lifeLog.isCapturing && !env.lifeLog.isTranscribing {
                        VStack(spacing: 10) {
                            Image(systemName: env.lifeLog.isCapturing ? "waveform" : "waveform.slash")
                                .font(.system(size: 28, weight: .light))
                            Text(env.lifeLog.isCapturing ? "発話を待っています" : "記録は停止中です")
                                .font(.system(size: 11.5, weight: .medium))
                        }
                        .foregroundStyle(.secondary.opacity(0.5))
                    }
                }
            }

            Divider().opacity(0.35)
            LifeLogCaptureControl(
                lifeLog: env.lifeLog,
                accessibilityIdentifier: "life-log-mini.capture-toggle"
            ) {
                env.setLifeLogCaptureEnabled(!env.lifeLog.hasCaptureIntent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider().opacity(0.35)
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
            .padding(10)
        }
        .frame(minWidth: 340, minHeight: 360)
        .background {
            LinearGradient(
                colors: [KoeTheme.accent.opacity(0.055), KoeTheme.accentSecondary.opacity(0.025), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
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
            .padding(.vertical, 6)
            .id("e-\(event.id)")
    }

    private func dictationRow(_ dictation: LifeLogDictation) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(dictation.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 45, alignment: .leading)
            Image(systemName: "keyboard.badge.ellipsis")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(KoeTheme.accent)
                .frame(width: 14)
                .help("音声入力")
            Text(dictation.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(KoeTheme.accent.opacity(0.04))
        .id("d-\(dictation.id)")
    }

    private func utteranceRow(_ utterance: LifeLogUtterance) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(utterance.startedAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 45, alignment: .leading)
            Text(utterance.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .id("u-\(utterance.id)")
    }

    private func memoRow(_ memo: LifeLogMemo) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(memo.createdAt.formatted(date: .omitted, time: .shortened))
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 45, alignment: .leading)
            Image(systemName: "note.text")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(KoeTheme.accent)
                .frame(width: 14)
            Text(memo.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .id("m-\(memo.id)")
    }
}
