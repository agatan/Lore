import AppKit
import SwiftUI

struct AutomationSettingsView: View {
    private let mcpServerPath = Bundle.main.bundleURL.appending(path: "Contents/Helpers/lore-mcp").path

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(
                title: "MCPサーバー",
                footnote: "MCPに対応したAIクライアントに、このパスを標準入出力のサーバーとして登録します。記録を読むだけで、書き換えや外部への通信はしません。"
            ) {
                HStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: LoreTheme.TextSize.headline, weight: .medium))
                        .foregroundStyle(LoreTheme.accent)
                        .frame(width: 30, height: 30)
                        .background(LoreTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "lore-mcp")
                            .font(.system(size: LoreTheme.TextSize.callout, weight: .semibold))
                        Text(mcpServerPath)
                            .font(.system(size: LoreTheme.TextSize.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    Menu("コピー") {
                        Button("パスをコピー") { copy(mcpServerPath) }
                        Button("Claude Code用のコマンドをコピー") {
                            copy("claude mcp add lore -- \"\(mcpServerPath)\"")
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("automation.mcp.copy")
                }
            }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
