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
                .shadow(color: KoeTheme.accent.opacity(0.25), radius: 18, y: 8)
            Text("話して過ごす毎日を、あなたの資産に。")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .multilineTextAlignment(.center)
            Text("Koeは、話したこと、声で残したメモ、音声入力した文章を、このMacの中に時刻順で残します。")
                .font(.system(size: 14))
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
                tint: KoeTheme.accentSecondary,
                title: "ライフログ",
                detail: "会議や作業中に話したことを、予定と並べて一日の流れとして残します。"
            )
            FeatureCard(
                symbol: "text.cursor",
                tint: KoeTheme.accent,
                title: "音声入力",
                detail: "ホットキーを押して話すと、整えた文章をいま使っているアプリへ入力します。"
            )
            FeatureCard(
                symbol: "pencil",
                tint: KoeTheme.memo,
                title: "声のメモ",
                detail: "思いついたことを声や短い文で残し、検索や書き出し、AIへの受け渡しに使えます。"
            )
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("はじめる準備")
                .font(KoeTheme.sectionFont)
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
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
        }
        .frame(maxWidth: 560)
    }

    private var start: some View {
        VStack(spacing: 12) {
            Button {
                env.settings.onboardingCompleted = true
            } label: {
                Text("Koeを始める")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(minWidth: 180)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .tint(KoeTheme.accent)
            .keyboardShortcut(.defaultAction)
            Label("記録はこのMacの中だけに保存します。通常の音声入力は音声を残さず、ライフログの復旧用音声は開始時に確認してから保存します。", systemImage: "lock.fill")
                .font(.system(size: 11))
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
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Text(LocalizedStringKey(title))
                .font(.system(size: 14, weight: .semibold))
            Text(LocalizedStringKey(detail))
                .font(.system(size: 12))
                .lineSpacing(3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
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
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(KoeTheme.voiceGradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 13, weight: .semibold))
                Text(LocalizedStringKey(detail))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if granted {
                Label("許可済み", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(KoeTheme.success)
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

/// Window全体に敷く背景。App iconのblue/cyanを大きくぼかし、縁のない光として置く。
private struct OnboardingBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Circle()
                    .fill(KoeTheme.accent.opacity(colorScheme == .dark ? 0.32 : 0.22))
                    .frame(width: size.width * 0.55)
                    .blur(radius: 120)
                    .offset(x: -size.width * 0.22, y: -size.height * 0.28)
                Circle()
                    .fill(KoeTheme.accentSecondary.opacity(colorScheme == .dark ? 0.26 : 0.2))
                    .frame(width: size.width * 0.45)
                    .blur(radius: 120)
                    .offset(x: size.width * 0.26, y: size.height * 0.2)
                Circle()
                    .fill(KoeTheme.memo.opacity(colorScheme == .dark ? 0.12 : 0.1))
                    .frame(width: size.width * 0.3)
                    .blur(radius: 110)
                    .offset(x: size.width * 0.05, y: size.height * 0.42)
            }
            .frame(width: size.width, height: size.height)
        }
        .accessibilityHidden(true)
    }
}
