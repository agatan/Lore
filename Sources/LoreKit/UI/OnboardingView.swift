import AppKit
import SwiftUI

/// 初回の画面。Window全体を一枚の背景として使い、中央の一列で
/// 「何をするappか」「何を許可するか」「どこに保存するか」だけを順に伝える。
///
/// 約束するのは今あるものだけにする: ライフログ、音声入力、声のメモ、検索と書き出し、AIへの受け渡し。
struct OnboardingView: View {
    var env: AppEnvironment

    var body: some View {
        ZStack {
            OnboardingBackdrop()
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 34) {
                    hero
                    features
                    permissions
                    start
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 40)
                .padding(.vertical, 56)
                .frame(maxWidth: .infinity, minHeight: 0)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollContentBackground(.hidden)
        }
        .task { env.refreshPermissions() }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)
            Text("話して過ごす毎日を、あなたの資産に。")
                .font(.system(size: LoreTheme.TextSize.display, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Loreは、話したこと、声で残したメモ、音声入力した文章を、このMacの中に時刻順で残します。")
                .font(.system(size: LoreTheme.TextSize.reading))
                .lineSpacing(4)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
    }

    private var features: some View {
        HStack(alignment: .top, spacing: 12) {
            FeatureCard(
                symbol: "calendar.day.timeline.left",
                tint: LoreTheme.recording,
                title: "ライフログ",
                detail: "会議や作業中に話したことを、予定と並べて一日の流れとして残します。"
            )
            FeatureCard(
                symbol: "text.cursor",
                tint: LoreTheme.accent,
                title: "音声入力",
                detail: "ホットキーを押して話すと、整えた文章をいま使っているアプリへ入力します。"
            )
            FeatureCard(
                symbol: "pencil",
                tint: LoreTheme.accent,
                title: "声のメモ",
                detail: "思いついたことを声や短い文で残し、検索や書き出し、AIへの受け渡しに使えます。"
            )
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("はじめる準備")
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 6)
            PermissionRow(
                symbol: "mic.fill",
                title: "マイク",
                detail: "話した声を文字にするために使います。",
                granted: env.isMicrophoneGranted
            ) { Task { await env.requestMicrophone() } }
            Divider().padding(.leading, 56)
            PermissionRow(
                symbol: "cursorarrow.motionlines",
                title: "入力操作",
                detail: "ホットキーと、文章をアプリへ入力するために使います。",
                granted: env.isAccessibilityGranted
            ) {
                env.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }
            Divider().padding(.leading, 56)
            PermissionRow(
                symbol: "calendar",
                title: "カレンダー",
                detail: "任意です。予定をライフログの横に並べます。",
                granted: !env.lifeLog.availableCalendars.isEmpty
            ) { Task { await env.lifeLog.loadCalendars() } }
        }
        .padding(.bottom, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .frame(maxWidth: 560)
    }

    private var start: some View {
        VStack(spacing: 12) {
            Button {
                env.settings.onboardingCompleted = true
            } label: {
                Text("Loreを始める")
                    .font(.system(size: LoreTheme.TextSize.reading, weight: .semibold))
                    .frame(minWidth: 180)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .tint(LoreTheme.accent)
            .keyboardShortcut(.defaultAction)
            Label("記録はこのMacの中だけに保存します。通常の音声入力は音声を残さず、ライフログの復旧用音声は開始時に確認してから保存します。", systemImage: "lock.fill")
                .font(.system(size: LoreTheme.TextSize.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
    }
}

private struct FeatureCard: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: LoreTheme.TextSize.headline, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
            Text(LocalizedStringKey(title))
                .font(.system(size: LoreTheme.TextSize.reading, weight: .semibold))
            Text(LocalizedStringKey(detail))
                .font(.system(size: LoreTheme.TextSize.callout))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
    }
}

private struct PermissionRow: View {
    var symbol: String
    var title: String
    var detail: String
    var granted: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: LoreTheme.TextSize.body, weight: .semibold))
                .foregroundStyle(LoreTheme.onAccent)
                .frame(width: 28, height: 28)
                .background(LoreTheme.accent, in: RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: LoreTheme.TextSize.body, weight: .semibold))
                Text(LocalizedStringKey(detail))
                    .font(.system(size: LoreTheme.TextSize.caption))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if granted {
                Label("許可済み", systemImage: "checkmark.circle.fill")
                    .font(.system(size: LoreTheme.TextSize.callout, weight: .medium))
                    .foregroundStyle(LoreTheme.success)
            } else {
                Button("許可する", action: action)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// Window全体に敷く背景。光や色のにじみは足さず、systemのwindow背景だけを敷く。
private struct OnboardingBackdrop: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .accessibilityHidden(true)
    }
}
