import SwiftUI

/// 使っているモデルの状態と実測の速さ(FR-9)。
///
/// Koe は OS 内蔵のモデルだけを使うので、**ここに選択肢は無い**。
/// 出すのは「いま何が使われていて、使える状態か、どれくらい待つか」だけにする。
struct ModelsSettingsView: View {
    var env: AppEnvironment

    private var settings: AppSettings { env.settings }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            NoticeBanner(
                title: "この Mac の中だけで動きます",
                message: "聞き取りも文章の仕上げも macOS に内蔵されたモデルで行います。追加のダウンロードはありません。話した内容が外に出ることもありません。",
                tint: KoeTheme.accent,
                actionTitle: nil,
                action: nil
            )

            SettingsCard(
                title: "聞き取り",
                footnote: "話した声を文字にします。日本語の音声モデルは macOS が管理します。"
            ) {
                engineRow(
                    name: "Apple 音声認識 (SpeechAnalyzer)",
                    availability: env.engines.sttAvailability,
                    measured: env.measuredLatencies.transcription[
                        HistoryStore.key(EngineIdentifier.speechAnalyzer.rawValue, "システム音声モデル")
                    ],
                    canInstall: true
                )
                if let error = env.speechAssetError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(KoeTheme.recording)
                }
            }

            SettingsCard(
                title: "文章の仕上げ",
                footnote: "文字起こしを読める文章に整えます。うまくいかないときは、整えずにそのまま挿入します。"
            ) {
                engineRow(
                    name: "Apple Foundation Models",
                    availability: env.engines.llmAvailability,
                    measured: env.measuredLatencies.formatting[
                        HistoryStore.key(EngineIdentifier.foundationModels.rawValue, "Apple Foundation Models")
                    ],
                    canInstall: false
                )
            }

            SettingsCard(
                title: "待ち時間の上限",
                footnote: "ここを過ぎたら仕上げを打ち切り、文字起こしをそのまま挿入します。"
            ) {
                SettingsRow(title: "仕上げを待つ上限") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.formattingTimeoutMs) },
                                set: { settings.formattingTimeoutMs = Int($0) }
                            ),
                            in: 2_000...20_000,
                            step: 500
                        )
                        .frame(width: 190)
                        Text(String(format: "%.1f 秒", Double(settings.formattingTimeoutMs) / 1_000))
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
            }
        }
        .task { await env.reloadMeasuredLatencies() }
    }

    @ViewBuilder
    private func engineRow(
        name: String,
        availability: EngineAvailability,
        measured: LatencyStats?,
        canInstall: Bool
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 12)
                statusView(availability, canInstall: canInstall)
            }
            if let measured, measured.count > 0 {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(Self.speedLines(measured), id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("使うと、ここに実測の速さが出ます")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func statusView(_ availability: EngineAvailability, canInstall: Bool) -> some View {
        if canInstall, let progress = env.speechAssetProgress {
            ProgressView(value: progress).frame(width: 110)
        } else {
            switch availability {
            case .ready:
                Label("使えます", systemImage: "checkmark.circle")
                    .font(.system(size: 10.5))
                    .foregroundStyle(KoeTheme.success)
            case .needsDownload(let reason):
                HStack(spacing: 8) {
                    Text(reason)
                        .font(.system(size: 10.5))
                        .foregroundStyle(KoeTheme.warning)
                    if canInstall {
                        Button("取得") { Task { await env.installSpeechAssets() } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            case .unavailable(let reason):
                Text(reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(KoeTheme.recording)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 260)
            }
        }
    }

    /// 待ち時間は「音声の長さの何倍か」で見せる。秒数だけでは発話の長さ次第で意味が変わる。
    static func speedLines(_ stats: LatencyStats) -> [String] {
        guard let factor = stats.realtimeFactor else {
            return ["実測 \(secondsText(stats.p50Ms))", "\(stats.count) 回の中央値"]
        }
        let text = factor < 1
            ? String(format: "%.2f 倍", factor)
            : String(format: "%.1f 倍", factor)
        return [
            "音声の長さの \(text)",
            "音声 10 秒 → \(secondsText(Int(factor * 10_000)))",
            "\(stats.realtimeFactorCount) 回の中央値",
        ]
    }

    static func secondsText(_ ms: Int) -> String {
        ms >= 1_000 ? String(format: "%.1f 秒", Double(ms) / 1_000) : "\(ms) ミリ秒"
    }
}
