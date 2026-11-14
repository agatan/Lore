import SwiftUI

/// 音声入力とライフログで共有するwhisper.cpp modelの選択と取得状態。
struct WhisperModelSettingsView: View {
    var env: AppEnvironment
    private var settings: AppSettings { env.settings }

    var body: some View {
        SettingsRow(title: "モデル", caption: "音声入力とライフログで共通です") {
            Picker("", selection: Binding(get: { settings.whisperModel }, set: { value in
                settings.whisperModel = value
                Task { await env.applySttChange() }
            })) {
                ForEach(WhisperModel.allCases) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .frame(width: 220, alignment: .trailing)
        }
        SettingsRow(title: "ダウンロード", caption: "ダウンロード中だけHugging Faceに接続します。音声は送信しません") {
            HStack(spacing: 8) {
                if let progress = env.whisperProgress {
                    ProgressView(value: progress).frame(width: 110)
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: LoreTheme.TextSize.caption)).monospacedDigit()
                    Button("キャンセル") { env.cancelWhisperDownload() }
                } else {
                    switch env.engines.whisperAvailability {
                    case .ready:
                        Label("ダウンロード済み", systemImage: "checkmark.circle")
                            .foregroundStyle(LoreTheme.success)
                        Button("削除") { Task { await env.deleteWhisperModel() } }
                            .disabled(env.isWhisperModelInUse)
                    case .needsDownload:
                        Button("ダウンロード") { env.installWhisperModel() }
                    case .unavailable(let reason):
                        Text(reason).foregroundStyle(LoreTheme.danger)
                    }
                }
            }
            .font(.system(size: LoreTheme.TextSize.caption))
        }
        if let error = env.whisperError {
            Text(error).font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.danger)
        }
    }
}

/// Appleの音声認識を選んだときに、言語モデルの準備状態をその場で見せる。
/// 準備ができていれば何も出さず、ダウンロードが要るときだけ行を足す。
struct SpeechAnalyzerStatusView: View {
    var env: AppEnvironment

    var body: some View {
        switch env.engines.sttAvailability {
        case .ready:
            EmptyView()
        case .needsDownload(let reason):
            SettingsRow(title: "音声認識モデル", caption: reason) {
                Button("ダウンロード") { Task { await env.installSpeechAssets() } }
            }
        case .unavailable(let reason):
            SettingsRow(title: "音声認識モデル", caption: reason) { EmptyView() }
        }
        if let error = env.speechAssetError {
            Text(error).font(.system(size: LoreTheme.TextSize.caption)).foregroundStyle(LoreTheme.danger)
        }
    }
}
