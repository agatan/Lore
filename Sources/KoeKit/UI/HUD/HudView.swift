import SwiftUI

/// 録音中・処理中に画面下部へ出る小さなフローティング表示(FR-8.2 / FR-8.3)。
///
/// 見た目の方針: 枠線や強い影で主張させず、ガラスの面と余白だけで浮かせる。
/// 情報の主役は波形と逐次テキストで、状態は小さな点と短い語で示す。
struct HudView: View {
    var coordinator: DictationCoordinator
    var onCancel: () -> Void

    @State private var isHovering = false

    private var phase: SessionPhase { coordinator.phase }
    private var tint: Color { KoeTheme.tint(for: phase) }

    private var transcript: String {
        coordinator.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            header
            if isRecording {
                WaveformView(levels: coordinator.levelHistory, isActive: true)
                    .frame(height: 26)
            }
            if !transcript.isEmpty {
                Text(transcript)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary.opacity(0.88))
                    .lineSpacing(2)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let detail = coordinator.statusDetail, isTerminal {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(KoeTheme.warning)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 15)
        .frame(width: 420, alignment: .leading)
        // いまの状態の色をガラスに透かす。文字を増やさずに状態が伝わる。
        .glassEffect(
            .regular.tint(tint.opacity(0.18)),
            in: RoundedRectangle(cornerRadius: KoeTheme.hudCornerRadius, style: .continuous)
        )
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: phase)
        .animation(.easeInOut(duration: 0.16), value: transcript.isEmpty)
        .onHover { isHovering = $0 }
        .padding(16)
    }

    private var header: some View {
        HStack(spacing: 9) {
            StatusDot(
                tint: tint,
                level: coordinator.inputLevel,
                isPulsing: isRecording,
                isSpinning: isProcessing
            )

            Text(KoeTheme.label(for: phase))
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.primary.opacity(0.9))

            if isRecording {
                Text(coordinator.recordingElapsed.clockText)
                    .font(.system(size: 12, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())

                // どのマイクで録れているか。主役ではないので最小の重さで置く。
                if let device = coordinator.inputDeviceName {
                    Label(device, systemImage: "mic")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .layoutPriority(-1)
                        .help("録音に使っている入力デバイス")
                }
            }

            Spacer(minLength: 8)

            if let mode = coordinator.activeMode {
                HStack(spacing: 4) {
                    if coordinator.pinnedModeID != nil {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                    }
                    Text(mode.name)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.secondary)
            }

            if phase.isActive {
                Button(action: onCancel) {
                    Text("esc")
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(isHovering ? .primary : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .glassEffect(
                            .regular.interactive(),
                            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .help("録音を破棄して中止します")
            }
        }
    }

    private var isProcessing: Bool {
        switch phase {
        case .recognizing, .formatting, .inserting: true
        default: false
        }
    }

    private var isTerminal: Bool {
        if case .finished = phase { return true }
        return false
    }
}

/// 状態を示す小さな点。録音中は音量で脈打ち、処理中は細いリングが回る。
private struct StatusDot: View {
    var tint: Color
    var level: Float
    var isPulsing: Bool
    var isSpinning: Bool

    @State private var spin = false

    var body: some View {
        ZStack {
            if isPulsing {
                Circle()
                    .fill(tint.opacity(0.28))
                    .frame(width: 16, height: 16)
                    .scaleEffect(1 + CGFloat(level) * 0.9)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
            if isSpinning {
                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .frame(width: 14, height: 14)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
            }
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
        }
        .frame(width: 18, height: 18)
        .onAppear { spin = true }
    }
}

#if DEBUG
@MainActor
private func previewCoordinator(
    phase: SessionPhase,
    transcript: String,
    mode: Mode?,
    levels: [Float]? = nil,
    elapsed: Duration = .zero,
    detail: String? = nil,
    inputDeviceName: String? = nil
) -> DictationCoordinator {
    let coordinator = DictationCoordinator(
        dependencies: .init(
            settings: AppSettings(),
            engines: EngineRegistry(),
            historyStore: { nil },
            modes: { BuiltinModes.all },
            vocabulary: { [] },
            onRecordChanged: { _ in }
        )
    )
    coordinator.applyPreviewState(
        phase: phase,
        transcript: transcript,
        mode: mode,
        levels: levels,
        elapsed: elapsed,
        detail: detail,
        inputDeviceName: inputDeviceName
    )
    return coordinator
}

/// プレビュー用のそれらしい波形。
@MainActor
private var sampleLevels: [Float] {
    (0..<DictationCoordinator.levelHistoryLength).map { index in
        let wave: Double = abs(sin(Double(index) / 2.6))
        let ramp: Double = 0.3 + 0.7 * Double(index) / 44
        return Float(0.1 + 0.8 * wave * ramp)
    }
}

#Preview("録音中") {
    HudView(
        coordinator: previewCoordinator(
            phase: .recording,
            transcript: "えーとこの関数をリファクタして、あーやっぱりテストも一緒に",
            mode: BuiltinModes.aiAgent,
            levels: sampleLevels,
            elapsed: .seconds(7),
            inputDeviceName: "MacBook Pro のマイク"
        ),
        onCancel: {}
    )
}

#Preview("整形中") {
    HudView(
        coordinator: previewCoordinator(
            phase: .formatting,
            transcript: "この関数をリファクタして、テストも一緒に書いて",
            mode: BuiltinModes.aiAgent
        ),
        onCancel: {}
    )
}

#Preview("整形スキップ") {
    HudView(
        coordinator: previewCoordinator(
            phase: .finished(.formattingSkipped(reason: "タイムアウト")),
            transcript: "この関数をリファクタして、テストも一緒に書いて",
            mode: BuiltinModes.chat,
            detail: "整形をスキップしました(処理がタイムアウトしました)"
        ),
        onCancel: {}
    )
}
#endif
