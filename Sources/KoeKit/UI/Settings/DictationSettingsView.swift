import SwiftUI

struct DictationSettingsView: View {
    var env: AppEnvironment
    private var settings: AppSettings { env.settings }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            if !env.isAccessibilityGranted
                || !env.isMicrophoneGranted
                || (env.requiresInputMonitoring && !env.isInputMonitoringGranted)
            { permissionSection }

            SettingsCard(title: "ホットキー", footnote: "短押しでトグル録音、長押しでpush-to-talk。") {
                SettingsRow(title: "録音キー") {
                    HotkeyRecorderView(
                        binding: Binding(get: { settings.hotkey }, set: { env.updateHotkey($0) }),
                        setCaptureMode: { env.setHotkeyCaptureMode($0) }
                    )
                }
                Divider()
                SettingsRow(title: "長押し判定") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(get: { Double(settings.holdThresholdMs) }, set: { settings.holdThresholdMs = Int($0) }),
                            in: 150...1_000,
                            step: 20
                        )
                        .frame(width: 190)
                        Text("\(settings.holdThresholdMs) ms")
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                if let error = env.hotkeyError {
                    Text(error).font(.system(size: 11)).foregroundStyle(KoeTheme.recording)
                }
            }

            SettingsCard(
                title: "聞き取り",
                footnote: "whisper.cppはキーを離した後に録音全体をMac内で一括認識します。録音中の暫定表示はありません。ボイスメモにも適用します。"
            ) {
                SettingsRow(title: "文字起こし") {
                    Picker("", selection: Binding(get: { settings.dictationSttBackend }, set: { value in
                        settings.dictationSttBackend = value
                        Task { await env.applySttChange() }
                    })) {
                        ForEach(SttBackend.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                    .accessibilityIdentifier("dictation.stt-backend")
                }
                if settings.dictationSttBackend == .whisperCpp {
                    WhisperModelSettingsView(env: env)
                }
            }

            SettingsCard(title: "フィードバック") {
                SettingsToggle(title: "録音中にHUDを表示する", isOn: Binding(
                    get: { settings.hudEnabled }, set: { settings.hudEnabled = $0 }
                ))
                SettingsToggle(title: "メニューバーに入力レベルを表示する", isOn: Binding(
                    get: { settings.showLevelMeterInMenuBar }, set: { settings.showLevelMeterInMenuBar = $0 }
                ))
                SettingsToggle(title: "効果音を鳴らす", isOn: Binding(
                    get: { settings.soundsEnabled }, set: { settings.soundsEnabled = $0 }
                ))
                if settings.soundsEnabled {
                    SettingsRow(title: "音量") {
                        Slider(value: Binding(get: { settings.soundVolume }, set: { settings.soundVolume = $0 }), in: 0...1)
                            .frame(width: 190)
                    }
                }
            }

            SettingsCard(title: "音声入力履歴", footnote: "語彙の自動提案と処理時間の集計にも使われます。") {
                SettingsRow(title: "保持期間") {
                    Picker("", selection: Binding(
                        get: { settings.historyRetentionDays },
                        set: { settings.historyRetentionDays = $0; Task { await env.purgeExpiredHistory() } }
                    )) {
                        Text("無期限").tag(0)
                        Text("30日").tag(30)
                        Text("90日").tag(90)
                        Text("1年").tag(365)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingsRow(title: "保存件数") {
                    Text("\(env.historyCount)件").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .task { env.refreshPermissions() }
    }

    private var permissionSection: some View {
        VStack(spacing: 8) {
            if !env.isAccessibilityGranted {
                NoticeBanner(
                    title: "アクセシビリティが未許可",
                    message: "ホットキーの監視とテキスト挿入に必要です。",
                    actionTitle: "システム設定を開く",
                    action: { env.requestAccessibility(); Permissions.openAccessibilitySettings() }
                )
            }
            if !env.isMicrophoneGranted {
                NoticeBanner(
                    title: "マイクが未許可",
                    message: "音声を取り込めません。",
                    actionTitle: "許可する",
                    action: { Task { await env.requestMicrophone() } }
                )
            }
            if env.requiresInputMonitoring, !env.isInputMonitoringGranted {
                NoticeBanner(
                    title: "入力監視が未許可",
                    message: "Option+文字keyのホットキーに必要です。Secure Input中は利用できません。",
                    actionTitle: "システム設定を開く",
                    action: {
                        env.requestInputMonitoring()
                        Permissions.openInputMonitoringSettings()
                    }
                )
            }
        }
    }
}
