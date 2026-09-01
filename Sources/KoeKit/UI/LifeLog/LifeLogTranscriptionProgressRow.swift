import SwiftUI

struct LifeLogTranscriptionProgressRow: View {
    let startedAt: Date

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let elapsed = max(0, Int(context.date.timeIntervalSince(startedAt)))
            HStack(spacing: 9) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                shimmerText
                Spacer(minLength: 8)
                Text(Self.elapsedText(elapsed))
                    .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(KoeTheme.accent)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(KoeTheme.accent.opacity(0.045))
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
                Text("文字起こし中")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(KoeTheme.accent.opacity(0.38))
                    .overlay {
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.95), .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: width * 0.55)
                        .offset(x: CGFloat(phase) * width * 1.55 - width * 0.65)
                        .mask(alignment: .leading) {
                            Text("文字起こし中")
                                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                        }
                    }
            }
        }
        .frame(width: 82, height: 16)
    }

    static func elapsedText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
