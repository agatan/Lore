import SwiftUI

/// 音声入力の整形とライフログの派生処理は、接続先・モデル・APIキーを用途ごとに保持する。
struct ModelsSettingsView: View {
    var env: AppEnvironment
    var purpose: LlmPurpose = .dictation

    @State private var apiKeyDraft = ""

    private var settings: AppSettings { env.settings }
    private var backend: FormattingBackend { settings.backend(for: purpose) }
    private var title: String { purpose == .dictation ? "音声入力の整形" : "要約とTODO" }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            privacyNotice
            if purpose == .dictation { speechRecognitionCard }
            SettingsCard(
                title: title,
                footnote: purpose == .dictation
                    ? "音声入力の文章を整えます。ライフログとは別に選べます。"
                    : "一日の要約とTODO案を作ります。音声入力とは別に選べます。"
            ) {
                providerPicker
                Divider()
                engineStatus
                if backend != .onDevice {
                    Divider()
                    providerSettings
                }
            }
            if purpose == .dictation { timeoutCard } else { promptCard }
        }
        .task {
            await env.reloadMeasuredLatencies()
            await env.applyEngineChange(purpose: purpose, checkCredentials: !AppEnvironment.usesScreenshotDemoData)
        }
    }

    private var privacyNotice: some View {
        NoticeBanner(
            title: backend.sendsTranscriptOffDevice ? "文章だけを \(backend.displayName) に送ります" : "この Mac の中だけで動きます",
            message: noticeMessage,
            tint: backend.sendsTranscriptOffDevice ? KoeTheme.warning : KoeTheme.accent,
            actionTitle: nil,
            action: nil
        )
    }

    private var noticeMessage: String {
        if backend.sendsTranscriptOffDevice {
            return purpose == .dictation
                ? "整形のため、文字起こしと指示文を送ります。音声ファイルは送りません。"
                : "要約とTODO案のため、対象日の発話、メモ、予定と指示文を送ります。音声ファイルは送りません。"
        }
        if backend == .onDevice {
            return purpose == .dictation
                ? "聞き取りと整形をmacOS内蔵モデルで行います。"
                : "要約とTODO案をmacOS内蔵モデルで作ります。"
        }
        return "文章処理をこのMac上のローカルサーバーで行います。"
    }

    private var speechRecognitionCard: some View {
        SettingsCard(title: "聞き取り", footnote: "音声入力とライフログの文字起こしに共通です。語彙も両方で共有します。") {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Apple 音声認識 (SpeechAnalyzer)").font(.system(size: 13, weight: .medium))
                Spacer()
                availabilityLabel(env.engines.sttAvailability, canInstall: true)
            }
            if let error = env.speechAssetError {
                Text(error).font(.system(size: 11)).foregroundStyle(KoeTheme.recording)
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
            settings.setBackend(option, for: purpose)
            apiKeyDraft = ""
            Task { await env.applyEngineChange(purpose: purpose, resetConnectionState: true) }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium))
                Text(option.displayName).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(backend == option ? KoeTheme.accent : Color.primary)
            .overlay(alignment: .topTrailing) {
                if backend == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(KoeTheme.accent)
                        .padding(7)
                }
            }
            .glassEffect(
                backend == option
                    ? .regular.tint(KoeTheme.accent.opacity(0.24)).interactive()
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
            availabilityLabel(env.llmAvailability(for: purpose), canInstall: false)
        }
    }

    @ViewBuilder
    private var providerSettings: some View {
        if backend.sendsTranscriptOffDevice {
            SettingsRow(title: "API キー", caption: env.hasLlmApiKey(for: purpose) ? "この用途のキーをキーチェーンに登録済み" : "用途ごとに別のキーを登録できます") {
                HStack(spacing: 8) {
                    SecureField("API key", text: $apiKeyDraft).textFieldStyle(.roundedBorder).frame(width: 180).onSubmit(saveKey)
                    Button("保存", action: saveKey).controlSize(.small)
                        .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if env.hasLlmApiKey(for: purpose) {
                        Button("削除") { Task { await env.setLlmApiKey("", purpose: purpose) } }.controlSize(.small)
                    }
                }
            }
        }

        SettingsRow(title: "モデル", caption: localServerCaption) {
            if env.llmModels(for: purpose).isEmpty {
                TextField("", text: modelBinding).textFieldStyle(.roundedBorder).frame(width: 230)
            } else {
                Picker("", selection: modelBinding) {
                    ForEach(modelChoices, id: \.self) { Text($0).tag($0) }
                }.labelsHidden().frame(width: 230, alignment: .trailing)
            }
        }

        HStack(spacing: 10) {
            Button(env.isCheckingLlm(for: purpose) ? "確認中…" : "接続を確認") {
                Task { await env.checkLlmConnection(purpose: purpose) }
            }
            .controlSize(.small)
            .disabled(env.isCheckingLlm(for: purpose) || (backend.sendsTranscriptOffDevice && !env.hasLlmApiKey(for: purpose)))
            if let status = env.llmStatus(for: purpose) {
                Text(status).font(.system(size: 10.5))
                    .foregroundStyle(env.llmAvailability(for: purpose).isReady ? KoeTheme.success : KoeTheme.recording)
                    .lineLimit(2)
            }
        }
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.model(for: backend, purpose: purpose) },
            set: { value in
                settings.setModel(value, for: backend, purpose: purpose)
                Task { await env.applyEngineChange(purpose: purpose, checkCredentials: false) }
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

    private var promptCard: some View {
        SettingsCard(title: "指示文", footnote: "要約と未確定のTODO案を、この指示文から作ります。") {
            promptEditor("日次要約", text: Binding(get: { settings.lifeLogSummaryPrompt }, set: { settings.lifeLogSummaryPrompt = $0 }))
            promptEditor("TODO", text: Binding(get: { settings.lifeLogTodoPrompt }, set: { settings.lifeLogTodoPrompt = $0 }))
            HStack {
                Spacer()
                Button("標準に戻す") {
                    settings.lifeLogSummaryPrompt = BuiltinLifeLogPrompts.summary
                    settings.lifeLogTodoPrompt = BuiltinLifeLogPrompts.todo
                }
            }
        }
    }

    private func promptEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: text).font(.system(size: 11.5, design: .monospaced))
                .frame(height: 104).scrollContentBackground(.hidden).padding(7).sunkenSurface()
        }
    }

    @ViewBuilder
    private func availabilityLabel(_ availability: EngineAvailability, canInstall: Bool) -> some View {
        switch availability {
        case .ready:
            Label("使えます", systemImage: "checkmark.circle").font(.system(size: 10.5)).foregroundStyle(KoeTheme.success)
        case .needsDownload(let reason):
            HStack(spacing: 8) {
                Text(reason).font(.system(size: 10.5)).foregroundStyle(KoeTheme.warning)
                if canInstall { Button("取得") { Task { await env.installSpeechAssets() } }.controlSize(.small) }
            }
        case .unavailable(let reason):
            Text(reason).font(.system(size: 10.5)).foregroundStyle(KoeTheme.recording).frame(maxWidth: 260)
        }
    }

    private var activeModelName: String {
        backend == .onDevice ? "Apple Foundation Models" : "\(backend.displayName) / \(settings.model(for: backend, purpose: purpose))"
    }

    private var modelChoices: [String] {
        let selected = settings.model(for: backend, purpose: purpose)
        let models = env.llmModels(for: purpose)
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
        Task { await env.setLlmApiKey(key, purpose: purpose) }
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
