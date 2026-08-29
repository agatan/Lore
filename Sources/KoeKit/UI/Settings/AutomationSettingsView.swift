import SwiftUI

struct AutomationSettingsView: View {
    private let integrations = AutomationIntegrationManager()
    @State private var status = AutomationIntegrationStatus.unavailable
    @State private var errorMessage: String?

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(
                title: "コマンドライン",
                footnote: "シェルの設定やPATHは変更しません。Koe.app内のCLIへのリンクだけを作ります。"
            ) {
                integrationRow(
                    symbol: "terminal",
                    title: "koe",
                    path: integrations.cliDestinationURL.path,
                    state: status.cli,
                    action: installCLI
                )
            }

            SettingsCard(
                title: "AIエージェント",
                footnote: "共通のAgent Skillへ配置し、Claudeからも同じSkillを参照できるようにします。"
            ) {
                integrationRow(
                    symbol: "sparkles",
                    title: "Koe Agent Skill",
                    path: integrations.skillDestinationURL.path,
                    state: status.skill,
                    action: installSkill
                )
            }

            if let errorMessage {
                NoticeBanner(
                    title: "インストールできませんでした",
                    message: errorMessage,
                    tint: KoeTheme.recording
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
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KoeTheme.accent)
                .frame(width: 30, height: 30)
                .background(KoeTheme.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            stateControl(state, action: action)
        }
    }

    @ViewBuilder
    private func stateControl(_ state: AutomationIntegrationState, action: @escaping () -> Void) -> some View {
        switch state {
        case .installed:
            Label("インストール済み", systemImage: "checkmark.circle.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(KoeTheme.success)
        case .notInstalled:
            Button("インストール", action: action)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        case .updateAvailable:
            Button("更新", action: action)
                .buttonStyle(.bordered)
                .controlSize(.small)
        case .conflict(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 10.5))
                .foregroundStyle(KoeTheme.warning)
        case .unavailable(let message):
            Label(message, systemImage: "xmark.circle")
                .font(.system(size: 10.5))
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
