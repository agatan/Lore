import SwiftUI

/// ライフログのTODO 1行。提案(draft)は採用・棄却、確定済みは完了・削除をhoverで出す。
struct LifeLogTodoRow: View {
    var todo: LifeLogTodo
    var title: Binding<String>
    var onToggle: () -> Void
    var onConfirm: () -> Void
    var onDelete: () -> Void

    @State private var isHovering = false

    private var isDraft: Bool { todo.status == .draft }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                TextField("TODO", text: title, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .lineLimit(1...6)
                    .fixedSize(horizontal: false, vertical: true)
                    .strikethrough(todo.status == .completed)
                    .foregroundStyle(isDraft ? .secondary : .primary)
                if isDraft {
                    Text("提案")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(KoeTheme.accent)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.04) : .clear)
                .padding(.horizontal, 6)
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }

    @ViewBuilder
    private var leading: some View {
        if isDraft {
            Image(systemName: "sparkle")
                .font(.system(size: 12))
                .foregroundStyle(KoeTheme.accent.opacity(0.8))
                .frame(width: 16)
        } else {
            Button(action: onToggle) {
                Image(systemName: todo.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 14))
                    .foregroundStyle(todo.status == .completed ? KoeTheme.success : .secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 16)
            .help(todo.status == .completed ? "未実施に戻す" : "完了にする")
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isDraft {
            HStack(spacing: 10) {
                Button(action: onConfirm) { Image(systemName: "checkmark") }
                    .foregroundStyle(KoeTheme.success)
                    .help("TODOにする")
                    .accessibilityLabel("TODOにする")
                Button(action: onDelete) { Image(systemName: "xmark") }
                    .foregroundStyle(.secondary)
                    .help("棄却")
                    .accessibilityLabel("棄却")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11, weight: .semibold))
        } else {
            Button(action: onDelete) { Image(systemName: "trash").font(.system(size: 11)) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .opacity(isHovering ? 1 : 0)
                .help("削除")
                .accessibilityLabel("TODOを削除")
        }
    }
}
