import AppKit
import SwiftUI

/// メニューバーは二つの主要用途を混ぜず、現在使う一方だけを見せる。
struct MenuBarPanel: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case lifeLog
        case dictation

        var id: String { rawValue }
        var title: String { self == .lifeLog ? "ライフログ" : "音声入力" }
        var symbol: String { self == .lifeLog ? "calendar.day.timeline.left" : "waveform.and.mic" }
    }

    var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .lifeLog

    private var coordinator: DictationCoordinator { env.coordinator }

    var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 12) {
                header
                tabPicker
                Group {
                    switch tab {
                    case .lifeLog: lifeLogTab
                    case .dictation: dictationTab
                    }
                }
                if !notices.isEmpty { noticeArea }
                footer
            }
        }
        .padding(14)
        .frame(width: 356)
        .task {
            coordinator.refreshPreview()
            await env.lifeLog.reload()
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(KoeTheme.voiceGradient)
            Text("Koe").font(.system(size: 14, weight: .semibold))
            Spacer()
            Circle().fill(statusTint).frame(width: 7, height: 7)
            Text(statusText)
                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var lifeLogTab: some View {
        VStack(spacing: 10) {
            VStack(spacing: 11) {
                ZStack {
                    Circle()
                        .fill(env.lifeLog.isCapturing ? KoeTheme.recording.opacity(0.14) : Color.secondary.opacity(0.09))
                        .frame(width: 54, height: 54)
                    Image(systemName: env.lifeLog.isCapturing ? "waveform.badge.mic" : "waveform")
                        .font(.system(size: 23, weight: .medium))
                        .foregroundStyle(env.lifeLog.isCapturing ? KoeTheme.recording : Color.secondary)
                        .symbolEffect(.variableColor.iterative, isActive: env.lifeLog.isCapturing)
                }

                if env.lifeLog.isCapturing || env.lifeLog.isTranscribing {
                    Text(env.lifeLog.liveTranscript.isEmpty ? "音声を取り込んでいます…" : env.lifeLog.liveTranscript)
                        .font(.system(size: 12.5))
                        .foregroundStyle(env.lifeLog.liveTranscript.isEmpty ? Color.secondary.opacity(0.65) : Color.primary)
                        .lineLimit(3)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                } else {
                    Text("今日の声を、時刻と予定に重ねて残します")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Button {
                    let enabled = !env.lifeLog.isCapturing
                    env.setLifeLogCaptureEnabled(enabled)
                } label: {
                    Label(env.lifeLog.isCapturing ? "記録を停止" : "記録を開始",
                          systemImage: env.lifeLog.isCapturing ? "stop.fill" : "record.circle")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.glassProminent)
                .tint(env.lifeLog.isCapturing ? KoeTheme.recording : KoeTheme.accent)
            }
            .padding(14)
            .sunkenSurface()

            HStack(spacing: 8) {
                compactButton("ライフログを開く", symbol: "arrow.up.right") { open(.lifeLog) }
                compactButton("ミニ", symbol: "rectangle.inset.filled") {
                    dismiss()
                    env.onToggleLifeLogMiniWindow?()
                }
            }
        }
    }

    private var dictationTab: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button { coordinator.toggleFromUI() } label: {
                Label(coordinator.isRecording ? "停止して文章にする" : "音声入力を開始",
                      systemImage: coordinator.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(coordinator.isRecording ? KoeTheme.recording : KoeTheme.accent)
            .disabled(coordinator.isBusy && !coordinator.isRecording)

            HStack {
                Text(env.settings.hotkey.displayName)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.secondary.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                Text("短押し / 長押し")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
                modeMenu
            }

            if let text = env.lastResultText, !text.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("直前").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                        Spacer()
                        Button { env.copyLastResult() } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                    Text(text).font(.system(size: 12)).lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(11)
                .sunkenSurface()
            } else {
                Text("最初の音声入力がここに表示されます")
                    .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .center)
            }
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
                .font(.system(size: 10.5, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func compactButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11.5, weight: .medium))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glass)
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
            Button { open(tab == .lifeLog ? .lifeLog : .history) } label: {
                Label("Koeを開く", systemImage: "macwindow")
            }
            .buttonStyle(.borderless).font(.system(size: 11.5))
            Spacer()
            Button {
                dismiss()
                env.settingsSection = tab == .lifeLog ? .lifeLog : .dictation
                openWindow(id: KoeWindow.settings)
                NSApp.activate()
            } label: { Image(systemName: "gearshape") }
            .buttonStyle(.borderless).help("設定")
            Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                .buttonStyle(.borderless).help("Koeを終了")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
    }

    private var statusText: String {
        tab == .lifeLog ? env.lifeLog.captureStatusText : KoeTheme.label(for: coordinator.phase)
    }

    private var statusTint: Color {
        if tab == .lifeLog { return env.lifeLog.isCapturing ? KoeTheme.recording : .secondary.opacity(0.35) }
        return KoeTheme.tint(for: coordinator.phase)
    }

    private func open(_ section: MainSection) {
        dismiss()
        env.mainSection = section
        openWindow(id: KoeWindow.main)
        NSApp.activate()
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
        if !env.isMicrophoneGranted {
            values.append(Notice(id: "mic", title: "マイクが未許可", message: "音声を取り込めません。", actionTitle: "許可する", action: {
                Task { await env.requestMicrophone() }
            }))
        }
        if let error = env.bootError {
            values.append(Notice(id: "db", title: "データを開けません", message: error))
        }
        return values
    }
}
