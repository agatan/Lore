import SwiftUI

/// Loreが使うmacOSの権限を一か所に並べる。許可済みは印だけ、未許可は押せばダイアログか
/// システム設定の該当箇所が開くbuttonを置く。
struct PermissionsCard: View {
    var env: AppEnvironment

    var body: some View {
        SettingsCard(title: "アクセス権") {
            PermissionStatusRow(
                symbol: "mic",
                title: "マイク",
                caption: "音声入力とライフログの録音に使います",
                isGranted: env.isMicrophoneGranted,
                identifier: "microphone"
            ) { Task { await env.requestMicrophone() } }
            PermissionStatusRow(
                symbol: "accessibility",
                title: "アクセシビリティ",
                caption: "ホットキーの検知と、文章の入力に使います",
                isGranted: env.isAccessibilityGranted,
                identifier: "accessibility"
            ) {
                env.requestAccessibility()
                Permissions.openAccessibilitySettings()
            }
            if env.requiresInputMonitoring {
                PermissionStatusRow(
                    symbol: "keyboard",
                    title: "入力監視",
                    caption: "Option＋文字キーのホットキーに使います",
                    isGranted: env.isInputMonitoringGranted,
                    identifier: "input-monitoring"
                ) {
                    env.requestInputMonitoring()
                    Permissions.openInputMonitoringSettings()
                }
            }
            PermissionStatusRow(
                symbol: "calendar",
                title: "カレンダー",
                caption: "任意。予定をタイムラインに表示します",
                isGranted: env.isCalendarGranted,
                identifier: "calendar"
            ) { Task { await env.requestCalendar() } }
        }
        .task { env.refreshPermissions() }
    }
}

struct PermissionStatusRow: View {
    var symbol: String
    var title: String
    var caption: String
    var isGranted: Bool
    var identifier: String
    var request: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: LoreTheme.TextSize.body, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 22)
            SettingsRow(title: title, caption: caption) {
                if isGranted {
                    Label("許可済み", systemImage: "checkmark.circle.fill")
                        .font(.system(size: LoreTheme.TextSize.callout, weight: .medium))
                        .foregroundStyle(LoreTheme.success)
                        .labelStyle(.titleAndIcon)
                } else {
                    Button("許可する", action: request)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.permission.\(identifier)")
    }
}
