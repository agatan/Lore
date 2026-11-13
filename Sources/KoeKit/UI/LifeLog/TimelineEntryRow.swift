import SwiftUI

/// ライフログの発話・音声入力・メモを、main / miniで同じ文法で並べる1行。
///
/// 種類は時刻の下の小さな記号だけで示し、本文の読みやすさを優先する。
/// 削除などの操作はhover中だけ出す。
struct TimelineEntryRow: View {
    enum Kind {
        case utterance
        case dictation
        case memo

        var symbol: String? {
            switch self {
            case .utterance: nil
            case .dictation: "keyboard"
            case .memo: "note.text"
            }
        }

        var label: String {
            switch self {
            case .utterance: "発話"
            case .dictation: "音声入力"
            case .memo: "メモ"
            }
        }
    }

    var date: Date
    var kind: Kind
    var text: String
    var isHighlighted = false
    var compact = false
    var onDelete: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: compact ? 10 : 14) {
            HStack(spacing: 4) {
                Text(date.formatted(date: .omitted, time: .shortened))
                    .font(KoeTheme.timeFont)
                    .foregroundStyle(.secondary)
                if let symbol = kind.symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(KoeTheme.accent.opacity(0.85))
                        .help(LocalizedStringKey(kind.label))
                        .accessibilityLabel(LocalizedStringKey(kind.label))
                }
            }
            .frame(width: compact ? 52 : 60, alignment: .leading)

            Text(text)
                .font(.system(size: compact ? 12.5 : 13))
                .lineSpacing(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(isHovering ? 1 : 0)
                .help("メモを削除")
                .accessibilityLabel("メモを削除")
            }
        }
        .padding(.horizontal, compact ? 12 : 16)
        .padding(.vertical, compact ? 7 : 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHighlighted ? KoeTheme.accent.opacity(0.14) : (isHovering ? Color.primary.opacity(0.04) : .clear))
                .padding(.horizontal, compact ? 4 : 6)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}
