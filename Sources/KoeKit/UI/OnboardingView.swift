import SwiftUI

struct OnboardingView: View {
    var env: AppEnvironment

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 42, weight: .light))
                    .foregroundStyle(KoeTheme.voiceGradient)
                Text("声を、そのまま使える形に")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("音声入力と、一日の発話を振り返るライフログ。\n処理の中心はこのMacの中です。")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                permissionCard(
                    symbol: "mic.fill",
                    title: "聞き取る",
                    detail: "通常の音声入力は\n音声を保存しません",
                    granted: env.isMicrophoneGranted,
                    action: { Task { await env.requestMicrophone() } }
                )
                permissionCard(
                    symbol: "cursorarrow.motionlines",
                    title: "どこでも入力",
                    detail: "ホットキーと\n文字の貼り付けに使用",
                    granted: env.isAccessibilityGranted,
                    action: {
                        env.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                )
                permissionCard(
                    symbol: "calendar",
                    title: "予定を重ねる",
                    detail: "カレンダーは任意、\n閲覧だけに使用",
                    granted: !env.lifeLog.availableCalendars.isEmpty,
                    action: { Task { await env.lifeLog.loadCalendars() } }
                )
            }

            Label(
                "ライフログを始めるときだけ、復旧用の音声をMac内へ保存する確認が表示されます。",
                systemImage: "externaldrive.badge.checkmark"
            )
            .font(.system(size: 11.5))
            .foregroundStyle(.secondary)

            Button("Koeを始める") {
                env.settings.onboardingCompleted = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(34)
        .frame(width: 650, height: 510)
        .background {
            LinearGradient(
                colors: [KoeTheme.accent.opacity(0.10), KoeTheme.accentSecondary.opacity(0.05), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .interactiveDismissDisabled()
        .task { env.refreshPermissions() }
    }

    private func permissionCard(
        symbol: String,
        title: String,
        detail: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Image(systemName: symbol)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(KoeTheme.accent)
                    Spacer()
                    Image(systemName: granted ? "checkmark.circle.fill" : "arrow.up.right.circle")
                        .foregroundStyle(granted ? KoeTheme.success : Color.secondary.opacity(0.45))
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(16)
            .frame(maxWidth: .infinity, minHeight: 142, alignment: .topLeading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.16), lineWidth: 0.7)
            }
        }
        .buttonStyle(.plain)
    }
}
