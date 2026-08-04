import SwiftUI

struct GeneralSettingsView: View {
    var env: AppEnvironment
    @State private var launchAtLogin = false

    private var settings: AppSettings { env.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !env.isAccessibilityGranted || !env.isMicrophoneGranted {
                permissionSection
            }

            SettingsCard(title: "ホットキー", footnote: "短押しでトグル録音、長押しで push-to-talk。閾値より長く押していれば離した瞬間に停止します。軽く叩いたつもりでも 300ms 前後かかるため、トグルが効きにくいときは閾値を上げてください。") {
                LabeledContent("録音キー") {
                    HotkeyRecorderView(binding: Binding(
                        get: { settings.hotkey },
                        set: { env.updateHotkey($0) }
                    ))
                }
                Divider()
                LabeledContent("長押し判定") {
                    HStack(spacing: 10) {
                        Slider(
                            value: Binding(
                                get: { Double(settings.holdThresholdMs) },
                                set: { settings.holdThresholdMs = Int($0) }
                            ),
                            in: 150...1_000,
                            step: 20
                        )
                        .frame(width: 190)
                        Text("\(settings.holdThresholdMs) ms")
                            .font(.system(size: 11, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 56, alignment: .trailing)
                    }
                }
                if let error = env.hotkeyError {
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(KoeTheme.recording)
                }
            }

            SettingsCard(title: "表示と音") {
                Toggle("録音中に HUD を表示する", isOn: Binding(
                    get: { settings.hudEnabled },
                    set: { settings.hudEnabled = $0 }
                ))
                Toggle("メニューバーに入力レベルを表示する", isOn: Binding(
                    get: { settings.showLevelMeterInMenuBar },
                    set: { settings.showLevelMeterInMenuBar = $0 }
                ))
                Toggle("起動時に履歴ウィンドウを開く", isOn: Binding(
                    get: { settings.openHistoryAtLaunch },
                    set: { settings.openHistoryAtLaunch = $0 }
                ))
                Divider()
                Toggle("効果音を鳴らす", isOn: Binding(
                    get: { settings.soundsEnabled },
                    set: { settings.soundsEnabled = $0 }
                ))
                if settings.soundsEnabled {
                    LabeledContent("音量") {
                        Slider(
                            value: Binding(
                                get: { settings.soundVolume },
                                set: { settings.soundVolume = $0 }
                            ),
                            in: 0...1
                        )
                        .frame(width: 190)
                    }
                }
            }

            SettingsCard(title: "履歴", footnote: "履歴は、語彙の自動提案と「ふだんどれくらいで入るか」の集計にも使われます。") {
                Picker("保持期間", selection: Binding(
                    get: { settings.historyRetentionDays },
                    set: { settings.historyRetentionDays = $0; Task { await env.purgeExpiredHistory() } }
                )) {
                    Text("無期限").tag(0)
                    Text("30 日").tag(30)
                    Text("90 日").tag(90)
                    Text("1 年").tag(365)
                }
                .pickerStyle(.segmented)
                LabeledContent("保存件数") {
                    Text("\(env.historyCount) 件")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }

            SettingsCard(title: "常駐", footnote: "しばらく使わないときにメモリを空けます。空けたあとの 1 回目だけ、少し待ち時間が増えます。") {
                Toggle("ログイン時に起動する", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            try LoginItem.setEnabled(newValue)
                        } catch {
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if LoginItem.needsApproval {
                    Text("システム設定 > 一般 > ログイン項目 で承認が必要です")
                        .font(.system(size: 11))
                        .foregroundStyle(KoeTheme.warning)
                }
                Divider()
                Picker("使わないときメモリを空ける", selection: Binding(
                    get: { settings.modelIdleUnloadMinutes },
                    set: { settings.modelIdleUnloadMinutes = $0 }
                )) {
                    Text("しない").tag(0)
                    Text("5 分").tag(5)
                    Text("10 分").tag(10)
                    Text("30 分").tag(30)
                }
                .pickerStyle(.segmented)
            }
        }
        .task { launchAtLogin = LoginItem.isEnabled }
    }

    private var permissionSection: some View {
        VStack(spacing: 8) {
            if !env.isAccessibilityGranted {
                NoticeBanner(
                    title: "アクセシビリティが未許可",
                    message: "ホットキーの監視とテキスト挿入に必要です。許可後に自動で有効になります。",
                    actionTitle: "システム設定を開く",
                    action: {
                        env.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
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
        }
    }
}
