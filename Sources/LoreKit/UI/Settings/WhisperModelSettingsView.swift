import SwiftUI

/// 音声入力とライフログで共有するwhisper.cpp modelの選択と取得状態。
struct WhisperModelSettingsView: View {
    var env: AppEnvironment
    private var settings: AppSettings { env.settings }

    var body: some View {
        SettingsRow(title: "Whisperモデル", caption: "音声入力とライフログで共通です") {
            Picker("", selection: Binding(get: { settings.whisperModel }, set: { value in
                settings.whisperModel = value
                Task { await env.applySttChange() }
            })) {
                ForEach(WhisperModel.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 220, alignment: .trailing)
        }
        SettingsRow(title: "モデル管理", caption: "取得中だけHugging Faceへ接続します。音声は送信しません") {
            HStack(spacing: 8) {
                if let progress = env.whisperProgress {
                    ProgressView(value: progress).frame(width: 110)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 10.5, design: .rounded)).monospacedDigit()
                    Button("キャンセル") { env.cancelWhisperDownload() }
                } else {
                    switch env.engines.whisperAvailability {
                    case .ready:
                        Label("取得済み", systemImage: "checkmark.circle")
                            .foregroundStyle(LoreTheme.success)
                        Button("削除") { Task { await env.deleteWhisperModel() } }
                            .disabled(env.isWhisperModelInUse)
                    case .needsDownload:
                        Button("取得") { env.installWhisperModel() }
                    case .unavailable(let reason):
                        Text(reason).foregroundStyle(LoreTheme.recording)
                    }
                }
            }
            .font(.system(size: 10.5))
        }
        if let error = env.whisperError {
            Text(error).font(.system(size: 11)).foregroundStyle(LoreTheme.recording)
        }
    }
}
