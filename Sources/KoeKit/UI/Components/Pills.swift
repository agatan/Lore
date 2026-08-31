import SwiftUI

/// モード名などを示す小さなラベル。
struct Pill: View {
    var text: String
    var systemImage: String?
    var tint: Color = .secondary
    var localized = false

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 9, weight: .semibold))
            }
            if localized {
                Text(LocalizedStringKey(text))
                    .font(.system(size: 10.5, weight: .medium))
            } else {
                Text(text)
                    .font(.system(size: 10.5, weight: .medium))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .glassEffect(.regular.tint(tint.opacity(0.22)), in: Capsule())
    }
}

/// 履歴のステータス表示。
struct StatusBadge: View {
    var status: SessionStatus

    private var tint: Color {
        switch status {
        case .completed: KoeTheme.success
        case .fallback: KoeTheme.warning
        case .clipboardOnly: KoeTheme.warning
        case .cancelled: .secondary
        case .failed: KoeTheme.recording
        case .interrupted: KoeTheme.warning
        }
    }

    private var symbol: String {
        switch status {
        case .completed: "checkmark"
        case .fallback: "wand.and.sparkles.inverse"
        case .clipboardOnly: "doc.on.clipboard"
        case .cancelled: "xmark"
        case .failed: "exclamationmark.triangle"
        case .interrupted: "clock.badge.exclamationmark"
        }
    }

    var body: some View {
        Pill(text: status.displayName, systemImage: symbol, tint: tint, localized: true)
    }
}

/// メニューパネルの行。ホバーで背景が付く。
struct MenuRow<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            label()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                // ホバーしていないときは `.identity`(効果なし)。同じ modifier を
                // 出し入れせず強さだけ変えることで、行の大きさが動かない。
                .glassEffect(
                    isHovering ? .regular.interactive() : .identity,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

/// 「浮いている面」の共通表現。カード・バナー・パネルはすべてこれを通す。
///
/// 面の役割は 2 つだけに保つ: **浮いているものはガラス**(`raisedGlass`)、
/// **へこんでいるものは塗り**(`sunkenSurface`)。画面ごとに素材を選び始めると、
/// 一部だけガラスが乗ったような中途半端な見た目になる。
struct RaisedGlass: ViewModifier {
    var cornerRadius: CGFloat = KoeTheme.panelCornerRadius
    /// 意味のある色(警告・成功など)を薄く透かす。既定は無色。
    var tint: Color?

    func body(content: Content) -> some View {
        content.glassEffect(
            tint.map { Glass.regular.tint($0.opacity(0.18)) } ?? .regular,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

/// 一覧や入力欄のような「へこんだ面」の共通表現。
///
/// ガラスは浮いているものにだけ使う。へこんだ面にガラスを乗せると
/// 前後関係が読めなくなるので、ここは塗りのままにする。
struct SunkenSurface: ViewModifier {
    var cornerRadius: CGFloat = KoeTheme.cardCornerRadius

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return content
            .clipShape(shape)
            .background { shape.fill(.background.opacity(0.5)) }
            .overlay { shape.strokeBorder(.separator.opacity(0.5), lineWidth: 0.5) }
    }
}

extension View {
    func sunkenSurface(cornerRadius: CGFloat = KoeTheme.cardCornerRadius) -> some View {
        modifier(SunkenSurface(cornerRadius: cornerRadius))
    }

    func raisedGlass(cornerRadius: CGFloat = KoeTheme.panelCornerRadius, tint: Color? = nil) -> some View {
        modifier(RaisedGlass(cornerRadius: cornerRadius, tint: tint))
    }
}

/// 設定 1 行分。**ラベルは左、操作するものは右**に寄せる。
///
/// `LabeledContent` はコントロールをラベルの直後に置くため、行ごとに操作部の
/// 左端がずれて視線が拾いにくい。設定行はここを通して、右端で縦に揃える。
struct SettingsRow<Control: View>: View {
    var title: String
    var caption: String?
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12))
                if let caption {
                    Text(LocalizedStringKey(caption))
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            control()
        }
        .frame(maxWidth: .infinity)
    }
}

/// スイッチ 1 行。`Toggle` のラベルは使わず、`SettingsRow` に揃える。
struct SettingsToggle: View {
    var title: String
    var caption: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

/// 設定画面のセクションカード。
struct SettingsCard<Content: View>: View {
    var title: String?
    var footnote: String?
    /// 余った縦を使い切る。長文の入力欄を持つカードだけ true にする。
    var fillsVertically = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: fillsVertically ? .infinity : nil, alignment: .leading)
            .raisedGlass()
            if let footnote {
                Text(LocalizedStringKey(footnote))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 権限などの注意喚起。
struct NoticeBanner: View {
    var title: String
    var message: String
    var tint: Color = KoeTheme.warning
    var actionTitle: String?
    var action: (() -> Void)?
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(tint)
                .font(.system(size: 13))
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title))
                    .font(.system(size: 12, weight: .semibold))
                Text(LocalizedStringKey(message))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if let actionTitle, let action {
                Button(LocalizedStringKey(actionTitle), action: action)
                    .buttonStyle(.borderless)
                    .font(.system(size: 11, weight: .medium))
            }
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("閉じる")
                .accessibilityLabel("通知を閉じる")
            }
        }
        .padding(12)
        .raisedGlass(cornerRadius: KoeTheme.cardCornerRadius, tint: tint)
    }
}
