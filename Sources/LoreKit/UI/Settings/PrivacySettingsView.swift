import AppKit
import SwiftUI

/// プライバシーの説明とデータの扱い(NFR-2 / FR-7.3)。
struct PrivacySettingsView: View {
    var env: AppEnvironment
    @State private var deleteTarget: DeleteTarget?

    var body: some View {
        // 画面外のカードを先に組まない(GeneralSettingsView と同じ理由)。
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "アクセシビリティ") {
                Text("グローバルショートカットの検知と、仕上げた文章の貼り付けに使います。画面やウィンドウ内の文字は読み取りません。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "保存場所", footnote: "音声入力は文章だけを保存します。ライフログの音声は、設定した保持期間だけこのMacに保存します。") {
                if let url = env.database?.fileURL {
                    HStack {
                        Text(url.path(percentEncoded: false))
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                        Spacer()
                        Button("表示") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else {
                    Text("履歴の保存先はまだ作られていません")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                SettingsRow(title: "このMacの使用量", caption: "履歴、ライフログ、保存音声、whisper.cpp modelの合計です") {
                    Text(ByteCountFormatter.string(fromByteCount: env.appDataBytes, countStyle: .file))
                        .font(LoreTheme.timeFont)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("privacy.storage")
                }
            }

            SettingsCard(title: "データの削除", footnote: "削除した内容は元に戻せません。ライフログの削除には、発話、メモ、予定の控え、保存音声が含まれます。") {
                HStack(spacing: 12) {
                    Text("\(env.historyCount) 件の履歴が保存されています")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("音声入力履歴…", role: .destructive) {
                        deleteTarget = .history
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("ライフログ")
                            .font(.system(size: 11.5, weight: .medium))
                        Text("音声 \(ByteCountFormatter.string(fromByteCount: env.lifeLogAudioBytes, countStyle: .file))")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("ライフログを削除…", role: .destructive) {
                        deleteTarget = .lifeLog
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                HStack(spacing: 12) {
                    Text("設定、語彙、モード、APIキーを含むすべて")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Loreを初期化…", role: .destructive) {
                        deleteTarget = .application
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if let error = env.dataOperationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LoreTheme.recording)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog(deleteTarget?.title ?? "データを削除しますか？", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            if let target = deleteTarget {
                Button(target.actionTitle, role: .destructive) {
                    deleteTarget = nil
                    Task {
                        switch target {
                        case .history: await env.deleteAllHistory()
                        case .lifeLog: await env.deleteAllLifeLogData()
                        case .application: await env.deleteAllApplicationData()
                        }
                    }
                }
            }
            Button("キャンセル", role: .cancel) { deleteTarget = nil }
        } message: {
            Text(deleteTarget?.message ?? "元に戻せません。")
        }
        .task { env.refreshStorageSizes() }
    }

    private enum DeleteTarget {
        case history
        case lifeLog
        case application

        var title: String {
            switch self {
            case .history: "音声入力履歴を削除しますか？"
            case .lifeLog: "ライフログをすべて削除しますか？"
            case .application: "Loreを初期状態に戻しますか？"
            }
        }

        var actionTitle: String {
            switch self {
            case .history: "履歴を削除"
            case .lifeLog: "ライフログを削除"
            case .application: "すべて削除して初期化"
            }
        }

        var message: String {
            switch self {
            case .history:
                "生の文字起こしと整形後の文章を削除します。語彙とライフログは残ります。"
            case .lifeLog:
                "発話、メモ、予定の控え、保存音声を削除します。音声入力履歴と設定は残ります。"
            case .application:
                "履歴、ライフログ、保存音声、語彙、モード、設定、APIキーを削除し、同期を解除します。同期フォルダ内のファイルは残ります。元に戻せません。"
            }
        }
    }
}
