import SwiftUI

/// 確定TODOの履歴と状態訂正を一か所に集める管理画面。
struct LifeLogTodoManagerWindow: View {
    var env: AppEnvironment
    @State private var filter: Filter = .open

    private enum Filter: String, CaseIterable, Identifiable {
        case open
        case completed
        case all

        var id: String { rawValue }
        var title: String {
            switch self {
            case .open: "未実施"
            case .completed: "完了"
            case .all: "すべて"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("すべてのTODO")
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .accessibilityIdentifier("todo-manager.root")
                    if !confirmedTodos.isEmpty {
                        Text("完了した項目は、いつでも未実施へ戻せます")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Picker("表示", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("todo-manager.filter")
            }
            .padding(20)

            Divider().opacity(0.45)

            if filteredTodos.isEmpty {
                emptyState
            } else {
                List(filteredTodos) { todo in
                    todoRow(todo)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .frame(minWidth: 560, minHeight: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            LinearGradient(
                colors: [KoeTheme.accent.opacity(0.055), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ).ignoresSafeArea()
        }
        .task { await env.lifeLog.reload() }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: filter == .completed ? "checkmark.circle" : "circle.dashed")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.secondary.opacity(0.45))
            Text(filter == .completed ? "完了したTODOはありません" : "TODOはありません")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("todo-manager.empty")
    }

    private var confirmedTodos: [LifeLogTodo] {
        env.lifeLog.todos.filter { $0.status != .draft }
    }

    private var filteredTodos: [LifeLogTodo] {
        switch filter {
        case .open: return confirmedTodos.filter { $0.status == .open }
        case .completed: return confirmedTodos.filter { $0.status == .completed }
        case .all: return confirmedTodos
        }
    }

    private func todoRow(_ todo: LifeLogTodo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button { toggle(todo) } label: {
                Image(systemName: todo.status == .completed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(todo.status == .completed ? KoeTheme.success : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(todo.status == .completed ? "未実施に戻す" : "完了にする")

            VStack(alignment: .leading, spacing: 5) {
                TextField("TODO", text: title(todo), axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
                    .lineLimit(1...8)
                    .fixedSize(horizontal: false, vertical: true)
                    .strikethrough(todo.status == .completed)
                HStack(spacing: 8) {
                    Text("作成 \(todo.createdAt.formatted(.dateTime.year().month().day()))")
                    if let completedAt = todo.completedAt {
                        Text("完了 \(completedAt.formatted(.dateTime.year().month().day().hour().minute()))")
                    }
                }
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 12)
            Button(role: .destructive) {
                Task { await env.lifeLog.delete(todoID: todo.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("削除")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }

    private func toggle(_ todo: LifeLogTodo) {
        var changed = todo
        changed.transition(to: todo.status == .completed ? .open : .completed)
        Task { await env.lifeLog.update(todo: changed) }
    }

    private func title(_ todo: LifeLogTodo) -> Binding<String> {
        Binding(get: { todo.title }, set: { value in
            var changed = todo
            changed.title = value
            Task { await env.lifeLog.update(todo: changed) }
        })
    }
}
