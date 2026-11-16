import SwiftUI

/// 設定 > AIプロバイダ。LLMの選択とAPIキーはすべてここで扱う。
/// 音声入力の整形とライフログAIは同じ`AIProviderForm`で選ぶので、見た目も操作も揃う。
struct AIProvidersSettingsView: View {
    var env: AppEnvironment

    /// クラウドへの送信を新たに始めるライフログAIの変更。確認するまで何も保存しない。
    @State private var pendingLifeLogAI: LifeLogAISettings?

    private var settings: AppSettings { env.settings }
    private var formatting: FormattingBackend { settings.formattingBackend }
    private var lifeLogAI: LifeLogAISettings { settings.lifeLogAI }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "音声入力の整形", footnote: formattingFootnote) {
                AIProviderForm(
                    env: env,
                    identifier: "ai-providers.formatting",
                    backend: formatting,
                    model: settings.model(for: formatting),
                    select: { backend in
                        settings.formattingBackend = backend
                        Task { await env.applyEngineChange() }
                    },
                    setModel: { model in
                        settings.setModel(model, for: formatting)
                        Task { await env.applyEngineChange(checkCredentials: false) }
                    }
                )
                SettingsRow(title: "整形を待つ時間", caption: "この時間を過ぎると整形をやめ、文字起こしをそのまま入力します。") {
                    HStack(spacing: 10) {
                        Slider(value: Binding(get: { Double(settings.formattingTimeoutMs) }, set: { settings.formattingTimeoutMs = Int($0) }), in: 2_000...20_000, step: 500).frame(width: 190)
                        Text("\(String(format: "%.1f", Double(settings.formattingTimeoutMs) / 1_000)) 秒")
                            .font(.system(size: LoreTheme.TextSize.caption)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }

            SettingsCard(title: "ライフログAI", footnote: "オン・オフ、送る内容、作成のタイミングは「ライフログAI」で設定します。オフの間は、ライフログの文章をどこにも送りません。") {
                AIProviderForm(
                    env: env,
                    identifier: "ai-providers.life-log-ai",
                    backend: lifeLogAI.backend,
                    model: lifeLogAI.model,
                    select: { backend in
                        var next = lifeLogAI
                        next.backend = backend
                        next.model = backend.defaultModel
                        pendingLifeLogAI = env.applyLifeLogAIChange(next)
                    },
                    setModel: { model in
                        var next = lifeLogAI
                        next.model = model
                        pendingLifeLogAI = env.applyLifeLogAIChange(next)
                    }
                )
                SettingsRow(title: "ライフログAI", caption: lifeLogAI.isEnabled ? "オン" : "オフ") {
                    Button("ライフログAIを開く") { env.settingsSection = .lifeLogAI }.controlSize(.small)
                }
            }

            APIKeysCard(env: env)
        }
        .accessibilityIdentifier("ai-providers.settings.root")
        .lifeLogAICloudConfirmation($pendingLifeLogAI, env: env)
        .task {
            await env.reloadMeasuredLatencies()
            await env.applyEngineChange(checkCredentials: !AppEnvironment.usesScreenshotDemoData)
        }
    }

    private var formattingFootnote: String {
        if formatting.sendsTranscriptOffDevice {
            return String(lore: "整形のため、その回の文字起こしと指示文、語彙を送ります。音声とライフログは送りません。")
        }
        if formatting == .onDevice {
            return String(lore: "macOSに内蔵されたモデルで整形します。")
        }
        return String(lore: "このMacで動いているローカルサーバーで整形します。")
    }
}

/// 1つの用途のプロバイダとモデル。整形とライフログAIで同じものを使う。
struct AIProviderForm: View {
    var env: AppEnvironment
    /// accessibility identifierの接頭辞。
    var identifier: String
    var backend: FormattingBackend
    var model: String
    var select: (FormattingBackend) -> Void
    var setModel: (String) -> Void

    @State private var modelDraft = ""
    /// `modelDraft`を入力したときのプロバイダ。切り替え後に前のプロバイダの下書きを保存しないために持つ。
    @State private var draftBackend: FormattingBackend?
    @State private var onDeviceAvailability: EngineAvailability = .ready

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            providerGroup("このMac内", [(.onDevice, "apple.logo"), (.ollama, "shippingbox"), (.lmStudio, "desktopcomputer")])
            providerGroup("クラウド", [(.openAI, "sparkles"), (.anthropic, "text.bubble"), (.gemini, "diamond"), (.groq, "bolt")])
                .padding(.top, 4)
        }
        .padding(.vertical, 4)

        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: backend == .onDevice ? backend.displayName : "\(backend.displayName) / \(model)")
                .font(.system(size: LoreTheme.TextSize.body, weight: .medium))
                .accessibilityIdentifier("\(identifier).active")
            Spacer()
            availabilityLabel
        }
        .task(id: backend) {
            guard backend == .onDevice else { return }
            onDeviceAvailability = await env.engines.standaloneEngine(backend: .onDevice, model: model).availability()
        }

        if backend != .onDevice {
            SettingsRow(title: "モデル", caption: localServerCaption) { modelControl }
            connectionCheck
        }
    }

    private func providerGroup(_ title: String, _ options: [(FormattingBackend, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: LoreTheme.TextSize.caption, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(options, id: \.0) { option, icon in providerButton(option, icon: icon) }
            }
        }
    }

    private func providerButton(_ option: FormattingBackend, icon: String) -> some View {
        Button {
            guard option != backend else { return }
            commitPendingModel()
            select(option)
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: LoreTheme.TextSize.reading, weight: .medium))
                Text(verbatim: option.displayName).font(.system(size: LoreTheme.TextSize.caption, weight: .medium)).lineLimit(1)
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
        .accessibilityIdentifier("\(identifier).provider.\(option.rawValue)")
    }

    /// 接続確認でモデル一覧が取れたプロバイダは一覧から選び、それ以外は名前を入力する。
    @ViewBuilder
    private var modelControl: some View {
        let models = env.llmModels[backend] ?? []
        if models.isEmpty {
            TextField("", text: $modelDraft)
                .textFieldStyle(.roundedBorder)
                .frame(width: 230)
                .onSubmit(commitModel)
                .onAppear(perform: resetDraft)
                .onChange(of: model, resetDraft)
                .onChange(of: backend, resetDraft)
                .onDisappear { commitPendingModel() }
                .accessibilityIdentifier("\(identifier).model")
        } else {
            Picker("", selection: Binding(get: { model }, set: setModel)) {
                ForEach(models.contains(model) ? models : [model] + models, id: \.self) { Text(verbatim: $0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 230, alignment: .trailing)
            .accessibilityIdentifier("\(identifier).model")
        }
    }

    private var connectionCheck: some View {
        HStack(spacing: 10) {
            Button(env.checkingLlmBackend == backend ? "確認中…" : "接続を確認") {
                let checked = commitPendingModel() ?? model
                Task { await env.checkLlmConnection(backend: backend, model: checked) }
            }
            .controlSize(.small)
            .disabled(env.checkingLlmBackend != nil || (backend.sendsTranscriptOffDevice && !env.storedApiKeys.contains(backend)))
            if let check = env.llmChecks[backend], check.model == model {
                Text(verbatim: check.message).font(.system(size: LoreTheme.TextSize.caption))
                    .foregroundStyle(check.succeeded ? LoreTheme.success : LoreTheme.danger)
                    .lineLimit(2)
            }
        }
    }

    /// クラウドはキーの有無、ローカルサーバーは接続確認で分かるので、ここではOS内蔵モデルだけを問い合わせる。
    @ViewBuilder
    private var availabilityLabel: some View {
        if backend.sendsTranscriptOffDevice, !env.storedApiKeys.contains(backend) {
            Text(String(lore: "\(backend.displayName) のAPIキーが未設定です"))
                .font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.warning)
        } else if backend == .onDevice, case .unavailable(let reason) = onDeviceAvailability {
            Text(reason).font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.danger).frame(maxWidth: 260)
        } else if backend == .onDevice, case .needsDownload(let reason) = onDeviceAvailability {
            Text(reason).font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.warning)
        } else {
            Label("使えます", systemImage: "checkmark.circle").font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.success)
        }
    }

    private var localServerCaption: String {
        switch backend {
        case .ollama: "Ollama · localhost:11434"
        case .lmStudio: "LM Studio · localhost:1234"
        default: "接続を確認すると、使えるモデルを選べます"
        }
    }

    private func resetDraft() {
        modelDraft = model
        draftBackend = backend
    }

    private func commitModel() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = trimmed.isEmpty ? backend.defaultModel : trimmed
        modelDraft = next
        if next != model { setModel(next) }
    }

    /// Returnを押す前に別の操作へ移っても、入力中のモデル名を今のプロバイダに保存する。保存したモデル名を返す。
    @discardableResult
    private func commitPendingModel() -> String? {
        guard draftBackend == backend, modelDraft != model else { return nil }
        commitModel()
        return modelDraft
    }
}

/// クラウドプロバイダごとのAPIキー。どの用途が選んでいるかに関係なく、ここで登録・削除する。
private struct APIKeysCard: View {
    var env: AppEnvironment

    @State private var drafts: [FormattingBackend: String] = [:]

    private static let providers: [FormattingBackend] = FormattingBackend.allCases.filter(\.sendsTranscriptOffDevice)

    var body: some View {
        SettingsCard(title: "APIキー", footnote: "キーはこのMacのキーチェーンに保存し、同期しません。1つのキーを音声入力の整形とライフログAIの両方で使います。") {
            ForEach(Self.providers) { backend in
                SettingsRow(title: backend.displayName, caption: caption(for: backend)) {
                    HStack(spacing: 8) {
                        SecureField("API key", text: draft(backend))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .onSubmit { save(backend) }
                            .accessibilityIdentifier("ai-providers.api-key.\(backend.rawValue)")
                        Button("保存") { save(backend) }
                            .controlSize(.small)
                            .disabled((drafts[backend] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        if env.storedApiKeys.contains(backend) {
                            Button("削除") { Task { await env.setApiKey("", for: backend) } }.controlSize(.small)
                        }
                    }
                }
            }
            if let error = env.apiKeyError {
                Text(verbatim: error).font(LoreTheme.captionFont).foregroundStyle(LoreTheme.danger)
            }
        }
    }

    private func caption(for backend: FormattingBackend) -> String {
        var parts = [env.storedApiKeys.contains(backend) ? String(lore: "キーチェーンに保存済み") : String(lore: "未登録")]
        let formatting = env.settings.formattingBackend == backend
        let lifeLog = env.settings.lifeLogAI.backend == backend
        switch (formatting, lifeLog) {
        case (true, true): parts.append(String(lore: "音声入力の整形とライフログAIで選択中"))
        case (true, false): parts.append(String(lore: "音声入力の整形で選択中"))
        case (false, true): parts.append(String(lore: "ライフログAIで選択中"))
        case (false, false): break
        }
        return parts.joined(separator: " · ")
    }

    private func draft(_ backend: FormattingBackend) -> Binding<String> {
        Binding(get: { drafts[backend] ?? "" }, set: { drafts[backend] = $0 })
    }

    private func save(_ backend: FormattingBackend) {
        let key = (drafts[backend] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        drafts[backend] = nil
        Task { await env.setApiKey(key, for: backend) }
    }
}
