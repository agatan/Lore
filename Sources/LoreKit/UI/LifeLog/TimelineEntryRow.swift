import SwiftUI

/// ライフログの発話・音声入力・メモを、main / miniで同じ文法で並べる1行。
///
/// 種類は時刻の右の縦線上の印だけで示し、本文の読みやすさを優先する。
/// 編集・削除などの操作はhover中だけ出す。
struct TimelineEntryRow: View {
    enum Kind {
        case utterance
        case dictation
        case memo

        var node: TimelineRail.Node {
            switch self {
            case .utterance: .dot
            case .dictation: .symbol("keyboard", LoreTheme.accent)
            case .memo: .symbol("pencil", LoreTheme.memo)
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
    var above: LifeLogTimelineLayout.Segment = .none
    var below: LifeLogTimelineLayout.Segment = .none
    var isHighlighted = false
    var compact = false
    /// 操作controlのaccessibility identifier接頭辞。例: `life-log.memo-<id>`
    var accessibilityPrefix: String?
    /// 編集後の本文を受け取り、保存できたらtrueを返す。falseなら編集を続ける。
    var onEdit: ((String) async -> Bool)?
    var onDelete: (() -> Void)?

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draft = ""
    @State private var isSaving = false
    @FocusState private var editorFocused: Bool

    private var bodySize: CGFloat { compact ? 12.5 : 14 }

    var body: some View {
        TimelineRowFrame(
            time: Text(date.formatted(date: .omitted, time: .shortened)),
            node: kind.node,
            nodeLabel: kind == .utterance ? nil : kind.label,
            above: above,
            below: below,
            topPadding: compact ? 5 : 7,
            bottomPadding: compact ? 5 : 7,
            firstLineCenter: bodySize * 0.62,
            isHighlighted: isHighlighted,
            compact: compact
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if isEditing {
                    editor
                } else {
                    Text(text)
                        .font(.system(size: bodySize))
                        .lineSpacing(compact ? 3 : 5)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .simultaneousGesture(TapGesture(count: 2).onEnded { beginEditing() }, including: onEdit == nil ? .none : .all)
                    actions
                }
            }
            .padding(.leading, compact ? 4 : 6)
        }
        .padding(.trailing, compact ? 12 : 8)
        .background {
            RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous)
                .fill(isHighlighted ? LoreTheme.accent.opacity(0.12) : (isHovering && !isEditing ? Color.primary.opacity(0.035) : .clear))
                .padding(.leading, TimelineRowFrame<EmptyView>.timeWidth(compact: compact) + TimelineRail.width(compact: compact) - 4)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var actions: some View {
        if onEdit != nil || onDelete != nil {
            HStack(spacing: 8) {
                if onEdit != nil {
                    Button(action: beginEditing) {
                        Image(systemName: "pencil")
                            .font(.system(size: 11))
                    }
                    .help("メモを編集")
                    .accessibilityLabel("メモを編集")
                    .accessibilityIdentifier(accessibilityPrefix.map { "\($0).edit" } ?? "")
                }
                if let onDelete {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .help("メモを削除")
                    .accessibilityLabel("メモを削除")
                    .accessibilityIdentifier(accessibilityPrefix.map { "\($0).delete" } ?? "")
                }
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("メモ", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: compact ? 12.5 : 13))
                .lineSpacing(3)
                .lineLimit(1...12)
                .focused($editorFocused)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .strokeBorder(LoreTheme.accent.opacity(0.5), lineWidth: 1)
                }
                .onSubmit(save)
                .onExitCommand(perform: cancelEditing)
                .disabled(isSaving)
                .accessibilityIdentifier(accessibilityPrefix.map { "\($0).editor" } ?? "")
            HStack(spacing: 10) {
                Text("Returnで保存 · Option-Returnで改行 · Escで取り消し")
                    .font(LoreTheme.captionFont)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Button("取り消す", action: cancelEditing)
                    .accessibilityIdentifier(accessibilityPrefix.map { "\($0).cancel" } ?? "")
                Button("保存", action: save)
                    .disabled(isSaving || trimmedDraft.isEmpty)
                    .accessibilityIdentifier(accessibilityPrefix.map { "\($0).save" } ?? "")
            }
            .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trimmedDraft: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func beginEditing() {
        guard onEdit != nil, !isEditing else { return }
        draft = text
        isEditing = true
        editorFocused = true
    }

    private func cancelEditing() {
        isEditing = false
        draft = ""
    }

    private func save() {
        guard let onEdit, !isSaving, !trimmedDraft.isEmpty else { return }
        guard trimmedDraft != text else { cancelEditing(); return }
        isSaving = true
        let value = draft
        Task {
            let saved = await onEdit(value)
            isSaving = false
            if saved { cancelEditing() }
        }
    }
}
