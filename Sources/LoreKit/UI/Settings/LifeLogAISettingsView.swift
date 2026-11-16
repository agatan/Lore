import SwiftUI

/// Settings > Life Log AI. Every change goes through `AppEnvironment.applyLifeLogAIChange`, and a cloud
/// provider takes effect only after the confirmation dialog. The provider and model are chosen in AI Providers.
struct LifeLogAISettingsView: View {
    var env: AppEnvironment

    /// A change that waits for the cloud confirmation. Nothing is stored until the user confirms.
    @State private var pending: LifeLogAISettings?

    private var value: LifeLogAISettings { env.settings.lifeLogAI }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(footnote: "オフの間は、ライフログの文章をどこにも送りません。") {
                SettingsToggle(
                    title: "ライフログAI",
                    caption: "予定が終わったときに、その時間の発話とメモから、自分が引き受けたこと・人に頼んだこと・自分が決めたことをまとめます。1日の終わりには、その日のまとめを作ります",
                    isOn: Binding(get: { value.isEnabled }, set: { enabled in
                        var next = value
                        next.isEnabled = enabled
                        apply(next)
                    })
                )
                .accessibilityIdentifier("life-log-ai.enabled")
                SettingsRow(title: "プロバイダ", caption: "APIキーとあわせて「AIプロバイダ」で選びます") {
                    HStack(spacing: 10) {
                        Text(verbatim: value.backend == .onDevice ? value.backend.displayName : "\(value.backend.displayName) / \(value.model)")
                            .font(LoreTheme.bodyFont)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("life-log-ai.provider")
                        Button("AIプロバイダを開く") { env.settingsSection = .aiProviders }.controlSize(.small)
                    }
                }
            }

            SettingsCard(title: "送信する内容") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(LocalizedStringKey(destination))
                        .font(LoreTheme.bodyFont)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("送るのは、決まった指示文、予定の件名と開始・終了時刻、予定の時間内にある発話とメモの時刻と本文だけです。1日のまとめでは、その日の予定の件名と時刻、作成済みの予定のノート、その日の発話とメモを送ります。録音した音声、カレンダー名、参加者、ほかの日の記録、音声入力の履歴、APIキーは送りません。")
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
                        Text("予定の終了時").tag(GenerationTriggerMode.automatic)
                        Text("手動").tag(GenerationTriggerMode.manual)
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

            SettingsCard(title: "1日のまとめ", footnote: "記録の時間帯を設定している日は、その時間帯が終わったときに作ります。Macがスリープ中だったときやLoreが起動していなかったときは、次に起動したときに前日の分だけ作ります。") {
                SettingsRow(title: "まとめを作るタイミング") {
                    Picker("", selection: Binding(get: { value.dailyDigestTrigger }, set: { trigger in
                        var next = value
                        next.dailyDigestTrigger = trigger
                        apply(next)
                    })) {
                        Text("毎日").tag(GenerationTriggerMode.automatic)
                        Text("手動").tag(GenerationTriggerMode.manual)
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 220)
                    .accessibilityIdentifier("life-log-ai.digest-trigger")
                }
                SettingsRow(title: "作成する時刻", caption: "記録の時間帯がない日に使います") {
                    DatePicker(
                        "",
                        selection: Binding(
                            get: {
                                Calendar.current.date(bySettingHour: value.dailyDigestMinute / 60, minute: value.dailyDigestMinute % 60, second: 0, of: Date()) ?? Date()
                            },
                            set: { date in
                                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                                var next = value
                                next.dailyDigestMinute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                                apply(next)
                            }
                        ),
                        displayedComponents: .hourAndMinute
                    )
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
                    .disabled(value.dailyDigestTrigger == .manual)
                    .accessibilityIdentifier("life-log-ai.digest-time")
                }
                SettingsToggle(
                    title: "まとめができたら通知",
                    caption: "話した時間、予定とメモの件数を知らせます",
                    isOn: Binding(get: { value.notifiesWhenDailyDigestReady }, set: { notifies in
                        var next = value
                        next.notifiesWhenDailyDigestReady = notifies
                        apply(next)
                    })
                )
                .accessibilityIdentifier("life-log-ai.digest-notification")
            }

            SettingsCard(title: "AIに送らないカレンダー", footnote: "選んだカレンダーの予定の時間内にある発話とメモは、ほかの予定と重なっていても送りません。1件ずつの予定は、タイムラインの予定を右クリックして選べます。") {
                excludedCalendars
            }
        }
        .accessibilityIdentifier("life-log-ai.settings.root")
        .toggleStyle(.switch)
        .task {
            env.refreshPermissions()
            if env.isCalendarGranted { await env.lifeLog.loadCalendars() }
        }
        .lifeLogAICloudConfirmation($pending, env: env)
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

    private func apply(_ next: LifeLogAISettings) {
        pending = env.applyLifeLogAIChange(next)
    }
}
