import AppKit
import SwiftUI

/// 初回の画面。Window全体を一枚の背景として使い、中央の一列で順に案内する。
/// 1. 何をするappか、何を許可するか、どこに保存するか。
/// 2. 音声入力を一度その場で成功させる。
/// 3. 次の一歩としてライフログを勧める。
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
                    switch env.onboardingStep {
                    case .welcome:
                        hero
                        features
                        permissions
                        start
                    case .tryDictation:
                        OnboardingDictationTrial(env: env)
                    case .ready:
                        ready
                    }
                    OnboardingStepDots(current: env.onboardingStep)
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
            Text("話したことを、あとから読める記録に。")
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
                title: "ボイスメモ",
                detail: "思いついたことを声や短い文で残し、検索や書き出し、AIへの受け渡しに使えます。"
            )
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("アクセス権")
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
                title: "アクセシビリティ",
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
                granted: env.isCalendarGranted
            ) { Task { await env.requestCalendar() } }
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
                env.onboardingStep = .tryDictation
            } label: {
                Text("次へ")
                    .font(.system(size: LoreTheme.TextSize.reading, weight: .semibold))
                    .frame(minWidth: 180)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .tint(LoreTheme.accent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.next")
            Label("記録はこのMacの中だけに保存します。通常の音声入力は音声を残さず、ライフログの復旧用音声は開始時に確認してから保存します。", systemImage: "lock.fill")
                .font(.system(size: LoreTheme.TextSize.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
        }
    }

    private var ready: some View {
        VStack(spacing: 22) {
            Image(systemName: "calendar.day.timeline.left")
                .font(.system(size: LoreTheme.TextSize.metric, weight: .semibold))
                .foregroundStyle(LoreTheme.recording)
                .frame(width: 64, height: 64)
                .background(LoreTheme.recording.opacity(0.14), in: RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous))
            VStack(spacing: 10) {
                Text("準備ができました")
                    .font(.system(size: LoreTheme.TextSize.display, weight: .bold, design: .rounded))
                Text("次は、ライフログで一日に話したことを残してみましょう。音声入力した文章も、同じ一日の流れに並びます。")
                    .font(.system(size: LoreTheme.TextSize.reading))
                    .lineSpacing(4)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }
            VStack(spacing: 10) {
                Button {
                    env.completeOnboarding(startingLifeLog: true)
                } label: {
                    Text("ライフログを始める")
                        .font(.system(size: LoreTheme.TextSize.reading, weight: .semibold))
                        .frame(minWidth: 180)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .tint(LoreTheme.accent)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding.start-life-log")
                Button("あとで") {
                    env.completeOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding.finish")
            }
        }
        .padding(.top, 40)
    }
}

/// 音声入力を一度その場で成功させる段階。案内の中の入力欄が文章の受け取り先になる。
private struct OnboardingDictationTrial: View {
    var env: AppEnvironment
    @State private var text = ""

    private var blockers: [OnboardingDictationBlocker] {
        OnboardingDictationBlocker.missing(microphone: env.isMicrophoneGranted, accessibility: env.isAccessibilityGranted)
    }

    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 10) {
                Text("音声入力を試してみましょう")
                    .font(.system(size: LoreTheme.TextSize.display, weight: .bold, design: .rounded))
                Text("このキーを押したまま、ひと言話してから離してください。")
                    .font(.system(size: LoreTheme.TextSize.reading))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Text(verbatim: env.settings.hotkey.displayName)
                .font(.system(size: LoreTheme.TextSize.display * 1.6, weight: .semibold, design: .rounded))
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
                }
                .accessibilityIdentifier("onboarding.try.hotkey")
            if !blockers.isEmpty {
                blockerPanel
            }
            TextField("話した文章がここに入ります", text: $text, axis: .vertical)
                .lineLimit(3...6)
                .textFieldStyle(.plain)
                .font(.system(size: LoreTheme.TextSize.reading))
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.07), lineWidth: 1)
                }
                .frame(maxWidth: 560)
                .accessibilityIdentifier("onboarding.try.field")
            if env.coordinator.isBusy {
                Label("聞いています…", systemImage: "waveform")
                    .font(.system(size: LoreTheme.TextSize.callout))
                    .foregroundStyle(.secondary)
            }
            if let record = env.onboardingDictation {
                comparison(record)
            }
            actions
        }
        .onAppear { env.beginOnboardingDictationTrial() }
        .onDisappear { env.endOnboardingDictationTrial() }
        .onChange(of: env.onboardingDictation) { _, record in
            guard let record else { return }
            text = text.isEmpty ? record.resultText : text + " " + record.resultText
        }
    }

    private var blockerPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blockers, id: \.self) { blocker in
                switch blocker {
                case .microphone:
                    Label("マイクが許可されていないため、録音できません。", systemImage: "mic.slash.fill")
                        .accessibilityIdentifier("onboarding.try.blocker.microphone")
                case .accessibility:
                    Label("アクセシビリティが許可されていないため、ホットキーを検出できません。", systemImage: "exclamationmark.triangle.fill")
                        .accessibilityIdentifier("onboarding.try.blocker.accessibility")
                }
            }
            Button("アクセス権に戻る") { env.onboardingStep = .welcome }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
                .accessibilityIdentifier("onboarding.try.back-to-permissions")
        }
        .font(.system(size: LoreTheme.TextSize.callout, weight: .medium))
        .foregroundStyle(LoreTheme.warning)
        .padding(14)
        .frame(maxWidth: 560, alignment: .leading)
        .background(LoreTheme.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
    }

    private func comparison(_ record: SessionRecord) -> some View {
        HStack(alignment: .top, spacing: 12) {
            comparisonCard(title: "認識した言葉", text: record.rawTranscript, identifier: "onboarding.try.raw")
            Image(systemName: "arrow.right")
                .font(.system(size: LoreTheme.TextSize.body, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 30)
            comparisonCard(title: "整えた文章", text: record.resultText, identifier: "onboarding.try.formatted")
        }
        .frame(maxWidth: 640)
    }

    private func comparisonCard(title: LocalizedStringKey, text: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .font(.system(size: LoreTheme.TextSize.body))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier(identifier)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: LoreTheme.cardCornerRadius, style: .continuous))
    }

    @ViewBuilder
    private var actions: some View {
        if env.onboardingDictation == nil {
            Button("スキップ") { env.onboardingStep = .ready }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding.try.skip")
        } else {
            Button {
                env.onboardingStep = .ready
            } label: {
                Text("次へ")
                    .font(.system(size: LoreTheme.TextSize.reading, weight: .semibold))
                    .frame(minWidth: 180)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.extraLarge)
            .tint(LoreTheme.accent)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("onboarding.try.next")
        }
    }
}

private struct OnboardingStepDots: View {
    var current: OnboardingStep

    var body: some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == current ? Color.primary.opacity(0.7) : Color.primary.opacity(0.15))
                    .frame(width: step == current ? 18 : 7, height: 7)
            }
        }
        .animation(.snappy, value: current)
        .accessibilityHidden(true)
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
