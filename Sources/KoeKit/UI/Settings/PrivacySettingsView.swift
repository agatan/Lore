import AppKit
import SwiftUI

/// プライバシーの説明とデータの扱い(NFR-2 / FR-7.3)。
struct PrivacySettingsView: View {
    var env: AppEnvironment
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "hand.raised.fill")
                        .foregroundStyle(KoeTheme.voiceGradient)
                    Text("すべてこの Mac の中で処理されます")
                        .font(.system(size: 15, weight: .semibold))
                }
                Text("""
                Koe はクラウドの音声認識や文章生成サービスに接続しません。API キーを設定する機能もありません。\
                この Mac の中だけで完結することを価値の中心に置いて作っています。
                """)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            SettingsCard(title: "外に出ないもの") {
                ForEach(Self.neverLeaves, id: \.self) { item in
                    Label(item, systemImage: "checkmark.shield")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Divider()
                Label("通信するのはモデルのダウンロードのみ", systemImage: "network")
                    .font(.system(size: 11.5))
                    .foregroundStyle(KoeTheme.accent)
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

            SettingsCard(title: "保存場所", footnote: "録音そのものは保存しません。残るのは聞き取った文字と仕上げた文章、そのとき使ったモードと指示文、かかった時間です。") {
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

            SettingsCard(title: "履歴の削除") {
                HStack {
                    Text("\(env.historyCount) 件の履歴が保存されています")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("すべて削除…", role: .destructive) {
                        showDeleteConfirm = true
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .confirmationDialog("履歴をすべて削除しますか？", isPresented: $showDeleteConfirm) {
            Button("すべて削除", role: .destructive) {
                Task { await env.deleteAllHistory() }
            }
        } message: {
            Text("元に戻せません。語彙の提案に使われた抜粋は別に保存されているため残ります。")
        }
    }

    private static let neverLeaves = [
        "録音した音声",
        "聞き取った文字と仕上げた文章",
        "カスタム語彙",
        "履歴と、そのとき使った指示文",
        "前面アプリの情報",
    ]
}
