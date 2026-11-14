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

            SettingsCard(title: "ホットキー", footnote: "短く押すと録音の開始と停止、長押しすると押している間だけ録音します。") {
                SettingsRow(title: "録音キー") {
                    HotkeyRecorderView(
                        binding: Binding(get: { settings.hotkey }, set: { env.updateHotkey($0) }),
                        setCaptureMode: { env.setHotkeyCaptureMode($0) }
                    )
                }
                SettingsRow(title: "長押しとみなす時間") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(get: { Double(settings.holdThresholdMs) }, set: { settings.holdThresholdMs = Int($0) }),
                            in: 150...1_000,
                            step: 20
                        )
                        .frame(width: 190)
                        Text("\(settings.holdThresholdMs) ms")
                            .font(.system(size: LoreTheme.TextSize.caption))
                            .monospacedDigit().foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                if let error = env.hotkeyError {
                    Text(error).font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.danger)
                }
            }

            SettingsCard(
                title: "文字起こし",
                footnote: settings.dictationSttBackend == .whisperCpp
                    ? "whisper.cppは、キーを離してから録音全体を文字起こしします。録音中は途中経過を表示しません。ボイスメモにも使います。"
                    : nil
            ) {
                SettingsRow(title: "エンジン") {
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
                } else {
                    SpeechAnalyzerStatusView(env: env)
                }
            }

            SettingsCard(title: "表示と効果音") {
                SettingsToggle(title: "録音中の状態を画面に表示する", isOn: Binding(
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

            SettingsCard(title: "履歴") {
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
                SettingsRow(title: "保存済み") {
                    Text("\(env.historyCount)件").font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(.secondary)
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
                    title: "アクセシビリティが許可されていません",
                    message: "ホットキーの検知と、文章の入力に必要です。",
                    actionTitle: "システム設定を開く",
                    action: { env.requestAccessibility(); Permissions.openAccessibilitySettings() }
                )
            }
            if !env.isMicrophoneGranted {
                NoticeBanner(
                    title: "マイクが許可されていません",
                    message: "音声入力と録音に必要です。",
                    actionTitle: "許可する",
                    action: { Task { await env.requestMicrophone() } }
                )
            }
            if env.requiresInputMonitoring, !env.isInputMonitoringGranted {
                NoticeBanner(
                    title: "入力監視が許可されていません",
                    message: "Option＋文字キーのホットキーに必要です。パスワード入力中は使えません。",
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
