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
                Divider()
                SettingsRow(title: "ミニウィンドウ") {
                    HotkeyRecorderView(
                        binding: Binding(get: { settings.lifeLogMiniWindowHotkey }, set: { env.updateLifeLogMiniWindowHotkey($0) }),
                        setCaptureMode: { env.setHotkeyCaptureMode($0) }
                    )
                }
                Divider()
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

            SettingsCard(
                title: "音声",
                footnote: "音声はこのMacのアプリ用データフォルダだけに保存します。処理に失敗した音声は次回起動時に再処理します。"
            ) {
                SettingsRow(title: "文字起こし", caption: "whisper.cppは発話区間だけをMac内で後追い処理します") {
                    Picker("", selection: Binding(get: { settings.lifeLogSttBackend }, set: { value in
                        settings.lifeLogSttBackend = value
                        Task { await env.applyLifeLogSttChange() }
                    })) {
                        ForEach(LifeLogSttBackend.allCases) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
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
                    .frame(width: 220)
                }
                if settings.lifeLogSttBackend == .whisperCpp {
                    SettingsRow(title: "Whisperモデル") {
                        Picker("", selection: Binding(get: { settings.lifeLogWhisperModel }, set: { value in
                            settings.lifeLogWhisperModel = value
                            Task { await env.applyLifeLogSttChange() }
                        })) {
                            ForEach(WhisperModel.allCases) { Text($0.displayName).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 220)
                    }
                    SettingsRow(title: "モデル管理", caption: "取得中だけHugging Faceへ接続します。音声は送信しません") {
                        HStack(spacing: 8) {
                            if let progress = env.lifeLogWhisperProgress {
                                ProgressView(value: progress).frame(width: 110)
                                Text("\(Int(progress * 100))%")
                                    .font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                                Button("キャンセル") { env.cancelLifeLogWhisperDownload() }
                            } else {
                                switch env.engines.lifeLogSttAvailability {
                                case .ready:
                                    Label("取得済み", systemImage: "checkmark.circle")
                                        .foregroundStyle(KoeTheme.success)
                                    Button("削除") { Task { await env.deleteLifeLogWhisperModel() } }
                                        .disabled(env.lifeLog.hasCaptureIntent || env.lifeLog.isTranscribing)
                                case .needsDownload:
                                    Button("取得") { env.installLifeLogWhisperModel() }
                                case .unavailable(let reason):
                                    Text(reason).foregroundStyle(KoeTheme.recording)
                                }
                            }
                        }
                        .font(.system(size: 10.5))
                    }
                    if let error = env.lifeLogWhisperError {
                        Text(error).font(.system(size: 11)).foregroundStyle(KoeTheme.recording)
                    }
                }
                Divider()
                SettingsRow(title: "マイク") {
                    Picker("", selection: Binding(get: { settings.lifeLogInputDeviceUID ?? "" }, set: { value in
                        settings.lifeLogInputDeviceUID = value.isEmpty ? nil : value
                        env.lifeLog.selectInputDevice(uid: settings.lifeLogInputDeviceUID)
                    })) {
                        Text("システム既定").tag("")
                        ForEach(AudioDevices.inputs()) { Text($0.name).tag($0.uid) }
                    }
                    .labelsHidden()
                    .frame(width: 240)
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

            SettingsCard(title: "要約とTODO", footnote: "要約とTODO案は同時に更新します。TODO案は編集して確定するまで実際のTODOにはなりません。次回更新時、未確定の案は作り直されます。") {
                SettingsRow(title: "要約の更新") {
                    Picker("", selection: Binding(get: { settings.lifeLogSummaryIntervalMinutes }, set: { settings.lifeLogSummaryIntervalMinutes = $0 })) {
                        Text("30分").tag(30)
                        Text("1時間").tag(60)
                        Text("2時間").tag(120)
                    }
                    .labelsHidden().pickerStyle(.segmented).fixedSize()
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
