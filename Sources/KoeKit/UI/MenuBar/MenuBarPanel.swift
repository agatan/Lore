import AppKit
import SwiftUI

/// メニューバーは用途ごとのquick actionだけを置き、詳細表示は各windowへ委ねる。
struct MenuBarPanel: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case lifeLog
        case dictation

        var id: String { rawValue }
        var title: String { self == .lifeLog ? "ライフログ" : "音声入力" }
        var settingsTitle: String { self == .lifeLog ? "ライフログの設定" : "音声入力の設定" }
        var symbol: String { self == .lifeLog ? "calendar.day.timeline.left" : "waveform.and.mic" }
    }

    var env: AppEnvironment
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
        .padding(12)
        .frame(width: 344)
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
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text("Koe").font(.system(size: 14, weight: .semibold))
                Text("声を残す・書く")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
    }

    private var tabPicker: some View {
        Picker("", selection: $tab) {
            ForEach(Tab.allCases) { item in
                Label(LocalizedStringKey(item.title), systemImage: item.symbol).tag(item)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
    }

    private var lifeLogTab: some View {
        VStack(spacing: 10) {
            LifeLogCaptureControl(
                lifeLog: env.lifeLog,
                accessibilityIdentifier: "menu.life-log.capture-toggle"
            ) {
                env.setLifeLogCaptureEnabled(!env.lifeLog.hasCaptureIntent)
            }
            .padding(12)
            .sunkenSurface()

            HStack(spacing: 8) {
                compactButton("今日を開く", symbol: "calendar") { open(.lifeLog) }
                compactButton("ミニウィンドウ", symbol: "rectangle.inset.filled") {
                    dismiss()
                    env.onToggleLifeLogMiniWindow?()
                }
            }
        }
    }

    private var dictationTab: some View {
        VStack(alignment: .leading, spacing: 11) {
            Button { coordinator.toggleFromUI() } label: {
                Label(LocalizedStringKey(coordinator.isRecording ? "停止して文章にする" : "音声入力を開始"),
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

            compactButton("音声入力履歴を開く", symbol: "clock.arrow.circlepath") { open(.history) }
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
            HStack(spacing: 7) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
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
                env.onShowSettings?(tab == .lifeLog ? .lifeLog : .dictation)
            } label: {
                Label(LocalizedStringKey(tab.settingsTitle), systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            Spacer()
            Button { NSApp.terminate(nil) } label: {
                Label("終了", systemImage: "power")
                    .labelStyle(.iconOnly)
            }
                .buttonStyle(.borderless).help("Koeを終了")
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 2)
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
