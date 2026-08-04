import SwiftUI

/// 聞き取りと仕上げに使うモデルを選ぶ(FR-9)。
///
/// 「エンジンを選んでからモデルを選ぶ」二段構えは実装の都合なので出さない。
/// 選択肢を 1 段に並べ、正確さ・速さの目安と、あなたの環境での実測時間で選べるようにする。
struct ModelsSettingsView: View {
    var env: AppEnvironment

    private var settings: AppSettings { env.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            NoticeBanner(
                title: "ダウンロード以外で通信しません",
                message: "モデルの取得だけがネットワークを使います。話した内容や履歴が外に出ることはありません。",
                tint: KoeTheme.accent,
                actionTitle: nil,
                action: nil
            )

            section(
                title: "聞き取り",
                caption: "話した声を文字にします。",
                choices: env.engines.transcriptionChoices,
                selectedID: TranscriptionCatalog.choice(
                    engine: settings.sttEngineID,
                    modelID: settings.whisperModelID
                )?.id,
                measured: env.measuredLatencies.transcription,
                select: { choice in Task { await env.selectTranscription(choice) } }
            )

            section(
                title: "文章の仕上げ",
                caption: "文字起こしを読める文章に整えます。うまくいかないときは、整えずにそのまま挿入します。",
                choices: env.engines.formattingChoices,
                selectedID: FormattingCatalog.choice(
                    engine: settings.llmEngineID,
                    modelID: settings.mlxModelID
                )?.id,
                measured: env.measuredLatencies.formatting,
                select: { choice in Task { await env.selectFormatting(choice) } }
            )

            SettingsCard(
                title: "待ち時間の上限",
                footnote: "ここを過ぎたら仕上げを打ち切り、文字起こしをそのまま挿入します。"
            ) {
                LabeledContent("仕上げを待つ上限") {
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

            if env.modelDiskUsage > 0 {
                SettingsCard(title: "ダウンロード済み", footnote: "~/Library/Application Support/Koe/models に保存されます。") {
                    HStack {
                        Text(ByteCountFormatter.string(fromByteCount: env.modelDiskUsage, countStyle: .file))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                        Spacer()
                        Button("すべて削除", role: .destructive) {
                            Task { await env.deleteDownloadedModels() }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .task { await env.reloadMeasuredLatencies() }
    }

    @ViewBuilder
    private func section(
        title: String,
        caption: String,
        choices: [ModelChoice],
        selectedID: ModelChoice.ID?,
        measured: [String: LatencyStats],
        select: @escaping (ModelChoice) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                ForEach(choices) { choice in
                    ModelChoiceCard(
                        choice: choice,
                        isSelected: choice.id == selectedID,
                        availability: env.engines.availability(for: choice),
                        measured: measured[choice.latencyKey(modelName: Self.measuredModelName(for: choice))],
                        downloadProgress: env.downloadingChoiceID == choice.id ? env.modelDownloadProgress : nil,
                        onSelect: { select(choice) },
                        onDownload: { Task { await env.download(choice) } }
                    )
                }
            }

            Text("正確さと速さの帯は目安です。「実測」はあなたの履歴から集計した実際の時間です。")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)

            if let error = env.modelDownloadError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(KoeTheme.recording)
            }
        }
    }

    /// 履歴にはエンジンが返す表示名で記録されているため、実測を引くキーも同じ名前で作る。
    static func measuredModelName(for choice: ModelChoice) -> String? {
        switch choice.engine {
        case .speechAnalyzer: "システム音声モデル"
        case .foundationModels: "Apple Foundation Models"
        default: choice.name
        }
    }
}

/// 1 つの選択肢のカード。正確さ・速さの目安と実測時間を並べる。
private struct ModelChoiceCard: View {
    var choice: ModelChoice
    var isSelected: Bool
    var availability: EngineAvailability
    var measured: LatencyStats?
    var downloadProgress: Double?
    var onSelect: () -> Void
    var onDownload: () -> Void

    @State private var isHovering = false

    private var isUsable: Bool {
        if case .unavailable = availability { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            Text(choice.summary)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 21)
            meters
                .padding(.leading, 21)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: KoeTheme.cardCornerRadius, style: .continuous)
                .fill(isSelected ? KoeTheme.accent.opacity(0.09) : Color.secondary.opacity(isHovering ? 0.09 : 0.05))
        }
        .overlay {
            RoundedRectangle(cornerRadius: KoeTheme.cardCornerRadius, style: .continuous)
                .strokeBorder(isSelected ? KoeTheme.accent.opacity(0.5) : .clear, lineWidth: 1)
        }
        .opacity(isUsable ? 1 : 0.55)
        .contentShape(.rect)
        .onTapGesture { if isUsable { onSelect() } }
        .onHover { isHovering = $0 }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? KoeTheme.accent : Color.secondary.opacity(0.5))

            Text(choice.name)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))

            if !choice.requiresDownload {
                Text("ダウンロード不要")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background { Capsule().fill(.secondary.opacity(0.14)) }
            }

            Spacer()
            trailing
        }
    }

    private var meters: some View {
        HStack(alignment: .top, spacing: 26) {
            RatingMeter(label: "正確さ", value: choice.rating.accuracy, tint: KoeTheme.accent)
            RatingMeter(label: "速さ", value: choice.rating.speed, tint: KoeTheme.accentSecondary)
            if let measured, measured.count > 0 {
                VStack(alignment: .leading, spacing: 3) {
                    Text("実測")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(Self.secondsText(measured.p50Ms))
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(KoeTheme.accent)
                    Text("\(measured.count) 回の中央値")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if let downloadProgress {
            ProgressView(value: downloadProgress)
                .frame(width: 110)
        } else {
            switch availability {
            case .ready:
                if let size = choice.downloadSizeText {
                    Label("ダウンロード済み \(size)", systemImage: "checkmark.circle")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                }
            case .needsDownload:
                Button("ダウンロード", action: onDownload)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            case .unavailable(let reason):
                Text(reason)
                    .font(.system(size: 10.5))
                    .foregroundStyle(KoeTheme.warning)
                    .multilineTextAlignment(.trailing)
                    .frame(maxWidth: 220)
            }
        }
    }

    static func secondsText(_ ms: Int) -> String {
        ms >= 1_000 ? String(format: "%.1f 秒", Double(ms) / 1_000) : "\(ms) ミリ秒"
    }
}

/// 5 段階の目安メーター。
private struct RatingMeter: View {
    var label: String
    var value: Int
    var tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
            HStack(spacing: 2.5) {
                ForEach(1...5, id: \.self) { step in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(step <= value ? tint : Color.secondary.opacity(0.2))
                        .frame(width: 12, height: 5)
                }
            }
        }
    }
}
