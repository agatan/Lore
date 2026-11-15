import SwiftUI

struct GeneralSettingsView: View {
    var env: AppEnvironment

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 20) {
            SettingsCard(title: "言語") {
                SettingsRow(title: "表示言語") {
                    Picker("表示言語", selection: Binding(
                        get: { env.settings.applicationLanguage },
                        set: { env.settings.applicationLanguage = $0 }
                    )) {
                        ForEach(ApplicationLanguage.allCases) { language in
                            Text(LocalizedStringKey(language.label)).tag(language)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .trailing)
                }
            }
            SettingsCard(title: "外観") {
                SettingsRow(title: "カラーテーマ") {
                    Picker("カラーテーマ", selection: Binding(
                        get: { env.settings.colorTheme },
                        set: { env.settings.colorTheme = $0 }
                    )) {
                        ForEach(ColorTheme.allCases) { theme in
                            Text(LocalizedStringKey(theme.label)).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 180, alignment: .trailing)
                    .accessibilityIdentifier("general.color-theme")
                }
            }
            SettingsCard(title: "起動") {
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
            PermissionsCard(env: env)
        }
        .toggleStyle(.switch)
        .task { await env.refreshLoginItem() }
    }
}
