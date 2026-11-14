import SwiftUI

struct OnboardingView: View {
    var env: AppEnvironment

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 9) {
                Image(systemName: "waveform.badge.mic")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(KoeTheme.voiceGradient)
                Text("話して過ごす毎日を、あなたの資産に。")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                Text("Koeは、日々話したことや、ふと残したメモをこのMacに記録します。\n振り返りも日記も、いつもの一日から自然に積み上がります。")
                    .multilineTextAlignment(.center)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                valueCard(
                    symbol: "lightbulb.max",
                    title: "気づきを、流さない",
                    detail: "会話で生まれた考えを、そのまま一日の記録へ。"
                )
                valueCard(
                    symbol: "magnifyingglass",
                    title: "あとから、すぐ引き出せる",
                    detail: "発話・音声入力・メモを横断して検索し、書き出せる。"
                )
                valueCard(
                    symbol: "arrow.trianglehead.2.clockwise.rotate.90",
                    title: "振り返るほど、次がよくなる",
                    detail: "発話・メモ・予定から、一日の流れを短時間で把握。"
                )
                valueCard(
                    symbol: "book.closed",
                    title: "気づけば、日記になっている",
                    detail: "書き起こさなくても、その日の出来事が積み上がる。"
                )
            }

            HStack(spacing: 12) {
                Image(systemName: "text.cursor")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(KoeTheme.accent)
                    .frame(width: 28, height: 28)
                    .background(KoeTheme.accent.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text("思いついたら、その場で書ける")
                        .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    Text("ホットキーを押して話せば、整えた文章をいま使っているアプリへ入力できます。")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 15))

            VStack(spacing: 10) {
                Text("はじめる準備")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    permissionButton(symbol: "mic.fill", title: "マイク", granted: env.isMicrophoneGranted) {
                        Task { await env.requestMicrophone() }
                    }
                    permissionButton(symbol: "cursorarrow.motionlines", title: "入力操作", granted: env.isAccessibilityGranted) {
                        env.requestAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                    permissionButton(symbol: "calendar", title: "カレンダー（任意）", granted: !env.lifeLog.availableCalendars.isEmpty) {
                        Task { await env.lifeLog.loadCalendars() }
                    }
                }
                Text("通常の音声入力は音声を保存しません。ライフログ開始時だけ、復旧用音声をMac内へ保存する前に確認します。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }

            Button("Koeを始める") {
                env.settings.onboardingCompleted = true
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(30)
        .frame(width: 760, height: 680)
        .background {
            LinearGradient(
                colors: [KoeTheme.accent.opacity(0.10), KoeTheme.accentSecondary.opacity(0.05), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .task { env.refreshPermissions() }
    }

    private func valueCard(
        symbol: String,
        title: String,
        detail: String
    ) -> some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(KoeTheme.accent)
                .frame(width: 23)
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 0.7)
        }
    }

    private func permissionButton(symbol: String, title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: symbol)
                Text(title)
                Image(systemName: granted ? "checkmark.circle.fill" : "arrow.up.right.circle")
                    .foregroundStyle(granted ? KoeTheme.success : Color.secondary)
            }
            .font(.system(size: 11.5, weight: .medium))
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
    }
}
