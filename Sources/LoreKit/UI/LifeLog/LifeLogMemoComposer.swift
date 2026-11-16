import SwiftUI

struct LifeLogMemoComposer: View {
    private let actionDiameter: CGFloat = 28
    /// 1行の入力欄は上下の余白を含めて約31pt。これを超えたら折り返しか改行で2行以上になっている。
    private let singleLineHeight: CGFloat = 40

    @Binding var text: String
    var accessibilityPrefix: String
    /// これを超える行数は入力欄の中でscrollする。
    var maxLines: Int
    var isVoiceMemoRecording: Bool
    var isPreparingVoiceMemo: Bool
    var canToggleVoiceMemo: Bool
    var voiceMemoShortcut: String
    var onToggleVoiceMemo: () -> Void
    var onSend: (String) -> Void

    @State private var isMultiline = false

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            VStack(alignment: .leading, spacing: 0) {
                // 入力欄は浮いたbar自体を枠として使い、二重の枠を描かない。
                TextField("メモを追加…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: LoreTheme.TextSize.body))
                    .lineLimit(1...maxLines)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 7)
                    .onGeometryChange(for: Bool.self) { $0.size.height > singleLineHeight } action: { isMultiline = $0 }
                    .memoShiftReturnInsertsNewline()
                    .onSubmit(send)
                    .accessibilityIdentifier("\(accessibilityPrefix).memo-input")
                // 複数行を書き始めた時だけ、送信と改行のkeyを示す。1行の間は出さない。
                if isMultiline {
                    MemoKeyHint("Shift-Returnで改行")
                        .padding(.horizontal, 4)
                        .padding(.bottom, 4)
                        .accessibilityIdentifier("\(accessibilityPrefix).memo-hint")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            voiceMemoButton
            Button(action: send) {
                ZStack {
                    Circle()
                        .fill(trimmedText.isEmpty ? AnyShapeStyle(Color.secondary.opacity(0.12)) : AnyShapeStyle(LoreTheme.accent))
                        .frame(width: actionDiameter, height: actionDiameter)
                    Image(systemName: "arrow.up")
                        .font(.system(size: LoreTheme.TextSize.callout, weight: .bold))
                        .foregroundStyle(trimmedText.isEmpty ? Color.secondary.opacity(0.45) : LoreTheme.onAccent)
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
                        .fill(LoreTheme.recording.opacity(0.2))
                        .frame(width: 34, height: 34)
                        .scaleEffect(isVoiceMemoRecording ? 1.12 : 0.72)
                        .opacity(isVoiceMemoRecording ? 0.82 : 0)
                        .animation(
                            .easeInOut(duration: 0.82).repeatForever(autoreverses: true),
                            value: isVoiceMemoRecording
                        )
                }
                Circle()
                    .fill(isVoiceMemoRecording ? AnyShapeStyle(LoreTheme.recording) : AnyShapeStyle(Color.secondary.opacity(0.12)))
                    .frame(width: actionDiameter, height: actionDiameter)
                if isPreparingVoiceMemo {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(.secondary)
                } else {
                    Image(systemName: isVoiceMemoRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
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
