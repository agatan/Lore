import AppKit
import SwiftUI

/// メニューバーのpanel。ライフログと音声入力を同じ文法の二枚のcardに並べ、tabで隠さない。
///
/// 各cardは左に丸い主操作button（main/miniの録音buttonと同じ形）、右に状態と補足、
/// 下に次の行き先を置く。詳細表示は各windowへ委ねる。
struct MenuBarPanel: View {
    var env: AppEnvironment
    @Environment(\.dismiss) private var dismiss

    private var coordinator: DictationCoordinator { env.coordinator }

    var body: some View {
        VStack(spacing: 10) {
            header
            lifeLogCard
            dictationCard
            if !notices.isEmpty { noticeArea }
            footer
        }
        .padding(12)
        .frame(width: 340)
        .task {
            coordinator.refreshPreview()
            await env.lifeLog.reload()
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
            Text("Lore").font(.system(size: LoreTheme.TextSize.headline, weight: .bold, design: .rounded))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.top, 2)
    }

    // MARK: ライフログ

    private var lifeLogStatus: LifeLogCaptureStatus {
        LifeLogCaptureStatus(lifeLog: env.lifeLog, scheduleCaption: env.lifeLogScheduleCaption)
    }

    private var lifeLogCard: some View {
        MenuCard(title: "ライフログ") {
            HStack(spacing: 12) {
                LifeLogRecordButton(
                    lifeLog: env.lifeLog,
                    status: lifeLogStatus,
                    accessibilityIdentifier: "menu.life-log.capture-toggle",
                    diameter: 36
                ) {
                    env.setLifeLogCaptureEnabled(!env.lifeLog.hasCaptureIntent)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringKey(lifeLogStatus.title))
                        .font(.system(size: LoreTheme.TextSize.body, weight: .semibold))
                        .foregroundStyle(env.lifeLog.isCapturing ? AnyShapeStyle(LoreTheme.recording) : AnyShapeStyle(.primary))
                    if let caption = lifeLogStatus.subtitle {
                        Text(caption)
                            .font(.system(size: LoreTheme.TextSize.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .accessibilityIdentifier("menu.life-log.capture-toggle.schedule")
                    } else {
                        Text(todaySummary)
                            .font(.system(size: LoreTheme.TextSize.caption))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
        } footer: {
            MenuLinkButton(title: "今日を開く", symbol: "calendar.day.timeline.left") { open(.lifeLog) }
            MenuLinkButton(title: "ミニウィンドウ", symbol: "pip") {
                dismiss()
                env.onToggleLifeLogMiniWindow?()
            }
        }
    }

    /// 停止中で自動記録の予定もない時は、今日どれだけ残したかを補足にする。
    private var todaySummary: LocalizedStringKey {
        let summary = LifeLogDaySummary(day: env.lifeLog.day)
        return "今日 \(summary.utteranceCount)件の発話 · メモ \(summary.memoCount)件"
    }

    // MARK: 音声入力

    private var dictationCard: some View {
        MenuCard(title: "音声入力") {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    DictationButton(isRecording: coordinator.isRecording) { coordinator.toggleFromUI() }
                        .disabled(coordinator.isBusy && !coordinator.isRecording)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(LocalizedStringKey(coordinator.isRecording ? "停止して文章にする" : "音声入力を開始"))
                            .font(.system(size: LoreTheme.TextSize.body, weight: .semibold))
                        HStack(spacing: 6) {
                            KeyCap(text: env.settings.hotkey.displayName)
                            Text("短押し / 長押し")
                                .font(.system(size: LoreTheme.TextSize.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                }
                lastResult
            }
        } footer: {
            MenuLinkButton(title: "履歴を開く", symbol: "clock.arrow.circlepath") { open(.history) }
            modeMenu
        }
    }

    @ViewBuilder
    private var lastResult: some View {
        if let text = env.lastResultText, !text.isEmpty {
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(LoreTheme.accent)
                    .frame(width: 2.5)
                Text(text)
                    .font(.system(size: LoreTheme.TextSize.callout))
                    .lineSpacing(2)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { env.copyLastResult() } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("直前の文章をコピー")
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("話した文章は、カーソルのある場所へ入ります")
                .font(.system(size: LoreTheme.TextSize.caption))
                .foregroundStyle(.tertiary)
        }
    }

    private var modeMenu: some View {
        Menu {
            Button("アプリに応じて自動") { coordinator.pinnedModeID = nil }
            Divider()
            ForEach(env.modes) { mode in Button(mode.name) { coordinator.pinnedModeID = mode.id } }
        } label: {
            Label(coordinator.previewMode?.name ?? "Default",
                  systemImage: coordinator.pinnedModeID == nil ? "wand.and.stars" : "pin.fill")
                .font(.system(size: LoreTheme.TextSize.caption, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .help("音声入力のモード")
    }

    private var noticeArea: some View {
        VStack(spacing: 6) {
            ForEach(notices) { notice in
                NoticeBanner(title: notice.title, message: notice.message,
                             actionTitle: notice.actionTitle, action: notice.action)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Button {
                dismiss()
                env.onShowSettings?(.lifeLog)
            } label: {
                Label("設定…", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("終了", systemImage: "power")
            }
            .buttonStyle(.borderless)
            .help("Loreを終了")
        }
        .font(.system(size: LoreTheme.TextSize.caption))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.top, 2)
    }

    private func open(_ section: MainSection) {
        dismiss()
        env.mainSection = section
        env.onShowMainWindow?()
    }

    private struct Notice: Identifiable {
        var id: String
        var title: String
        var message: String
        var actionTitle: String?
        var action: (() -> Void)?
    }

    private var notices: [Notice] {
        var values: [Notice] = []
        if !env.isAccessibilityGranted {
            values.append(Notice(id: "ax", title: "アクセシビリティが未許可", message: "ホットキーとテキスト挿入に必要です。", actionTitle: "許可する", action: {
                env.requestAccessibility(); Permissions.openAccessibilitySettings()
            }))
        }
        if env.requiresInputMonitoring, !env.isInputMonitoringGranted {
            values.append(Notice(
                id: "input-monitoring",
                title: "入力監視が未許可",
                message: "Option+文字keyのホットキーに必要です。Secure Input中は利用できません。",
                actionTitle: "許可する",
                action: {
                    env.requestInputMonitoring()
                    Permissions.openInputMonitoringSettings()
                }
            ))
        }
        if !env.isMicrophoneGranted {
            values.append(Notice(id: "mic", title: "マイクが未許可", message: "音声を取り込めません。", actionTitle: "許可する", action: {
                Task { await env.requestMicrophone() }
            }))
        }
        if let issue = env.dataMigrationIssue {
            values.append(Notice(id: "legacy-koe", title: "以前のKoeのデータを確認してください", message: issue))
        }
        if let error = env.bootError {
            values.append(Notice(id: "db", title: "データを開けません", message: error))
        }
        return values
    }
}

/// Panelの一枚。見出し、本体、区切り線の下に行き先を並べる。
private struct MenuCard<Content: View, Footer: View>: View {
    var title: String
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(LocalizedStringKey(title))
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)
            content
            Divider()
                .padding(.top, 12)
                .padding(.bottom, 4)
            HStack(spacing: 4) { footer }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: LoreTheme.panelCornerRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        }
    }
}

/// Cardの下端の行き先。Glass buttonは文字をrasterizeしてにじむため、plain buttonへ直接描く。
private struct MenuLinkButton: View {
    var title: String
    var symbol: String
    var action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
                    .foregroundStyle(LoreTheme.accent)
                Text(LocalizedStringKey(title))
                    .font(.system(size: LoreTheme.TextSize.callout, weight: .medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(isHovering ? 0.07 : 0), in: RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.leading, -8)
        .padding(.trailing, 4)
    }
}

/// 音声入力の主操作。ライフログの録音buttonと同じ直径と影で、待機中は墨色のmic、録音中はroseの停止。
private struct DictationButton: View {
    var isRecording: Bool
    var action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isRecording ? AnyShapeStyle(LoreTheme.recording) : AnyShapeStyle(LoreTheme.accent))
                Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: LoreTheme.TextSize.reading, weight: .semibold))
                    .foregroundStyle(isRecording ? Color.white : LoreTheme.onAccent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 36, height: 36)
            .padding(2)
            .contentShape(Circle())
            .opacity(isEnabled ? 1 : 0.45)
        }
        .buttonStyle(.plain)
        .help(LocalizedStringKey(isRecording ? "停止して文章にする" : "音声入力を開始"))
        .accessibilityLabel(LocalizedStringKey(isRecording ? "停止して文章にする" : "音声入力を開始"))
        .accessibilityIdentifier("menu.dictation.toggle")
    }
}

/// Hotkeyの表示。Keyboardのkeyのように薄い枠で囲む。
private struct KeyCap: View {
    var text: String

    var body: some View {
        Text(verbatim: text)
            .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.14), lineWidth: 1)
            }
    }
}
