import SwiftUI

/// Sidebarの行の記号。機能の色の角丸tileに白で載せる（システム設定と同じ作り）。
struct SidebarIcon: View {
    var symbol: String
    var tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(tint, in: RoundedRectangle(cornerRadius: LoreTheme.smallCornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// 文字と`SidebarIcon`を並べたsidebarの行。
struct SidebarLabel: View {
    var title: String
    var symbol: String
    var tint: Color

    var body: some View {
        Label {
            Text(LocalizedStringKey(title))
        } icon: {
            SidebarIcon(symbol: symbol, tint: tint)
        }
    }
}
