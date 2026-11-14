import SwiftUI

struct LifeLogSettingsView: View {
    var env: AppEnvironment
    private var settings: AppSettings { env.settings }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "ショートカット", footnote: "Koeが手前になくても使えます。音声入力とは別のキーを割り当ててください。") {
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
                SettingsRow(title: "ボイスメモ", caption: "押すたびに録音開始・停止。認識結果を今日のメモだけに追加します") {
                    HotkeyRecorderView(
                        binding: Binding(get: { settings.voiceMemoHotkey }, set: { env.updateVoiceMemoHotkey($0) }),
                        setCaptureMode: { env.setHotkeyCaptureMode($0) }
                    )
                    .accessibilityIdentifier("life-log.voice-memo-hotkey")
                }
                if let error = env.hotkeyError {
                    Text(error).font(.system(size: 11)).foregroundStyle(KoeTheme.recording)
                }
            }

            LifeLogScheduleSettingsView(env: env)

            SettingsCard(
                title: "音声",
                footnote: "音声はこのMacのアプリ用データフォルダだけに保存します。処理に失敗した音声は次回起動時に再処理します。"
            ) {
                SettingsRow(title: "文字起こし", caption: "whisper.cppは発話区間だけをMac内で後追い処理します") {
                    Picker("", selection: Binding(get: { settings.lifeLogSttBackend }, set: { value in
                        settings.lifeLogSttBackend = value
                        Task { await env.applySttChange() }
                    })) {
                        ForEach(SttBackend.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220, alignment: .trailing)
                }
                SettingsRow(title: "認識言語", caption: "ライフログだけに適用します") {
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
                }
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
                SettingsRow(title: "音声の保持期間") {
                    Picker("", selection: Binding(get: { settings.lifeLogAudioRetentionPolicy }, set: {
                        settings.lifeLogAudioRetentionPolicy = $0
                        Task { await env.purgeExpiredLifeLogAudio() }
                    })) {
                        Text("処理後削除").tag(LifeLogAudioRetentionPolicy.processedOnly)
                        Text("7日").tag(LifeLogAudioRetentionPolicy.days(7))
                        Text("30日").tag(LifeLogAudioRetentionPolicy.days(30))
                        if ![.processedOnly, .days(7), .days(30)].contains(settings.lifeLogAudioRetentionPolicy) {
                            Text(legacyRetentionLabel).tag(settings.lifeLogAudioRetentionPolicy)
                        }
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
                }
                SettingsRow(title: "現在の音声") {
                    Text(ByteCountFormatter.string(fromByteCount: env.lifeLogAudioBytes, countStyle: .file))
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .toggleStyle(.switch)
        .task { env.refreshLifeLogAudioSize() }
    }

    private var legacyRetentionLabel: String {
        switch settings.lifeLogAudioRetentionPolicy {
        case .processedOnly: "処理後削除"
        case .days(let days): "\(days)日（旧設定）"
        case .unlimited: "無期限（旧設定）"
        }
    }

}
