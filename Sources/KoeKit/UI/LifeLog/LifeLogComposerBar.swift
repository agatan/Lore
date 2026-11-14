import SwiftUI

/// Main / miniの最下部に浮かぶ1本のcapsule。Voice Memosの録音buttonとMessagesの入力欄を
/// 一つにまとめ、記録の開始・停止とmemo追加を同じ場所で行う。
///
/// Timelineはこのbarの下までscrollし、境界はscroll edge effectが作る。
struct LifeLogComposerBar: View {
    var env: AppEnvironment
    @Binding var memoDraft: String
    /// 例: `life-log`、`life-log-mini`。既存のaccessibility identifierの接頭辞。
    var accessibilityPrefix: String
    /// 過去日を表示中は現在のmemoを混ぜないよう、入力欄を出さない。
    var acceptsMemo: Bool
    var compact = false

    var body: some View {
        VStack(spacing: 8) {
            if let startedAt = env.lifeLog.liveActivityStartedAt {
                LifeLogTranscriptionProgressRow(
                    startedAt: startedAt,
                    audioDuration: env.lifeLog.liveActivityAudioDuration,
                    isListening: env.lifeLog.isHearingSpeech,
                    transcript: env.lifeLog.liveTranscript
                )
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            bar
        }
        .animation(.snappy(duration: 0.25), value: env.lifeLog.liveActivityStartedAt != nil)
    }

    private var status: LifeLogCaptureStatus {
        LifeLogCaptureStatus(lifeLog: env.lifeLog, scheduleCaption: env.lifeLogScheduleCaption)
    }

    private var bar: some View {
        HStack(alignment: .center, spacing: compact ? 8 : 10) {
            LifeLogRecordButton(
                lifeLog: env.lifeLog,
                status: status,
                accessibilityIdentifier: "\(accessibilityPrefix).capture-toggle"
            ) {
                env.setLifeLogCaptureEnabled(!env.lifeLog.hasCaptureIntent)
            }
            statusText
                .frame(maxWidth: acceptsMemo ? (compact ? 150 : 176) : .infinity, alignment: .leading)
            if acceptsMemo {
                Divider().frame(height: 20)
                LifeLogMemoComposer(
                    text: $memoDraft,
                    accessibilityPrefix: accessibilityPrefix,
                    isVoiceMemoRecording: env.coordinator.isVoiceMemoRecording,
                    isPreparingVoiceMemo: env.isPreparingVoiceMemo,
                    canToggleVoiceMemo: env.canToggleVoiceMemo,
                    voiceMemoShortcut: env.settings.voiceMemoHotkey.displayName,
                    onToggleVoiceMemo: env.toggleVoiceMemo
                ) { value in
                    Task { await env.lifeLog.addMemo(value) }
                }
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, acceptsMemo ? 6 : 16)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var statusText: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(LocalizedStringKey(status.title))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(env.lifeLog.isCapturing ? AnyShapeStyle(KoeTheme.recording) : AnyShapeStyle(.primary))
                .lineLimit(1)
            if let caption = status.subtitle {
                Text(caption)
                    .font(KoeTheme.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("\(accessibilityPrefix).capture-toggle.schedule")
            }
        }
        .contentTransition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: status.title)
    }
}

/// 記録の開始・停止button。停止中はblueの録音記号、記録意図がある間はroseの停止記号。
/// 実際に録音している間だけ外周がゆっくり脈打つ。
struct LifeLogRecordButton: View {
    var lifeLog: LifeLogCoordinator
    var status: LifeLogCaptureStatus
    var accessibilityIdentifier: String
    var diameter: CGFloat = 32
    var action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if lifeLog.isCapturing && !reduceMotion {
                    Circle()
                        .stroke(KoeTheme.recording.opacity(0.5), lineWidth: 2)
                        .frame(width: diameter, height: diameter)
                        .scaleEffect(pulse ? 1.32 : 1)
                        .opacity(pulse ? 0 : 0.9)
                        .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                        .onAppear { pulse = true }
                        .onDisappear { pulse = false }
                }
                Circle()
                    .fill(lifeLog.hasCaptureIntent ? AnyShapeStyle(KoeTheme.recordingGradient) : AnyShapeStyle(KoeTheme.voiceGradient))
                    .frame(width: diameter, height: diameter)
                    .shadow(color: (lifeLog.hasCaptureIntent ? KoeTheme.recording : KoeTheme.accent).opacity(0.35), radius: 4, y: 1)
                if lifeLog.hasCaptureIntent {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(.white)
                        .frame(width: diameter * 0.32, height: diameter * 0.32)
                        .opacity(lifeLog.isCapturing ? 1 : 0.75)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: diameter * 0.36, height: diameter * 0.36)
                }
            }
            .frame(width: diameter + 4, height: diameter + 4)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey(status.actionLabel))
        .accessibilityLabel(LocalizedStringKey(status.actionLabel))
        .accessibilityIdentifier(accessibilityIdentifier)
        .animation(.snappy(duration: 0.24), value: lifeLog.hasCaptureIntent)
    }
}
