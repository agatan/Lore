import SwiftUI

struct LifeLogTranscriptionProgressRow: View {
    let startedAt: Date
    let audioDuration: TimeInterval
    let isListening: Bool
    let transcript: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: isListening ? "waveform" : "waveform.badge.magnifyingglass")
                    .font(.system(size: LoreTheme.TextSize.callout, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    statusLabel
                    if !transcript.isEmpty {
                        Text(transcript)
                            .font(.system(size: LoreTheme.TextSize.callout))
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text("音声")
                    Text(Self.elapsedText(Int(audioDuration.rounded())))
                    if !isListening {
                        Text("·")
                        Text("処理")
                        Text(Self.elapsedText(elapsed))
                    }
                }
                .font(.system(size: LoreTheme.TextSize.caption, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .foregroundStyle(LoreTheme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("life-log.transcription-progress")
    }

    private var statusLabel: some View {
        Text(LocalizedStringKey(statusText))
            .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
            .foregroundStyle(LoreTheme.accent)
            .breathing(true)
            .frame(width: 88, height: 16, alignment: .leading)
    }

    private var statusText: String { isListening ? "聞き取り中" : "文字起こし中" }

    static func elapsedText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
