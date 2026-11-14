import SwiftUI

/// 録音中・処理中に画面下部へ出る小さなフローティング表示(FR-8.2 / FR-8.3)。
///
/// Dynamic Islandのように、普段は高さ44 ptの一本のcapsuleで、左から状態の印、
/// 波形または状態の語、経過時間、mode、escを並べる。逐次textが届くとcapsuleの上へ
/// 本文の段が伸び、同じガラスの面のまま角の丸い板へ形を変える。
struct HudView: View {
    var coordinator: DictationCoordinator
    var onCancel: () -> Void

    @State private var isHovering = false

    private var phase: SessionPhase { coordinator.phase }
    private var tint: Color { LoreTheme.tint(for: phase) }

    /// 逐次textは最新の語が見えるよう、長ければ末尾だけを残す。
    private var transcript: String {
        let value = coordinator.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = 96
        guard value.count > limit else { return value }
        return "…" + value.suffix(limit)
    }

    private var isRecording: Bool {
        if case .recording = phase { return true }
        return false
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

    private var terminalDetail: String? {
        guard isTerminal, let detail = coordinator.statusDetail, !detail.isEmpty else { return nil }
        return detail
    }

    private var expands: Bool { !transcript.isEmpty || terminalDetail != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if expands {
                VStack(alignment: .leading, spacing: 6) {
                    if !transcript.isEmpty {
                        Text(transcript)
                            .font(.system(size: 14))
                            .foregroundStyle(.primary.opacity(isRecording ? 0.92 : 0.7))
                            .lineSpacing(3)
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentTransition(.interpolate)
                    }
                    if let detail = terminalDetail {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(LoreTheme.warning)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 2)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            bar
        }
        .frame(width: expands ? 440 : nil)
        .fixedSize(horizontal: !expands, vertical: true)
        // いまの状態の色をガラスへわずかに透かす。文字を増やさずに状態が伝わる。
        .glassEffect(
            .regular.tint(tint.opacity(0.12)),
            in: RoundedRectangle(cornerRadius: expands ? 24 : 22, style: .continuous)
        )
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: phase)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: expands)
        .onHover { isHovering = $0 }
        .padding(16)
    }

    /// 高さ44 ptのcapsule。録音中は波形、それ以外は状態の語を中央に置く。
    private var bar: some View {
        HStack(spacing: 10) {
            HudStatusOrb(phase: phase, tint: tint, level: coordinator.inputLevel)
                .help(coordinator.inputDeviceName.map { Text("入力: \($0)") } ?? Text(verbatim: ""))

            if isRecording {
                WaveformView(levels: coordinator.levelHistory, isActive: true)
                    .frame(width: 132, height: 22)
                    .mask {
                        LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .init(x: 0.35, y: 0.5))
                    }
                Text(coordinator.recordingElapsed.clockText)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            } else {
                Text(LocalizedStringKey(coordinator.activityLabel ?? LoreTheme.label(for: phase)))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isTerminal ? AnyShapeStyle(tint) : AnyShapeStyle(.primary))
                    .shimmering(isProcessing)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }

            Spacer(minLength: 6)

            if let mode = coordinator.activeMode {
                HStack(spacing: 4) {
                    Image(systemName: coordinator.pinnedModeID != nil ? "pin.fill" : "wand.and.stars")
                        .font(.system(size: 8.5, weight: .semibold))
                    Text(mode.name)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }

            if phase.isActive {
                Button(action: onCancel) {
                    Text("esc")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(isHovering ? .primary : .secondary)
                        .frame(minWidth: 26, minHeight: 18)
                        .background {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.primary.opacity(isHovering ? 0.35 : 0.18), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .help("録音を破棄して中止します")
            }
        }
        .padding(.leading, 11)
        .padding(.trailing, 12)
        .frame(height: 44)
        .frame(minWidth: 240)
    }
}

/// Capsule左端の印。録音中は声の大きさで脈打つrose、処理中は回る弧、終了時は結果の記号。
private struct HudStatusOrb: View {
    var phase: SessionPhase
    var tint: Color
    var level: Float

    @State private var spin = false

    var body: some View {
        ZStack {
            switch phase {
            case .recording:
                Circle()
                    .fill(tint.opacity(0.22))
                    .scaleEffect(0.75 + CGFloat(min(1, level)) * 0.6)
                    .animation(.easeOut(duration: 0.08), value: level)
                Circle()
                    .fill(LoreTheme.recording)
                    .frame(width: 10, height: 10)
            case .recognizing, .formatting, .inserting:
                Circle()
                    .stroke(tint.opacity(0.18), lineWidth: 2)
                    .frame(width: 16, height: 16)
                Circle()
                    .trim(from: 0, to: 0.32)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .frame(width: 16, height: 16)
                    .rotationEffect(.degrees(spin ? 360 : 0))
                    .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spin)
                    .onAppear { spin = true }
            case .idle, .finished:
                Image(systemName: LoreTheme.symbol(for: phase))
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tint)
                    .symbolEffect(.bounce, value: phase)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct Shimmer: ViewModifier {
    var isActive: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        if isActive {
            content
                .overlay {
                    LinearGradient(
                        colors: [.clear, .white.opacity(0.55), .clear],
                        startPoint: .init(x: phase - 0.3, y: 0.5),
                        endPoint: .init(x: phase + 0.3, y: 0.5)
                    )
                    .blendMode(.plusLighter)
                    .mask(content)
                    .allowsHitTesting(false)
                }
                .onAppear {
                    withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 2 }
                }
        } else {
            content
        }
    }
}

private extension View {
    /// 処理中の語に光を流し、待っている間も止まっていないことを示す。
    func shimmering(_ isActive: Bool) -> some View { modifier(Shimmer(isActive: isActive)) }
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
            mode: BuiltinModes.defaultMode,
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
            mode: BuiltinModes.defaultMode
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
