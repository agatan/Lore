import SwiftUI

struct LifeLogMemoComposer: View {
    private let actionDiameter: CGFloat = 28

    @Binding var text: String
    var accessibilityPrefix: String
    var isVoiceMemoRecording: Bool
    var isPreparingVoiceMemo: Bool
    var canToggleVoiceMemo: Bool
    var voiceMemoShortcut: String
    var onToggleVoiceMemo: () -> Void
    var onSend: (String) -> Void

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            // 入力欄は浮いたbar自体を枠として使い、二重の枠を描かない。
            TextField("メモを追加…", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(1...5)
                .padding(.horizontal, 4)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity)
                .onSubmit(send)
                .accessibilityIdentifier("\(accessibilityPrefix).memo-input")
            voiceMemoButton
            Button(action: send) {
                ZStack {
                    Circle()
                        .fill(trimmedText.isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.12)) : AnyShapeStyle(KoeTheme.voiceGradient))
                        .frame(width: actionDiameter, height: actionDiameter)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(trimmedText.isEmpty ? Color.secondary.opacity(0.45) : .white)
                }
                .frame(width: 32, height: 32)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(trimmedText.isEmpty)
            .help("メモを追加")
            .accessibilityIdentifier("\(accessibilityPrefix).memo-send")
            .animation(.easeInOut(duration: 0.18), value: trimmedText.isEmpty)
        }
    }

    private var voiceMemoButton: some View {
        Button(action: onToggleVoiceMemo) {
            ZStack {
                if isVoiceMemoRecording {
                    Circle()
                        .fill(KoeTheme.recording.opacity(0.2))
                        .frame(width: 34, height: 34)
                        .scaleEffect(isVoiceMemoRecording ? 1.12 : 0.72)
                        .opacity(isVoiceMemoRecording ? 0.82 : 0)
                        .animation(
                            .easeInOut(duration: 0.82).repeatForever(autoreverses: true),
                            value: isVoiceMemoRecording
                        )
                }
                Circle()
                    .fill(isVoiceMemoRecording ? AnyShapeStyle(KoeTheme.recordingGradient) : AnyShapeStyle(Color.secondary.opacity(0.12)))
                    .frame(width: actionDiameter, height: actionDiameter)
                if isPreparingVoiceMemo {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.secondary)
                } else {
                    Image(systemName: isVoiceMemoRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(isVoiceMemoRecording ? .white : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                        .symbolEffect(.breathe, options: .repeating, isActive: isVoiceMemoRecording)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canToggleVoiceMemo)
        .help(isVoiceMemoRecording ? "ボイスメモを停止" : "ボイスメモを開始（\(voiceMemoShortcut)）")
        .accessibilityLabel(isVoiceMemoRecording ? "ボイスメモを停止" : "ボイスメモを開始")
        .accessibilityIdentifier("\(accessibilityPrefix).voice-memo")
        .animation(.snappy(duration: 0.24), value: isVoiceMemoRecording)
        .animation(.easeInOut(duration: 0.2), value: isPreparingVoiceMemo)
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func send() {
        let value = trimmedText
        guard !value.isEmpty else { return }
        text = ""
        onSend(value)
    }
}
