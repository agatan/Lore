import SwiftUI

/// 語彙の管理と、履歴分析からの提案の承認(FR-6)。
struct VocabularySettingsView: View {
    var env: AppEnvironment
    @State private var editing: VocabularyEntry?
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            suggestionsCard
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

    // MARK: 提案

    private var suggestionsCard: some View {
        SettingsCard(
            title: "提案 (\(env.pendingSuggestions.count))",
            footnote: "これまでの履歴から見つけた候補です。承認したものだけが辞書に入ります。却下した語は二度と出てきません。"
        ) {
            HStack(spacing: 10) {
                Toggle("履歴から自動で提案する", isOn: Binding(
                    get: { env.settings.vocabularyAnalysisEnabled },
                    set: { env.settings.vocabularyAnalysisEnabled = $0 }
                ))
                Spacer()
                if case .running = env.analysisState {
                    ProgressView().controlSize(.small)
                }
                Button("いま分析する") {
                    Task { await env.runAnalysis(force: true) }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(env.analysisState == .running)
            }

            switch env.analysisState {
            case .finished(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            case .failed(let message):
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(KoeTheme.recording)
            case .idle, .running:
                if let lastAnalysisAt = env.lastAnalysisAt {
                    Text("最後の分析: \(lastAnalysisAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }

            if env.pendingSuggestions.isEmpty {
                Text("保留中の候補はありません")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 8) {
                    ForEach(env.pendingSuggestions) { suggestion in
                        SuggestionRow(
                            suggestion: suggestion,
                            onAccept: { Task { await env.acceptSuggestion(id: suggestion.id) } },
                            onReject: { Task { await env.rejectSuggestion(id: suggestion.id) } }
                        )
                    }
                }
            }
        }
    }

    // MARK: 辞書

    private var entriesCard: some View {
        SettingsCard(
            title: "辞書 (\(env.vocabulary.count))",
            footnote: "音声入力とライフログの文字起こしで同じ辞書を使います。表記・読みは聞き取りのヒントに、よくある誤認識は音声入力の整形に使います。"
        ) {
            HStack {
                Text("表記・読み・よくある誤認識を登録します")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    isAdding = true
                } label: {
                    Label("追加", systemImage: "plus")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if env.vocabulary.isEmpty {
                Text("まだ登録がありません")
                    .font(.system(size: 11))
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
                        .font(.system(size: 12, weight: .medium))
                    if let reading = entry.reading, !reading.isEmpty {
                        Text(reading)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                    if entry.source == .suggested {
                        Pill(text: "提案由来", tint: KoeTheme.accent)
                    }
                }
                if !entry.misrecognitions.isEmpty {
                    Text("誤認識: " + entry.misrecognitions.joined(separator: " / "))
                        .font(.system(size: 10))
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
                .foregroundStyle(KoeTheme.recording)
            }
        }
        .padding(.vertical, 6)
        .onHover { isHovering = $0 }
    }
}

private struct SuggestionRow: View {
    var suggestion: VocabularySuggestion
    var onAccept: () -> Void
    var onReject: () -> Void

    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(suggestion.surface)
                    .font(.system(size: 12.5, weight: .semibold))
                Pill(text: suggestion.evidence.kind.displayName, tint: KoeTheme.accent)
                Text("\(suggestion.evidence.count) 回")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("却下", action: onReject)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("承認", action: onAccept)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            if !suggestion.evidence.misrecognitions.isEmpty {
                Text("誤認識候補: " + suggestion.evidence.misrecognitions.joined(separator: " / "))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            if !suggestion.evidence.examples.isEmpty {
                DisclosureGroup(isExpanded: $showEvidence) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(suggestion.evidence.examples.enumerated()), id: \.offset) { _, example in
                            Text(example.excerpt)
                                .font(.system(size: 10.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    Text("根拠を見る")
                        .font(.system(size: 10.5))
                }
            }
        }
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: KoeTheme.cardCornerRadius, style: .continuous)
                .fill(KoeTheme.accent.opacity(0.07))
        }
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
                .font(.system(size: 14, weight: .semibold))

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
