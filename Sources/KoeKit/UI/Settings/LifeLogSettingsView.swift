import SwiftUI

struct LifeLogSettingsView: View {
    var env: AppEnvironment
    @State private var extractionRuleDraft = ""

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
                if let error = env.hotkeyError {
                    Text(error).font(.system(size: 11)).foregroundStyle(KoeTheme.recording)
                }
            }

            SettingsCard(
                title: "音声",
                footnote: "音声はこのMacのアプリ用データフォルダだけに保存します。処理に失敗した音声は次回起動時に再処理します。"
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
                    .frame(width: 240)
                }
                SettingsRow(title: "音声の保持期間") {
                    Picker("", selection: Binding(get: { settings.lifeLogAudioRetentionDays }, set: {
                        settings.lifeLogAudioRetentionDays = $0
                        Task { await env.purgeExpiredLifeLogAudio() }
                    })) {
                        Text("30日").tag(30)
                        Text("90日").tag(90)
                        Text("1年").tag(365)
                        Text("無期限").tag(0)
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

            SettingsCard(title: "指示文") {
                promptEditor("日次要約", text: Binding(
                    get: { settings.lifeLogSummaryPrompt },
                    set: { settings.lifeLogSummaryPrompt = $0 }
                ))
                promptEditor("TODO", text: Binding(
                    get: { settings.lifeLogTodoPrompt },
                    set: { settings.lifeLogTodoPrompt = $0 }
                ))
                HStack {
                    Spacer()
                    Button("標準に戻す") {
                        settings.lifeLogSummaryPrompt = BuiltinLifeLogPrompts.summary
                        settings.lifeLogTodoPrompt = BuiltinLifeLogPrompts.todo
                    }
                }
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Text("TODO抽出の追加ルール")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(env.lifeLog.extractionRules) { rule in
                        HStack(spacing: 8) {
                            Text(rule.instruction).font(.system(size: 11.5)).lineLimit(2)
                            Spacer()
                            Button { Task { await env.lifeLog.deleteExtractionRule(id: rule.id) } } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain).foregroundStyle(.tertiary)
                        }
                    }
                    HStack(spacing: 8) {
                        TextField("例: 「軽く見ておきます」はTODOにしない", text: $extractionRuleDraft)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(addExtractionRule)
                        Button(action: addExtractionRule) { Image(systemName: "plus.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(KoeTheme.accent)
                            .disabled(extractionRuleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
        .toggleStyle(.switch)
        .task { env.refreshLifeLogAudioSize() }
    }

    private func promptEditor(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            TextEditor(text: text)
                .font(.system(size: 11.5, design: .monospaced))
                .frame(height: 92)
                .scrollContentBackground(.hidden)
                .padding(7)
                .sunkenSurface()
        }
    }

    private func addExtractionRule() {
        let value = extractionRuleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        extractionRuleDraft = ""
        Task { await env.lifeLog.addExtractionRule(value) }
    }
}
