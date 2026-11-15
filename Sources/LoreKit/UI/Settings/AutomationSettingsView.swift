import AppKit
import SwiftUI

struct AutomationSettingsView: View {
    private let integrations = AutomationIntegrationManager()
    @State private var status = AutomationIntegrationStatus.unavailable
    @State private var errorMessage: String?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(
                title: "MCPサーバー",
                footnote: "MCPに対応したAIクライアントに、このパスを標準入出力のサーバーとして登録します。記録を読むだけで、書き換えや外部への通信はしません。"
            ) {
                HStack(spacing: 12) {
                    integrationIcon("point.3.connected.trianglepath.dotted")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(verbatim: "lore-mcp")
                            .font(.system(size: LoreTheme.TextSize.callout, weight: .semibold))
                        Text(integrations.mcpServerURL.path)
                            .font(.system(size: LoreTheme.TextSize.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    Menu("コピー") {
                        Button("パスをコピー") { copy(integrations.mcpServerURL.path) }
                        Button("Claude Code用のコマンドをコピー") {
                            copy("claude mcp add lore -- \"\(integrations.mcpServerURL.path)\"")
                        }
                    }
                    .fixedSize()
                    .accessibilityIdentifier("automation.mcp.copy")
                }
            }

            SettingsCard(
                title: "コマンドライン",
                footnote: "シェルの設定やPATHは変更しません。Lore.appの中のCLIへのリンクを作るだけです。"
            ) {
                integrationRow(
                    symbol: "terminal",
                    title: "lore",
                    path: integrations.cliDestinationURL.path,
                    state: status.cli,
                    action: installCLI
                )
            }

            SettingsCard(
                title: "Agent Skill",
                footnote: "Loreの記録の読み方をAIエージェントに教えるSkillです。共通のSkillフォルダに置き、Claudeからも参照できるようにします。"
            ) {
                integrationRow(
                    symbol: "sparkles",
                    title: "Lore Agent Skill",
                    path: integrations.skillDestinationURL.path,
                    state: status.skill,
                    action: installSkill
                )
            }

            if let errorMessage {
                NoticeBanner(
                    title: "インストールできませんでした",
                    message: errorMessage,
                    tint: LoreTheme.danger
                )
            }
        }
        .task { refresh() }
    }

    private func integrationRow(
        symbol: String,
        title: String,
        path: String,
        state: AutomationIntegrationState,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            integrationIcon(symbol)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: LoreTheme.TextSize.callout, weight: .semibold))
                Text(path)
                    .font(.system(size: LoreTheme.TextSize.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            stateControl(state, action: action)
        }
    }

    private func integrationIcon(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: LoreTheme.TextSize.headline, weight: .medium))
            .foregroundStyle(LoreTheme.accent)
            .frame(width: 30, height: 30)
            .background(LoreTheme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius))
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @ViewBuilder
    private func stateControl(_ state: AutomationIntegrationState, action: @escaping () -> Void) -> some View {
        switch state {
        case .installed:
            Label("インストール済み", systemImage: "checkmark.circle.fill")
                .font(.system(size: LoreTheme.TextSize.caption, weight: .medium))
                .foregroundStyle(LoreTheme.success)
        case .notInstalled:
            Button("インストール", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .updateAvailable:
            Button("更新", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .conflict(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: LoreTheme.TextSize.caption))
                .foregroundStyle(LoreTheme.warning)
        case .unavailable(let message):
            Label(message, systemImage: "xmark.circle")
                .font(.system(size: LoreTheme.TextSize.caption))
                .foregroundStyle(.secondary)
        }
    }

    private func installCLI() {
        perform { try integrations.installCLI() }
    }

    private func installSkill() {
        perform { try integrations.installSkill() }
    }

    private func perform(_ operation: () throws -> Void) {
        do {
            try operation()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        refresh()
    }

    private func refresh() {
        status = integrations.status()
    }
}
