import SwiftUI

struct GeneralSettingsView: View {
    var env: AppEnvironment
    private var settings: AppSettings { env.settings }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "Accent") {
                HStack(spacing: 12) {
                    ForEach(AccentPalette.allCases) { palette in
                        Button {
                            settings.accentPalette = palette
                        } label: {
                            VStack(spacing: 8) {
                                Circle()
                                    .fill(palette.color.gradient)
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if settings.accentPalette == palette {
                                            Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                                        }
                                    }
                                Text(palette.label).font(.system(size: 10.5, weight: .medium))
                            }
                            .frame(width: 62)
                            .padding(.vertical, 8)
                            .background(settings.accentPalette == palette ? palette.color.opacity(0.10) : .clear,
                                        in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
            SettingsCard(title: "起動") {
                SettingsToggle(title: "起動時にKoeを開く", isOn: Binding(
                    get: { settings.openHistoryAtLaunch },
                    set: { settings.openHistoryAtLaunch = $0 }
                ))
                SettingsToggle(
                    title: "ログイン時に起動する",
                    caption: env.loginItemState == .requiresApproval
                        ? "システム設定 > 一般 > ログイン項目 で承認が必要です" : nil,
                    isOn: Binding(
                        get: { env.loginItemState.isEnabled },
                        set: { newValue in Task { await env.setLoginItem(enabled: newValue) } }
                    )
                )
            }
        }
        .toggleStyle(.switch)
        .task { await env.refreshLoginItem() }
    }
}
