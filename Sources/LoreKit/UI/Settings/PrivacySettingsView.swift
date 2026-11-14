import AppKit
import SwiftUI

/// プライバシーの説明とデータの扱い(NFR-2 / FR-7.3)。
struct PrivacySettingsView: View {
    var env: AppEnvironment
    @State private var deleteTarget: DeleteTarget?

    var body: some View {
        // 画面外のカードを先に組まない(GeneralSettingsView と同じ理由)。
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "保存場所", footnote: "録音した音声は外部へ送信しません。音声入力は文章だけを保存し、ライフログの音声は保存期間の設定に従って削除します。") {
                SettingsRow(
                    title: "データフォルダ",
                    caption: env.database?.fileURL?.deletingLastPathComponent().path(percentEncoded: false)
                ) {
                    if let url = env.database?.fileURL {
                        Button("Finderで表示") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                    }
                }
                SettingsRow(title: "このMacでの使用量", caption: "履歴、ライフログ、音声、whisper.cppのモデル") {
                    Text(ByteCountFormatter.string(fromByteCount: env.appDataBytes, countStyle: .file))
                        .font(LoreTheme.timeFont)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("privacy.storage")
                }
            }

            SettingsCard(title: "データの削除", footnote: "削除したデータは元に戻せません。") {
                SettingsRow(title: "音声入力の履歴", detail: "\(env.historyCount)件") {
                    Button("削除…", role: .destructive) { deleteTarget = .history }
                        .accessibilityIdentifier("privacy.delete-history")
                }
                SettingsRow(
                    title: "ライフログ",
                    detail: "発話、メモ、取り込んだ予定、音声（\(ByteCountFormatter.string(fromByteCount: env.lifeLogAudioBytes, countStyle: .file))）"
                ) {
                    Button("削除…", role: .destructive) { deleteTarget = .lifeLog }
                        .accessibilityIdentifier("privacy.delete-life-log")
                }
                SettingsRow(title: "すべてのデータ", caption: "設定、語彙、モード、APIキーを含めて初期状態に戻します") {
                    Button("Loreを初期化…", role: .destructive) { deleteTarget = .application }
                        .accessibilityIdentifier("privacy.reset")
                }
                if let error = env.dataOperationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: LoreTheme.TextSize.caption))
                        .foregroundStyle(LoreTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .confirmationDialog(LocalizedStringKey(deleteTarget?.title ?? "データを削除しますか？"), isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            if let target = deleteTarget {
                Button(LocalizedStringKey(target.actionTitle), role: .destructive) {
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
            Text(LocalizedStringKey(deleteTarget?.message ?? "元に戻せません。"))
        }
        .task { env.refreshStorageSizes() }
    }

    private enum DeleteTarget {
        case history
        case lifeLog
        case application

        var title: String {
            switch self {
            case .history: "音声入力の履歴を削除しますか？"
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
                "文字起こしと整形後の文章を削除します。語彙とライフログは残ります。"
            case .lifeLog:
                "発話、メモ、取り込んだ予定、音声を削除します。音声入力の履歴と設定は残ります。"
            case .application:
                "履歴、ライフログ、音声、語彙、モード、設定、APIキーを削除し、同期を解除します。同期フォルダ内のファイルは残ります。"
            }
        }
    }
}
