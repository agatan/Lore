import SwiftUI

enum LifeLogExportDestination: String, CaseIterable, Identifiable {
    case clipboard
    case file

    var id: String { rawValue }
    var title: String { self == .clipboard ? "クリップボード" : "ファイル" }
    var symbol: String { self == .clipboard ? "doc.on.clipboard" : "doc.badge.arrow.up" }
}

struct LifeLogExportSheet: View {
    var date: Date
    var day: LifeLogDay
    var todos: [LifeLogTodo]
    var onExport: (LifeLogTextExporter.Options, LifeLogExportDestination) -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var options = LifeLogTextExporter.Options()
    @State private var didCopy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("この日を書き出す")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .accessibilityIdentifier("export.sheet")
                    Text(date.formatted(.dateTime.year().month().day().weekday(.wide)))
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("export.close")
            }

            VStack(alignment: .leading, spacing: 9) {
                Text("含めるもの")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    exportToggle("予定", id: "calendar", count: day.calendarEvents.count, isOn: $options.includesCalendarEvents)
                    exportToggle("発話", id: "speech", count: day.utterances.count + day.dictations.count, isOn: $options.includesUtterances)
                    exportToggle("メモ", id: "memo", count: day.memos.count, isOn: $options.includesMemos)
                    exportToggle("要約", id: "summary", count: day.summary == nil ? 0 : 1, isOn: $options.includesSummary)
                    exportToggle("この日のTODO", id: "todo", count: dayTodoCount, isOn: $options.includesTodosForDay)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("プレビュー")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("LLM向けテキスト")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(preview)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                        .accessibilityIdentifier("export.preview")
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .overlay {
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(.white.opacity(0.10), lineWidth: 0.7)
                }
            }
            .frame(minHeight: 260)

            HStack {
                Button {
                    if onExport(options, .clipboard) { didCopy = true }
                } label: {
                    Label(didCopy ? "コピーしました" : "コピー", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(!options.hasSelection)
                Spacer()
                Button {
                    if onExport(options, .file) { dismiss() }
                } label: {
                    Label("テキストファイルを書き出す…", systemImage: "doc.badge.arrow.up")
                }
                .buttonStyle(.borderedProminent)
                .tint(KoeTheme.accent)
                .disabled(!options.hasSelection)
            }
        }
        .padding(22)
        .frame(width: 660, height: 680)
        .onChange(of: options) { _, _ in didCopy = false }
    }

    private var preview: String {
        LifeLogTextExporter.render(date: date, day: day, todos: todos, options: options)
    }

    private var dayTodoCount: Int {
        todos.filter {
            ($0.status == .open && Calendar.current.isDate($0.createdAt, inSameDayAs: date))
                || ($0.status == .completed && $0.completedAt.map { Calendar.current.isDate($0, inSameDayAs: date) } == true)
        }.count
    }

    private func exportToggle(_ title: String, id: String, count: Int, isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: isOn.wrappedValue ? "checkmark.square.fill" : "square")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(isOn.wrappedValue ? KoeTheme.accent : .secondary)
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(isOn.wrappedValue ? KoeTheme.accent.opacity(0.45) : Color.secondary.opacity(0.18), lineWidth: 1)
        }
        .accessibilityLabel("\(title)を含める")
        .accessibilityValue(isOn.wrappedValue ? "オン" : "オフ")
        .accessibilityIdentifier("export.include.\(id)")
    }
}
