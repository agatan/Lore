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
            SettingsCard(title: "音声入力の整形", footnote: "ライフログの文字起こしは整形せず、外部にも送りません。") {
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
            title: backend.sendsTranscriptOffDevice
                ? String(lore: "文字起こしを\(backend.displayName)に送ります")
                : "このMacの中で処理します",
            message: noticeMessage,
            tint: backend.sendsTranscriptOffDevice ? LoreTheme.warning : LoreTheme.accent,
            symbol: backend.sendsTranscriptOffDevice ? "exclamationmark.triangle.fill" : "lock.fill",
            actionTitle: nil,
            action: nil
        )
    }

    private var noticeMessage: String {
        if backend.sendsTranscriptOffDevice {
            return "整形のため、その回の文字起こしと指示文、語彙を送ります。音声とライフログは送りません。"
        }
        if backend == .onDevice {
            return "macOSに内蔵されたモデルで整形します。"
        }
        return "このMacで動いているローカルサーバーで整形します。"
    }

    private var providerPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("このMac内").font(.system(size: LoreTheme.TextSize.caption, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                providerButton(.onDevice, icon: "apple.logo")
                providerButton(.ollama, icon: "shippingbox")
                providerButton(.lmStudio, icon: "desktopcomputer")
            }
            Text("クラウド").font(.system(size: LoreTheme.TextSize.caption, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 4)
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
                Image(systemName: icon).font(.system(size: LoreTheme.TextSize.reading, weight: .medium))
                Text(option.displayName).font(.system(size: LoreTheme.TextSize.caption, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(backend == option ? LoreTheme.accent : Color.primary)
            .overlay(alignment: .topTrailing) {
                if backend == option {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: LoreTheme.TextSize.micro))
                        .foregroundStyle(LoreTheme.accent)
                        .padding(7)
                }
            }
            .glassEffect(
                backend == option
                    ? .regular.tint(LoreTheme.accent.opacity(0.24)).interactive()
                    : .regular.interactive(),
                in: RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }

    private var engineStatus: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(activeModelName).font(.system(size: LoreTheme.TextSize.body, weight: .medium))
            Spacer()
            availabilityLabel(env.engines.llmAvailability, canInstall: false)
        }
    }

    @ViewBuilder
    private var providerSettings: some View {
        if backend.sendsTranscriptOffDevice {
            SettingsRow(title: "APIキー", caption: env.hasLlmApiKey ? "キーチェーンに保存済み" : "キーチェーンに保存します") {
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
                Text(status).font(.system(size: LoreTheme.TextSize.caption))
                    .foregroundStyle(env.engines.llmAvailability.isReady ? LoreTheme.success : LoreTheme.danger)
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
        SettingsCard(title: "待ち時間", footnote: "この時間を過ぎると整形をやめ、文字起こしをそのまま入力します。") {
            SettingsRow(title: "整形を待つ時間") {
                HStack(spacing: 10) {
                    Slider(value: Binding(get: { Double(settings.formattingTimeoutMs) }, set: { settings.formattingTimeoutMs = Int($0) }), in: 2_000...20_000, step: 500).frame(width: 190)
                    Text("\(String(format: "%.1f", Double(settings.formattingTimeoutMs) / 1_000)) 秒")
                        .font(.system(size: LoreTheme.TextSize.caption)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func availabilityLabel(_ availability: EngineAvailability, canInstall: Bool) -> some View {
        switch availability {
        case .ready:
            Label("使えます", systemImage: "checkmark.circle").font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.success)
        case .needsDownload(let reason):
            HStack(spacing: 8) {
                Text(reason).font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.warning)
                if canInstall { Button("取得") { Task { await env.installSpeechAssets() } }.controlSize(.small) }
            }
        case .unavailable(let reason):
            Text(reason).font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.danger).frame(maxWidth: 260)
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
        default: "接続を確認すると、使えるモデルを選べます"
        }
    }

    private func saveKey() {
        let key = apiKeyDraft
        apiKeyDraft = ""
        Task { await env.setLlmApiKey(key) }
    }
}
