import SwiftUI

/// Settings > Life Log AI. Every change goes through `AppEnvironment.updateLifeLogAI`, and a cloud
/// provider takes effect only after the confirmation dialog.
struct LifeLogAISettingsView: View {
    var env: AppEnvironment

    /// A change that waits for the cloud confirmation. Nothing is stored until the user confirms.
    @State private var pending: LifeLogAISettings?
    @State private var modelDraft = ""

    private var value: LifeLogAISettings { env.settings.lifeLogAI }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(footnote: "オフの間は、ライフログの文章をどこにも送りません。") {
                SettingsToggle(
                    title: "ライフログAI",
                    caption: "予定が終わったときに、その時間の発話とメモから決定事項・やること・未解決の問いをまとめます",
                    isOn: Binding(get: { value.isEnabled }, set: { enabled in
                        var next = value
                        next.isEnabled = enabled
                        apply(next)
                    })
                )
                .accessibilityIdentifier("life-log-ai.enabled")
                SettingsRow(title: "プロバイダ") {
                    Picker("", selection: Binding(get: { value.backend }, set: { backend in
                        var next = value
                        next.backend = backend
                        next.model = backend.defaultModel
                        apply(next)
                    })) {
                        ForEach(FormattingBackend.allCases) { backend in
                            Text(verbatim: backend.displayName).tag(backend)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                    .accessibilityIdentifier("life-log-ai.provider")
                }
                if value.backend != .onDevice {
                    SettingsRow(title: "モデル") {
                        TextField("", text: $modelDraft)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                            .onSubmit(commitModel)
                            .accessibilityIdentifier("life-log-ai.model")
                    }
                }
                if value.backend.sendsTranscriptOffDevice {
                    SettingsRow(title: "APIキー", caption: "AI整形でこのプロバイダに保存したAPIキーを使います") {
                        Button("AI整形を開く") { env.settingsSection = .models }
                    }
                }
            }

            SettingsCard(title: "送信する内容") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(destination))
                        .font(LoreTheme.bodyFont)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("送るのは、決まった指示文、予定の件名と開始・終了時刻、予定の時間内にある発話とメモの時刻と本文だけです。録音した音声、カレンダー名、参加者、ほかの時間や日の記録、音声入力の履歴、APIキーは送りません。")
                        .font(LoreTheme.captionFont)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("life-log-ai.sent-fields")
                SettingsRow(title: "今日のリクエスト") {
                    Text(verbatim: "\(env.lifeLogAI.requestsToday)")
                        .font(LoreTheme.bodyFont.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("life-log-ai.requests-today")
                }
            }

            SettingsCard(title: "予定のノート", footnote: "録音しているのはこのMacのマイクだけです。オンライン会議では、ほかの参加者の発言はノートに入りません。") {
                SettingsRow(title: "作成するタイミング") {
                    Picker("", selection: Binding(get: { value.eventNotesTrigger }, set: { trigger in
                        var next = value
                        next.eventNotesTrigger = trigger
                        apply(next)
                    })) {
                        Text("予定の終了時").tag(EventNotesTriggerMode.automatic)
                        Text("手動").tag(EventNotesTriggerMode.manual)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .accessibilityIdentifier("life-log-ai.trigger")
                }
                SettingsToggle(
                    title: "ノートができたら通知",
                    isOn: Binding(get: { value.notifiesWhenEventNotesReady }, set: { notifies in
                        var next = value
                        next.notifiesWhenEventNotesReady = notifies
                        apply(next)
                    })
                )
            }

            SettingsCard(title: "AIに送らないカレンダー", footnote: "選んだカレンダーの予定の時間内にある発話とメモは、ほかの予定と重なっていても送りません。1件ずつの予定は、タイムラインの予定を右クリックして選べます。") {
                excludedCalendars
            }
        }
        .accessibilityIdentifier("life-log-ai.settings.root")
        .toggleStyle(.switch)
        .task {
            modelDraft = value.model
            env.refreshPermissions()
            if env.isCalendarGranted { await env.lifeLog.loadCalendars() }
        }
        .onChange(of: value.backend) { modelDraft = value.model }
        .onDisappear { if modelDraft != value.model, value.backend != .onDevice { commitModel() } }
        .alert(
            Text("\(pending?.backend.displayName ?? "")へ送信しますか？"),
            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })
        ) {
            Button("送信を許可") {
                guard var next = pending else { return }
                next.confirmedCloudBackend = next.backend
                env.updateLifeLogAI(next)
                pending = nil
            }
            Button("キャンセル", role: .cancel) { pending = nil }
        } message: {
            Text("予定が終わるたびに、その時間の発話とメモの本文を\(pending?.backend.displayName ?? "")のAPIへ送ります。音声は送りません。データはそのサービスの規約に従って扱われます。")
        }
    }

    private var destination: String {
        guard value.isEnabled else { return "いまはオフなので、何も送りません。" }
        return switch value.backend {
        case .onDevice: "このMacの中で処理します。外部には送りません。"
        case .ollama: "このMacのOllama（localhost:11434）へ送ります。Macの外には出ません。"
        case .lmStudio: "このMacのLM Studio（localhost:1234）へ送ります。Macの外には出ません。"
        case .openAI, .anthropic, .gemini, .groq: "選んだクラウドのAPIへ送ります。"
        }
    }

    @ViewBuilder
    private var excludedCalendars: some View {
        if !env.isCalendarGranted {
            Text("カレンダーへのアクセスが許可されていません")
                .font(LoreTheme.captionFont)
                .foregroundStyle(.secondary)
        } else if env.lifeLog.availableCalendars.isEmpty {
            Text("カレンダーがありません")
                .font(LoreTheme.captionFont)
                .foregroundStyle(.secondary)
        } else {
            ForEach(env.lifeLog.availableCalendars, id: \.self) { title in
                SettingsRow(title: title) {
                    Toggle("", isOn: Binding(get: { value.excludedCalendars.contains(title) }, set: { excluded in
                        var next = value
                        next.excludedCalendars = excluded
                            ? (next.excludedCalendars + [title]).sorted()
                            : next.excludedCalendars.filter { $0 != title }
                        apply(next)
                    }))
                    .labelsHidden()
                    .controlSize(.small)
                }
            }
        }
    }

    private func commitModel() {
        let trimmed = modelDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = value
        next.model = trimmed.isEmpty ? value.backend.defaultModel : trimmed
        modelDraft = next.model
        apply(next)
    }

    /// A change that would start sending to a cloud provider the user has not confirmed waits for the dialog.
    private func apply(_ next: LifeLogAISettings) {
        if next.isEnabled, next.backend.sendsTranscriptOffDevice, next.confirmedCloudBackend != next.backend {
            pending = next
        } else {
            env.updateLifeLogAI(next)
        }
    }
}
