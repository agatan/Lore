import SwiftUI

struct LifeLogSettingsView: View {
    var env: AppEnvironment
    private var settings: AppSettings { env.settings }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "ショートカット", footnote: "Loreが前面になくても使えます。音声入力とは別のキーにしてください。") {
                SettingsRow(title: "記録の開始・停止") {
                    HotkeyRecorderView(
                        binding: Binding(get: { settings.lifeLogCaptureHotkey }, set: { env.updateLifeLogCaptureHotkey($0) }),
                        setCaptureMode: { env.setHotkeyCaptureMode($0) }
                    )
                }
                SettingsRow(title: "ミニウィンドウ") {
                    HotkeyRecorderView(
                        binding: Binding(get: { settings.lifeLogMiniWindowHotkey }, set: { env.updateLifeLogMiniWindowHotkey($0) }),
                        setCaptureMode: { env.setHotkeyCaptureMode($0) }
                    )
                }
                SettingsRow(title: "ボイスメモ", caption: "押すたびに録音を開始・停止し、文字起こしを今日のメモに追加します") {
                    HotkeyRecorderView(
                        binding: Binding(get: { settings.voiceMemoHotkey }, set: { env.updateVoiceMemoHotkey($0) }),
                        setCaptureMode: { env.setHotkeyCaptureMode($0) }
                    )
                    .accessibilityIdentifier("life-log.voice-memo-hotkey")
                }
                if let error = env.hotkeyError {
                    Text(error).font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.danger)
                }
            }

            LifeLogScheduleSettingsView(env: env)

            SettingsCard(
                title: "文字起こし",
                footnote: settings.lifeLogSttBackend == .whisperCpp
                    ? "whisper.cppは、話し終えた区間ごとにこのMacで文字起こしします。"
                    : nil
            ) {
                SettingsRow(title: "エンジン") {
                    Picker("", selection: Binding(get: { settings.lifeLogSttBackend }, set: { value in
                        settings.lifeLogSttBackend = value
                        Task { await env.applySttChange() }
                    })) {
                        ForEach(SttBackend.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                }
                SettingsRow(title: "言語", caption: "ライフログだけに使います") {
                    Picker("", selection: Binding(get: { settings.lifeLogTranscriptionLanguage }, set: { value in
                        settings.lifeLogTranscriptionLanguage = value
                        Task { await env.applyLifeLogTranscriptionLanguageChange() }
                    })) {
                        ForEach(LifeLogTranscriptionLanguage.allCases) {
                            Text(LocalizedStringKey($0.label)).tag($0)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                }
                if settings.lifeLogSttBackend == .whisperCpp {
                    WhisperModelSettingsView(env: env)
                } else {
                    SpeechAnalyzerStatusView(env: env)
                }
            }

            SettingsCard(
                title: "録音",
                footnote: "音声はこのMacにだけ保存し、外部へは送りません。文字起こしに失敗した音声は、次回の起動時にやり直します。"
            ) {
                SettingsRow(title: "マイク") {
                    Picker("", selection: Binding(get: { settings.lifeLogInputDeviceUID ?? "" }, set: { value in
                        settings.lifeLogInputDeviceUID = value.isEmpty ? nil : value
                        env.lifeLog.selectInputDevice(uid: settings.lifeLogInputDeviceUID)
                    })) {
                        Text("システム既定").tag("")
                        ForEach(AudioDevices.inputs()) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .frame(width: 240, alignment: .trailing)
                }
                SettingsRow(title: "音声の保存期間") {
                    Picker("", selection: Binding(get: { settings.lifeLogAudioRetentionPolicy }, set: {
                        settings.lifeLogAudioRetentionPolicy = $0
                        Task { await env.purgeExpiredLifeLogAudio() }
                    })) {
                        Text("文字起こし後に削除").tag(LifeLogAudioRetentionPolicy.processedOnly)
                        Text("7日").tag(LifeLogAudioRetentionPolicy.days(7))
                        Text("30日").tag(LifeLogAudioRetentionPolicy.days(30))
                        if ![.processedOnly, .days(7), .days(30)].contains(settings.lifeLogAudioRetentionPolicy) {
                            Text(legacyRetentionLabel).tag(settings.lifeLogAudioRetentionPolicy)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingsRow(title: "保存中の音声") {
                    Text(ByteCountFormatter.string(fromByteCount: env.lifeLogAudioBytes, countStyle: .file))
                        .font(.system(size: LoreTheme.TextSize.caption))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .task { env.refreshLifeLogAudioSize() }
    }

    private var legacyRetentionLabel: LocalizedStringKey {
        switch settings.lifeLogAudioRetentionPolicy {
        case .processedOnly: "文字起こし後に削除"
        case .days(let days): "\(days)日（旧設定）"
        case .unlimited: "無期限（旧設定）"
        }
    }

}
