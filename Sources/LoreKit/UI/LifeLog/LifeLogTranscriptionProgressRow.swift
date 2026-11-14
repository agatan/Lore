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
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.variableColor.iterative, isActive: isListening)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    shimmerText
                    if !transcript.isEmpty {
                        Text(transcript)
                            .font(.system(size: 12.5))
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
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
            .foregroundStyle(LoreTheme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("life-log.transcription-progress")
    }

    private var shimmerText: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            GeometryReader { proxy in
                let width = max(1, proxy.size.width)
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 1.6) / 1.6
                Text(LocalizedStringKey(statusText))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(LoreTheme.accent.opacity(0.38))
                    .overlay {
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.95), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.55)
                        .offset(x: CGFloat(phase) * width * 1.55 - width * 0.65)
                        .mask(alignment: .leading) {
                            Text(LocalizedStringKey(statusText))
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                    }
            }
        }
        .frame(width: 88, height: 16)
    }

    private var statusText: String { isListening ? "聞き取り中" : "文字起こし中" }

    static func elapsedText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
