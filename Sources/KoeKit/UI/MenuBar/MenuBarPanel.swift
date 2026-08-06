import AppKit
import SwiftUI

/// メニューバーから開くパネル(FR-8.1)。
///
/// 「いま何が起きているか」「次にどのモードで整形されるか」「直前の結果」を
/// 1 画面で確認できることを優先する。
struct MenuBarPanel: View {
    var env: AppEnvironment
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var coordinator: DictationCoordinator { env.coordinator }

    var body: some View {
        // 近接したガラス同士を溶け合わせる。個別に効果を掛けるより境目が減る。
        GlassEffectContainer(spacing: 14) {
            panel
        }
        .padding(14)
        .frame(width: 330)
        .task { coordinator.refreshPreview() }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            recordSection
            if !notices.isEmpty {
                VStack(spacing: 6) {
                    ForEach(notices) { notice in
                        NoticeBanner(
                            title: notice.title,
                            message: notice.message,
                            actionTitle: notice.actionTitle,
                            action: notice.action
                        )
                    }
                }
            }
            Divider().opacity(0.6)
            modeSection
            Divider().opacity(0.6)
            lastResultSection
            Divider().opacity(0.6)
            footer
        }
    }

    // MARK: 見出し

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(KoeTheme.voiceGradient)
            Text("Koe")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
            Pill(
                text: KoeTheme.label(for: coordinator.phase),
                systemImage: KoeTheme.symbol(for: coordinator.phase),
                tint: KoeTheme.tint(for: coordinator.phase)
            )
        }
    }

    // MARK: 録音

    private var recordSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                coordinator.toggleFromUI()
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: coordinator.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text(coordinator.isRecording ? "停止して文章にする" : "録音を開始")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .tint(coordinator.isRecording ? KoeTheme.recording : KoeTheme.accent)
            .disabled(coordinator.isBusy && !coordinator.isRecording)

            HStack(spacing: 4) {
                Text(env.settings.hotkey.displayName)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background {
                        RoundedRectangle(cornerRadius: 4).fill(.secondary.opacity(0.16))
                    }
                Text("短押しでトグル / 長押しで話す")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                if let latency = env.latency, latency.count > 0 {
                    Text("ふだん \(formatted(ms: latency.p50Ms))で入ります")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .help("直近 \(latency.count) 回の実測。ほとんどの場合 \(formatted(ms: latency.p95Ms))以内に入ります")
                }
            }
        }
    }

    // MARK: モード

    private var modeSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("モード")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if coordinator.pinnedModeID != nil {
                    Button("自動に戻す") { coordinator.pinnedModeID = nil }
                        .buttonStyle(.borderless)
                        .font(.system(size: 10.5))
                }
            }

            Menu {
                Button {
                    coordinator.pinnedModeID = nil
                } label: {
                    Text(coordinator.pinnedModeID == nil ? "✓ アプリに応じて自動" : "アプリに応じて自動")
                }
                Divider()
                ForEach(env.modes) { mode in
                    Button {
                        coordinator.pinnedModeID = mode.id
                    } label: {
                        Text(coordinator.pinnedModeID == mode.id ? "✓ \(mode.name)" : mode.name)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: coordinator.pinnedModeID == nil ? "wand.and.stars" : "pin.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(KoeTheme.accent)
                    Text(coordinator.previewMode?.name ?? "Default")
                        .font(.system(size: 12, weight: .medium))
                    Text(coordinator.pinnedModeID == nil ? "自動" : "固定")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    // MARK: 直前の結果

    private var lastResultSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("直前の結果")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let record = coordinator.lastRecord {
                    StatusBadge(status: record.status)
                }
            }

            if let text = env.lastResultText, !text.isEmpty {
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9)
                    .sunkenSurface()

                HStack(spacing: 8) {
                    Button {
                        env.copyLastResult()
                    } label: {
                        Label("コピー", systemImage: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.borderless)

                    if let record = coordinator.lastRecord, record.formattedText != nil {
                        Button {
                            TextInserter.copyToClipboard(record.rawTranscript)
                        } label: {
                            Label("生テキストをコピー", systemImage: "text.quote")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } else {
                Text("まだ結果がありません")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: フッター

    private var footer: some View {
        VStack(spacing: 1) {
            MenuRow {
                open(.history)
            } label: {
                Label("履歴を開く", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 12))
            }
            MenuRow {
                open(.general)
            } label: {
                Label("設定…", systemImage: "gearshape")
                    .font(.system(size: 12))
            }
            MenuRow {
                NSApp.terminate(nil)
            } label: {
                Label("Koe を終了", systemImage: "power")
                    .font(.system(size: 12))
            }
        }
        .padding(.horizontal, -6)
    }

    private func open(_ section: MainSection) {
        dismiss()
        env.mainSection = section
        openWindow(id: KoeWindow.main)
        NSApp.activate()
    }

    private func formatted(ms: Int) -> String {
        ms >= 1_000 ? String(format: "%.1f 秒", Double(ms) / 1_000) : "\(ms) ミリ秒"
    }

    // MARK: 注意

    private struct Notice: Identifiable {
        var id: String
        var title: String
        var message: String
        var actionTitle: String?
        var action: (() -> Void)?
    }

    private var notices: [Notice] {
        var notices: [Notice] = []
        if !env.isAccessibilityGranted {
            notices.append(Notice(
                id: "ax",
                title: "アクセシビリティが未許可",
                message: "ホットキーとテキスト挿入に必要です。",
                actionTitle: "許可する",
                action: {
                    env.requestAccessibility()
                    Permissions.openAccessibilitySettings()
                }
            ))
        }
        if !env.isMicrophoneGranted {
            notices.append(Notice(
                id: "mic",
                title: "マイクが未許可",
                message: "音声を取り込めません。",
                actionTitle: "許可する",
                action: { Task { await env.requestMicrophone() } }
            ))
        }
        if let error = env.bootError {
            notices.append(Notice(id: "db", title: "履歴 DB を開けません", message: error, actionTitle: nil, action: nil))
        }
        if let message = env.engines.sttAvailability.message {
            notices.append(Notice(
                id: "stt",
                title: "聞き取りの準備が必要",
                message: message,
                actionTitle: "設定",
                action: { open(.models) }
            ))
        }
        if let message = env.engines.llmAvailability.message {
            notices.append(Notice(
                id: "llm",
                title: "文章の仕上げができません",
                message: "\(message)。このままだと、聞き取った文字がそのまま挿入されます。",
                actionTitle: "設定",
                action: { open(.models) }
            ))
        }
        return notices
    }
}
