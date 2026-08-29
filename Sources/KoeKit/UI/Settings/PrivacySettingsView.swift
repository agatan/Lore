import AppKit
import SwiftUI

/// プライバシーの説明とデータの扱い(NFR-2 / FR-7.3)。
struct PrivacySettingsView: View {
    var env: AppEnvironment
    @State private var deleteTarget: DeleteTarget?

    var body: some View {
        // 画面外のカードを先に組まない(GeneralSettingsView と同じ理由)。
        LazyVStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: sendsOffDevice ? "arrow.up.forward.app.fill" : "hand.raised.fill")
                        .foregroundStyle(sendsOffDevice ? AnyShapeStyle(KoeTheme.warning) : AnyShapeStyle(KoeTheme.voiceGradient))
                    Text(sendsOffDevice ? "文章処理に \(providerName) を使っています" : "すべてこの Mac の中で処理されます")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text(sendsOffDevice ? offDeviceSummary : Self.onDeviceSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "外に出ないもの") {
                ForEach(neverLeaves, id: \.self) { item in
                    Label(item, systemImage: "checkmark.shield")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Divider()
                if sendsOffDevice {
                    Label(
                        "口述の整形とライフログの要約・TODO生成に必要な文字データを\(providerName)へ送ります",
                        systemImage: "arrow.up.forward"
                    )
                    .font(.system(size: 11.5))
                    .foregroundStyle(KoeTheme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                } else {
                    Label("通信するのはモデルのダウンロードのみ", systemImage: "network")
                        .font(.system(size: 11.5))
                        .foregroundStyle(KoeTheme.accent)
                }
            }

            SettingsCard(title: "前面アプリの扱い") {
                Text("""
                モードを自動で切り替えるために、録音を始めた時点でどのアプリを使っていたかだけを見ます。\
                画面の内容やウィンドウの中の文字は読み取りません。
                """)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "保存場所", footnote: "通常の口述音声は保存しません。ライフログを有効にした場合だけ、再処理用の短い音声チャンクをMac内へ保存します。") {
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
            }

            SettingsCard(title: "データの削除", footnote: "削除した内容は元に戻せません。ライフログの削除には、発話、メモ、予定の控え、要約、TODO、保存音声が含まれます。") {
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
                Divider()
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
                Divider()
                HStack(spacing: 12) {
                    Text("設定、語彙、プロンプト、APIキーを含むすべて")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Koeを初期化…", role: .destructive) {
                        deleteTarget = .application
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                if let error = env.dataOperationError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(KoeTheme.recording)
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
        .task { env.refreshLifeLogAudioSize() }
    }

    /// 仕上げを外部に出しているかどうかで説明が変わる。判断の出どころは
    /// `FormattingBackend` 1 箇所だけにして、画面ごとに言うことがずれないようにする。
    private var sendsOffDevice: Bool {
        env.settings.formattingBackend.sendsTranscriptOffDevice
    }

    private static let onDeviceSummary = """
    Koe はクラウドの音声認識や文章生成サービスに接続しません。\
    この Mac の中だけで完結することを価値の中心に置いて作っています。
    """

    private var offDeviceSummary: String { """
    設定 > モデル で文章処理に \(providerName) を選んでいます。聞き取りはこの Mac の中で完結しますが、\
    口述の整形では文字起こしと指示文を送ります。ライフログではSummary・TODO生成のため、対象日の発話、メモ、予定の時刻と件名、指示文を送ります。録音した音声そのものは送りません。\
    外に出したくない場合は、仕上げを「この Mac の中」に戻してください。
    """ }

    private var providerName: String { env.settings.formattingBackend.displayName }

    /// 仕上げがオンデバイスのときに、この Mac から出ないもの。
    private var neverLeaves: [String] {
        var items = [
            "録音した音声",
            "通常の口述履歴",
            "前面アプリの情報",
        ]
        if !sendsOffDevice {
            items.insert("聞き取った文字と仕上げた文章", at: 1)
            items.insert("共通ルール・モードの指示・カスタム語彙", at: 2)
        }
        return items
    }

    private enum DeleteTarget {
        case history
        case lifeLog
        case application

        var title: String {
            switch self {
            case .history: "音声入力履歴を削除しますか？"
            case .lifeLog: "ライフログをすべて削除しますか？"
            case .application: "Koeを初期状態に戻しますか？"
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
                "発話、メモ、予定の控え、要約、TODO、保存音声を削除します。音声入力履歴と設定は残ります。"
            case .application:
                "履歴、ライフログ、保存音声、語彙、プロンプト、設定、Groq APIキーを削除します。元に戻せません。"
            }
        }
    }
}
