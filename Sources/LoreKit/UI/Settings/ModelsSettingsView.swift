import SwiftUI

/// 音声入力の整形に使う接続先・モデル・APIキー。
struct ModelsSettingsView: View {
    var env: AppEnvironment

    @State private var apiKeyDraft = ""

    private var settings: AppSettings { env.settings }
    private var backend: FormattingBackend { settings.formattingBackend }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            privacyNotice
            speechRecognitionCard
            SettingsCard(title: "音声入力の整形", footnote: "音声入力の文章を整えます。ライフログの文字は整形にも外部送信にも使いません。") {
                providerPicker
                engineStatus
                if backend != .onDevice {
                    providerSettings
                }
            }
            timeoutCard
        }
        .task {
            await env.reloadMeasuredLatencies()
            await env.applyEngineChange(checkCredentials: !AppEnvironment.usesScreenshotDemoData)
        }
    }

    private var privacyNotice: some View {
        NoticeBanner(
            title: backend.sendsTranscriptOffDevice ? "文章だけを \(backend.displayName) に送ります" : "この Mac の中だけで動きます",
            message: noticeMessage,
            tint: backend.sendsTranscriptOffDevice ? LoreTheme.warning : LoreTheme.accent,
            symbol: backend.sendsTranscriptOffDevice ? "exclamationmark.triangle.fill" : "lock.fill",
            actionTitle: nil,
            action: nil
        )
    }

    private var noticeMessage: String {
        if backend.sendsTranscriptOffDevice {
            return "整形のため、文字起こしと指示文を送ります。音声ファイルは送りません。"
        }
        if backend == .onDevice {
            return "聞き取りと整形をmacOS内蔵モデルで行います。"
        }
        return "文章処理をこのMac上のローカルサーバーで行います。"
    }

    private var speechRecognitionCard: some View {
        SettingsCard(title: "聞き取り", footnote: "SpeechAnalyzerを選んだ音声入力とライフログで使います。whisper.cppは各設定で選べます。語彙は両方で共有します。") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Apple 音声認識 (SpeechAnalyzer)").font(.system(size: 13, weight: .medium))
                Spacer()
                availabilityLabel(env.engines.sttAvailability, canInstall: true)
            }
            if let error = env.speechAssetError {
                Text(error).font(.system(size: 11)).foregroundStyle(LoreTheme.recording)
            }
        }
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("このMac内").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                providerButton(.onDevice, icon: "apple.logo")
                providerButton(.ollama, icon: "shippingbox")
                providerButton(.lmStudio, icon: "desktopcomputer")
            }
            Text("クラウド").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
            HStack(spacing: 8) {
                providerButton(.openAI, icon: "sparkles")
                providerButton(.anthropic, icon: "text.bubble")
                providerButton(.gemini, icon: "diamond")
                providerButton(.groq, icon: "bolt")
            }
        }
    }

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
            .foregroundStyle(backend == option ? LoreTheme.accent : Color.primary)
            .overlay(alignment: .topTrailing) {
                if backend == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(LoreTheme.accent)
                        .padding(7)
                }
            }
            .glassEffect(
                backend == option
                    ? .regular.tint(LoreTheme.accent.opacity(0.24)).interactive()
                    : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var engineStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(activeModelName).font(.system(size: 13, weight: .medium))
            Spacer()
            availabilityLabel(env.engines.llmAvailability, canInstall: false)
        }
    }

    @ViewBuilder
    private var providerSettings: some View {
        if backend.sendsTranscriptOffDevice {
            SettingsRow(title: "API キー", caption: env.hasLlmApiKey ? "キーチェーンに登録済み" : "キーチェーンに保存します") {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKeyDraft).textFieldStyle(.roundedBorder).frame(width: 180).onSubmit(saveKey)
                    Button("保存", action: saveKey).controlSize(.small)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if env.hasLlmApiKey {
                        Button("削除") { Task { await env.setLlmApiKey("") } }.controlSize(.small)
                    }
                }
            }
        }

        SettingsRow(title: "モデル", caption: localServerCaption) {
            if env.llmModels.isEmpty {
                TextField("", text: modelBinding).textFieldStyle(.roundedBorder).frame(width: 230)
            } else {
                Picker("", selection: modelBinding) {
                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 230, alignment: .trailing)
            }
        }

        HStack(spacing: 10) {
            Button(env.isCheckingLlm ? "確認中…" : "接続を確認") {
                Task { await env.checkLlmConnection() }
            }
            .controlSize(.small)
            .disabled(env.isCheckingLlm || (backend.sendsTranscriptOffDevice && !env.hasLlmApiKey))
            if let status = env.llmStatus {
                Text(status).font(.system(size: 10.5))
                    .foregroundStyle(env.engines.llmAvailability.isReady ? LoreTheme.success : LoreTheme.recording)
                    .lineLimit(2)
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.model(for: backend) },
            set: { value in
                settings.setModel(value, for: backend)
                Task { await env.applyEngineChange(checkCredentials: false) }
            }
        )
    }

    private var timeoutCard: some View {
        SettingsCard(title: "待ち時間の上限", footnote: "時間を過ぎたら整形を打ち切り、文字起こしをそのまま挿入します。") {
            SettingsRow(title: "仕上げを待つ上限") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { Double(settings.formattingTimeoutMs) }, set: { settings.formattingTimeoutMs = Int($0) }), in: 2_000...20_000, step: 500).frame(width: 190)
                    Text(String(format: "%.1f 秒", Double(settings.formattingTimeoutMs) / 1_000))
                        .font(.system(size: 11, design: .rounded)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func availabilityLabel(_ availability: EngineAvailability, canInstall: Bool) -> some View {
        switch availability {
        case .ready:
            Label("使えます", systemImage: "checkmark.circle").font(.system(size: 10.5)).foregroundStyle(LoreTheme.success)
        case .needsDownload(let reason):
            HStack(spacing: 8) {
                Text(reason).font(.system(size: 10.5)).foregroundStyle(LoreTheme.warning)
                if canInstall { Button("取得") { Task { await env.installSpeechAssets() } }.controlSize(.small) }
            }
        case .unavailable(let reason):
            Text(reason).font(.system(size: 10.5)).foregroundStyle(LoreTheme.recording).frame(maxWidth: 260)
        }
    }

    private var activeModelName: String {
        backend == .onDevice ? "Apple Foundation Models" : "\(backend.displayName) / \(settings.model(for: backend))"
    }

    private var modelChoices: [String] {
        let selected = settings.model(for: backend)
        let models = env.llmModels
        return models.contains(selected) ? models : [selected] + models
    }

    private var localServerCaption: String {
        switch backend {
        case .ollama: "Ollama · localhost:11434"
        case .lmStudio: "LM Studio · localhost:1234"
        default: "接続確認で利用可能なモデルを取得"
        }
    }

    private func saveKey() {
        let key = apiKeyDraft
        apiKeyDraft = ""
        Task { await env.setLlmApiKey(key) }
    }

    static func speedLines(_ stats: LatencyStats) -> [String] {
        guard let factor = stats.realtimeFactor else { return ["実測 \(secondsText(stats.p50Ms))", "\(stats.count) 回の中央値"] }
        let text = factor < 1 ? String(format: "%.2f 倍", factor) : String(format: "%.1f 倍", factor)
        return ["音声の長さの \(text)", "音声 10 秒 → \(secondsText(Int(factor * 10_000)))", "\(stats.realtimeFactorCount) 回の中央値"]
    }

    static func secondsText(_ ms: Int) -> String {
        ms >= 1_000 ? String(format: "%.1f 秒", Double(ms) / 1_000) : "\(ms) ミリ秒"
    }
}
