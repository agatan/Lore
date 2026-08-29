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
    @State private var destination: LifeLogExportDestination = .clipboard
    @State private var options = LifeLogTextExporter.Options()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("この日を書き出す")
                        .font(.system(size: 18, weight: .semibold, design: .rounded))
                    Text(date.formatted(.dateTime.year().month().day().weekday(.wide)))
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
            }

            Picker("書き出し先", selection: $destination) {
                ForEach(LifeLogExportDestination.allCases) { value in
                    Label(value.title, systemImage: value.symbol).tag(value)
                }
            }
            .pickerStyle(.segmented)

            VStack(spacing: 0) {
                exportToggle("予定", symbol: "calendar", count: day.calendarEvents.count, isOn: $options.includesCalendarEvents)
                Divider().padding(.leading, 38)
                exportToggle("発話", symbol: "waveform", count: day.utterances.count, isOn: $options.includesUtterances)
                Divider().padding(.leading, 38)
                exportToggle("メモ", symbol: "text.bubble", count: day.memos.count, isOn: $options.includesMemos)
                Divider().padding(.leading, 38)
                exportToggle("要約", symbol: "sparkles", count: day.summary == nil ? 0 : 1, isOn: $options.includesSummary)
                Divider().padding(.leading, 38)
                exportToggle("この日に作成・完了したTODO", symbol: "checkmark.circle", count: dayTodoCount, isOn: $options.includesTodosForDay)
            }
            .padding(.horizontal, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))

            HStack {
                Text("予定・発話・メモは時刻順に並びます")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                Spacer()
                Button(destination == .clipboard ? "コピー" : "保存…") {
                    if onExport(options, destination) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .tint(KoeTheme.accent)
                .disabled(!options.hasSelection)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var dayTodoCount: Int {
        todos.filter {
            ($0.status == .open && Calendar.current.isDate($0.createdAt, inSameDayAs: date))
                || ($0.status == .completed && $0.completedAt.map { Calendar.current.isDate($0, inSameDayAs: date) } == true)
        }.count
    }

    private func exportToggle(_ title: String, symbol: String, count: Int, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .foregroundStyle(KoeTheme.accent)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .toggleStyle(.switch)
        .padding(.vertical, 10)
    }
}
