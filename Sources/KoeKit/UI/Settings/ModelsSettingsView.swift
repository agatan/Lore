import SwiftUI

/// 使っているモデルの状態と実測の速さ(FR-9)。
///
/// 選べるのは「聞き取り」と「仕上げ」の 2 段だけ。どちらも既定は追加ダウンロード無しの
/// OS 内蔵モデルで、変えたときに何が変わるか(外に出るか / 待ち方が変わるか)を
/// その場で読めるようにする。
struct ModelsSettingsView: View {
    var env: AppEnvironment

    private var settings: AppSettings { env.settings }

    @State private var apiKeyDraft = ""

    private var backend: FormattingBackend { settings.formattingBackend }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if backend.sendsTranscriptOffDevice {
                NoticeBanner(
                    title: "文章だけを \(backend.displayName) に送ります",
                    message: "音声認識はMac内で完結します。整形・ライフログ要約・TODOのため、文字起こし、予定、メモと指示文を送ります。音声ファイルは送りません。",
                    tint: KoeTheme.warning,
                    actionTitle: nil,
                    action: nil
                )
            } else {
                NoticeBanner(
                    title: "この Mac の中だけで動きます",
                    message: backend == .onDevice
                        ? "音声認識と文章処理をmacOS内蔵モデルで行います。"
                        : "音声認識と文章処理をこのMac上で行います。ローカルサーバーを起動して使います。",
                    tint: KoeTheme.accent,
                    actionTitle: nil,
                    action: nil
                )
            }

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
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            SettingsCard(
                title: "文章の仕上げ",
                footnote: "音声入力の整形と、ライフログの要約・TODOに共通して使います。"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("このMac内")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        providerButton(.onDevice, icon: "apple.logo")
                        providerButton(.ollama, icon: "shippingbox")
                        providerButton(.lmStudio, icon: "desktopcomputer")
                    }
                    Text("クラウド")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                    HStack(spacing: 8) {
                        providerButton(.openAI, icon: "sparkles")
                        providerButton(.anthropic, icon: "text.bubble")
                        providerButton(.gemini, icon: "diamond")
                        providerButton(.groq, icon: "bolt")
                    }
                }

                Divider()

                engineRow(
                    name: activeModelName,
                    availability: env.engines.llmAvailability,
                    measured: env.measuredLatencies.formatting[activeLatencyKey],
                    canInstall: false
                )

                if backend != .onDevice {
                    Divider()
                    providerSettings
                }
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
        .task {
            await env.reloadMeasuredLatencies()
            await env.applyEngineChange()
        }
    }

    private var activeModelName: String {
        backend == .onDevice ? "Apple Foundation Models" : "\(backend.displayName) / \(settings.model(for: backend))"
    }

    private var activeLatencyKey: String {
        HistoryStore.key(env.engines.llm.identifier.rawValue, settings.model(for: backend))
    }

    @ViewBuilder
    private func providerButton(_ option: FormattingBackend, icon: String) -> some View {
        Button {
            settings.formattingBackend = option
            apiKeyDraft = ""
            Task { await env.applyEngineChange(resetConnectionState: true) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Text(option.displayName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(backend == option ? Color.white : Color.primary)
            .background(backend == option ? KoeTheme.accent : Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    /// 選択中の接続先だけを見せる。キーはKeychainに入れ、保存後は画面に残さない。
    @ViewBuilder
    private var providerSettings: some View {
        if backend.sendsTranscriptOffDevice {
            SettingsRow(
                title: "API キー",
                caption: env.hasLlmApiKey ? "キーチェーンに登録済み" : "Koeはキーの内容を表示しません"
            ) {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKeyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onSubmit { save() }
                    Button("保存") { save() }
                        .controlSize(.small)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if env.hasLlmApiKey {
                        Button("削除") {
                            apiKeyDraft = ""
                            Task { await env.setLlmApiKey("") }
                        }
                        .controlSize(.small)
                    }
                }
            }
        }

        SettingsRow(title: "モデル", caption: localServerCaption) {
            HStack(spacing: 8) {
                if env.llmModels.isEmpty {
                    TextField("", text: Binding(
                        get: { settings.model(for: backend) },
                        set: { settings.setModel($0, for: backend); Task { await env.applyEngineChange(checkCredentials: false) } }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 230)
                } else {
                    Picker("", selection: Binding(
                        get: { settings.model(for: backend) },
                        set: { settings.setModel($0, for: backend); Task { await env.applyEngineChange(checkCredentials: false) } }
                    )) {
                        ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 230)
                }
            }
        }

        HStack(spacing: 10) {
            Button(env.isCheckingLlm ? "確認中…" : "接続を確認") {
                Task { await env.checkLlmConnection() }
            }
            .controlSize(.small)
            .disabled(env.isCheckingLlm || (backend.sendsTranscriptOffDevice && !env.hasLlmApiKey))

            if let status = env.llmStatus {
                Text(status)
                    .font(.system(size: 10.5))
                    .foregroundStyle(env.engines.llmAvailability.isReady ? KoeTheme.success : KoeTheme.recording)
                    .lineLimit(2)
            }
        }
    }

    /// 一覧に無いモデルを設定していても選択が消えないようにする。
    private var modelChoices: [String] {
        let selected = settings.model(for: backend)
        return env.llmModels.contains(selected) ? env.llmModels : [selected] + env.llmModels
    }

    private var localServerCaption: String {
        switch backend {
        case .ollama: "Ollamaを起動してから確認 · localhost:11434"
        case .lmStudio: "DeveloperでServerを開始 · localhost:1234"
        default: "接続確認で利用可能なモデルを取得"
        }
    }

    private func save() {
        let key = apiKeyDraft
        apiKeyDraft = ""
        Task { await env.setLlmApiKey(key) }
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
