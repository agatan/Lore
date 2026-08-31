import SwiftUI

enum LifeLogExportDestination: String, CaseIterable, Identifiable {
    case clipboard
    case file

    var id: String { rawValue }
    var title: String { self == .clipboard ? "クリップボード" : "ファイル" }
    var symbol: String { self == .clipboard ? "doc.on.clipboard" : "doc.badge.arrow.up" }
}

struct LifeLogExportSheet: View {
    private struct Snapshot: Sendable {
        var date: Date
        var day: LifeLogDay
        var todos: [LifeLogTodo]
    }

    @State private var snapshot: Snapshot
    var onExport: (String, Date, LifeLogExportDestination) async -> Bool

    @Environment(\.dismiss) private var dismiss
    @State private var options = LifeLogTextExporter.Options()
    @State private var didCopy = false
    @State private var renderedText = ""
    @State private var isPreparing = true
    @State private var isExporting = false

    init(
        date: Date,
        day: LifeLogDay,
        todos: [LifeLogTodo],
        onExport: @escaping (String, Date, LifeLogExportDestination) async -> Bool
    ) {
        _snapshot = State(initialValue: Snapshot(date: date, day: day, todos: todos))
        self.onExport = onExport
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("この日を書き出す")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                        .accessibilityIdentifier("export.sheet")
                    Text(snapshot.date.formatted(.dateTime.year().month().day().weekday(.wide)))
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
                    exportToggle("予定", id: "calendar", count: snapshot.day.calendarEvents.count, isOn: $options.includesCalendarEvents)
                    exportToggle("発話", id: "speech", count: snapshot.day.utterances.count, isOn: $options.includesUtterances)
                    exportToggle("音声入力", id: "voice-input", count: snapshot.day.dictations.count, isOn: $options.includesDictations)
                    exportToggle("メモ", id: "memo", count: snapshot.day.memos.count, isOn: $options.includesMemos)
                    exportToggle("要約", id: "summary", count: snapshot.day.summary == nil ? 0 : 1, isOn: $options.includesSummary)
                    exportToggle("この日のTODO", id: "todo", count: dayTodoCount, isOn: $options.includesTodosForDay)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("プレビュー")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("読みやすいMarkdown")
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                ScrollView(.vertical) {
                    if isPreparing {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("プレビューを準備中…")
                        }
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("export.preparing")
                    } else {
                    Text(previewText)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(12)
                        .accessibilityIdentifier("export.preview")
                    }
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
                    export(to: .clipboard)
                } label: {
                    Label(didCopy ? "コピーしました" : "コピー", systemImage: didCopy ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .disabled(!canExport)
                Spacer()
                Button {
                    export(to: .file)
                } label: {
                    if isExporting {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Markdownを書き出す…", systemImage: "doc.badge.arrow.up")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(KoeTheme.accent)
                .disabled(!canExport)
            }
        }
        .padding(22)
        .frame(width: 660, height: 680)
        .task(id: options) {
            didCopy = false
            isPreparing = true
            let snapshot = snapshot
            let options = options
            let text = await Task.detached(priority: .userInitiated) {
                LifeLogTextExporter.render(
                    date: snapshot.date,
                    day: snapshot.day,
                    todos: snapshot.todos,
                    options: options
                )
            }.value
            guard !Task.isCancelled else { return }
            renderedText = text
            isPreparing = false
        }
    }

    private var previewText: String {
        let limit = 30_000
        guard renderedText.count > limit else { return renderedText }
        return String(renderedText.prefix(limit)) + "\n\n…プレビューは先頭部分だけを表示しています。書き出しには全文が含まれます。"
    }

    private var dayTodoCount: Int {
        snapshot.todos.filter {
            ($0.status == .open && Calendar.current.isDate($0.createdAt, inSameDayAs: snapshot.date))
                || ($0.status == .completed && $0.completedAt.map { Calendar.current.isDate($0, inSameDayAs: snapshot.date) } == true)
        }.count
    }

    private var canExport: Bool {
        options.hasSelection && !isPreparing && !isExporting
    }

    private func export(to destination: LifeLogExportDestination) {
        guard canExport else { return }
        isExporting = true
        Task {
            let succeeded = await onExport(renderedText, snapshot.date, destination)
            isExporting = false
            if succeeded, destination == .clipboard { didCopy = true }
            if succeeded, destination == .file { dismiss() }
        }
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
