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
                    Text("完了した項目は、いつでも未実施へ戻せます")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("表示", selection: $filter) {
                    ForEach(Filter.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 230)
            }
            .padding(20)

            Divider().opacity(0.45)

            if filteredTodos.isEmpty {
                ContentUnavailableView(
                    filter == .completed ? "完了したTODOはありません" : "TODOはありません",
                    systemImage: filter == .completed ? "checkmark.circle" : "circle.dashed"
                )
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
        .frame(minWidth: 560, minHeight: 460)
        .background {
            LinearGradient(
                colors: [KoeTheme.accent.opacity(0.055), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ).ignoresSafeArea()
        }
        .task { await env.lifeLog.reload() }
    }

    private var filteredTodos: [LifeLogTodo] {
        let confirmed = env.lifeLog.todos.filter { $0.status != .draft }
        switch filter {
        case .open: return confirmed.filter { $0.status == .open }
        case .completed: return confirmed.filter { $0.status == .completed }
        case .all: return confirmed
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
                TextField("TODO", text: title(todo))
                    .textFieldStyle(.plain)
                    .font(.system(size: 13.5, weight: .medium))
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
