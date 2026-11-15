import SwiftUI

/// 語彙の管理(FR-6)。
struct VocabularySettingsView: View {
    var env: AppEnvironment
    @State private var editing: VocabularyEntry?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            entriesCard
        }
        .sheet(isPresented: $isAdding) {
            VocabularyEditorSheet(entry: VocabularyEntry(surface: "")) { entry in
                Task { await env.save(entry: entry) }
            }
        }
        .sheet(item: $editing) { entry in
            VocabularyEditorSheet(entry: entry) { updated in
                Task { await env.save(entry: updated) }
            }
        }
    }

    // MARK: 辞書

    private var entriesCard: some View {
        SettingsCard(
            title: "登録した語",
            footnote: "音声入力とライフログで共通です。表記と読みは文字起こしのヒントに、よくある誤認識は音声入力の整形に使います。"
        ) {
            HStack {
                Text("固有名詞や専門用語を登録すると、正しく文字起こしされやすくなります")
                    .font(.system(size: LoreTheme.TextSize.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isAdding = true
                } label: {
                    Label("追加", systemImage: "plus")
                        .font(.system(size: LoreTheme.TextSize.caption))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if env.vocabulary.isEmpty {
                Text("まだ登録した語はありません")
                    .font(.system(size: LoreTheme.TextSize.caption))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(env.vocabulary) { entry in
                        VocabularyRow(
                            entry: entry,
                            onToggle: { enabled in
                                var updated = entry
                                updated.enabled = enabled
                                Task { await env.save(entry: updated) }
                            },
                            onEdit: { editing = entry },
                            onDelete: { Task { await env.deleteVocabulary(id: entry.id) } }
                        )
                        if entry.id != env.vocabulary.last?.id {
                            Divider().opacity(0.5)
                        }
                    }
                }
            }
        }
    }
}

private struct VocabularyRow: View {
    var entry: VocabularyEntry
    var onToggle: (Bool) -> Void
    var onEdit: () -> Void
    var onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { entry.enabled }, set: { onToggle($0) }))
                .labelsHidden()
                .controlSize(.mini)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.surface)
                        .font(.system(size: LoreTheme.TextSize.callout, weight: .medium))
                    if let reading = entry.reading, !reading.isEmpty {
                        Text(reading)
                            .font(.system(size: LoreTheme.TextSize.caption))
                            .foregroundStyle(.secondary)
                    }
                    if entry.source == .suggested {
                        Pill(text: "提案由来", tint: LoreTheme.accent, localized: true)
                    }
                }
                if !entry.misrecognitions.isEmpty {
                    Text("誤認識: \(entry.misrecognitions.joined(separator: " / "))")
                        .font(.system(size: LoreTheme.TextSize.micro))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            .opacity(entry.enabled ? 1 : 0.45)

            Spacer()

            if isHovering {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(LoreTheme.danger)
            }
        }
        .padding(.vertical, 6)
        .onHover { isHovering = $0 }
    }
}

private struct VocabularyEditorSheet: View {
    @State var entry: VocabularyEntry
    var onSave: (VocabularyEntry) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var misrecognitionsText = ""

    private var parsedMisrecognitions: [String] {
        misrecognitionsText
            .components(separatedBy: CharacterSet(charactersIn: ",\n、"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(entry.surface.isEmpty ? "語彙を追加" : "語彙を編集")
                .font(.system(size: LoreTheme.TextSize.reading, weight: .semibold))

            Form {
                TextField("正しい表記", text: $entry.surface)
                TextField("読み (任意)", text: Binding(
                    get: { entry.reading ?? "" },
                    set: { entry.reading = $0.isEmpty ? nil : $0 }
                ))
                TextField("よくある誤認識 (改行またはカンマ区切り)", text: $misrecognitionsText, axis: .vertical)
                    .lineLimit(2...4)
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("キャンセル") { dismiss() }
                Button("保存") {
                    entry.misrecognitions = parsedMisrecognitions
                    onSave(entry)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(entry.surface.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
        .task { misrecognitionsText = entry.misrecognitions.joined(separator: "\n") }
    }
}
