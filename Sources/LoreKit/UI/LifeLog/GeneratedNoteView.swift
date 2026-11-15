import AppKit
import SwiftUI

/// An AI note of the main window: the notes under an event, or the daily digest at the top of the day.
/// All decisions (may it send, is it stale) come from the domain; this view only draws them.
struct GeneratedNoteView: View {
    enum Subject {
        case event(CalendarEventSnapshot)
        case day(String)
    }

    enum Style {
        /// The timeline card with every section.
        case full
        /// The inspector: header, actions, and the summary lines only.
        case compact
        /// A stored note shown on its own, without actions, as in the morning sheet.
        case readOnly(GeneratedNote)
    }

    var env: AppEnvironment
    var subject: Subject
    var style: Style = .full

    @State private var confirmsDelete = false

    private var ai: LifeLogAIService { env.lifeLogAI }

    private var scope: GeneratedNoteScope {
        switch subject {
        case .event(let event): .event(EventOccurrence(event))
        case .day(let day): .day(day)
        }
    }

    private var kind: GeneratedNoteKind {
        switch subject {
        case .event: .eventNotes
        case .day: .dailyDigest
        }
    }

    private var note: GeneratedNote? {
        if case .readOnly(let note) = style { return note }
        return switch subject {
        case .event(let event): env.lifeLog.day.eventNotes(for: event)
        case .day: env.lifeLog.day.dailyDigest
        }
    }

    private var isExcluded: Bool {
        guard case .event(let event) = subject else { return false }
        return env.settings.lifeLogAI.excludes(event, excludedEventIDs: ai.excludedEventIDs)
    }

    /// When "Generate" may appear. An event waits for its end; a day can be summed up at any time.
    private var availableFrom: Date? {
        switch subject {
        case .event(let event): event.isAllDay ? nil : event.endsAt
        case .day: env.lifeLog.day.utterances.isEmpty ? nil : .distantPast
        }
    }

    private var canSend: Bool { env.settings.lifeLogAI.sendPermission == .allowed && !isExcluded }
    private var isGenerating: Bool { ai.generatingScopes.contains(scope.key) }
    private var failure: String? { ai.failures[scope.key] }
    private var isCompact: Bool {
        if case .compact = style { return true }
        return false
    }

    private var showsActions: Bool {
        if case .readOnly = style { return false }
        return true
    }

    private var accessibilityPrefix: String {
        let base = switch subject {
        case .event(let event): "life-log.event-notes-\(event.id)"
        case .day: "life-log.daily-digest"
        }
        return switch style {
        case .full: base
        case .compact: "\(base).compact"
        case .readOnly: "\(base).read-only"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isExcluded {
                Label("AIに送らない", systemImage: "eye.slash")
                    .font(LoreTheme.captionFont)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(accessibilityPrefix).excluded")
            }
            if let note {
                noteCard(note)
            } else if isGenerating {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(generatingLabel)
                        .font(LoreTheme.captionFont)
                        .foregroundStyle(.secondary)
                }
            } else if canSend, showsActions, let availableFrom {
                // The button appears when the event ends, without waiting for another redraw.
                // `context.date` is the scheduled date even before it arrives, so compare with the clock.
                TimelineView(.explicit([availableFrom])) { _ in
                    if availableFrom <= Date() {
                        Button {
                            generate()
                        } label: {
                            Label(generateLabel, systemImage: "sparkles")
                        }
                        .buttonStyle(.link)
                        .font(LoreTheme.captionFont)
                        .accessibilityIdentifier("\(accessibilityPrefix).generate")
                    }
                }
            }
            if let failure, !isGenerating, showsActions {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(failure)
                        .font(LoreTheme.captionFont)
                        .foregroundStyle(LoreTheme.danger)
                        .wrapsFully(!isCompact)
                    Button("再試行") { generate() }
                        .buttonStyle(.link)
                        .font(LoreTheme.captionFont)
                        .disabled(!canSend)
                        .accessibilityIdentifier("\(accessibilityPrefix).retry")
                }
            }
        }
        .padding(.top, 6)
        .confirmationDialog(deleteQuestion, isPresented: $confirmsDelete) {
            Button(deleteLabel, role: .destructive) {
                guard let note else { return }
                Task {
                    await ai.deleteNote(note)
                    await env.lifeLog.reload()
                }
            }
        } message: {
            Text("元の発話やメモは削除されません。")
        }
    }

    private var generateLabel: LocalizedStringKey {
        if case .day = subject { return "まとめを作成" }
        return "ノートを作成"
    }

    private var generatingLabel: LocalizedStringKey {
        if case .day = subject { return "まとめを作成しています" }
        return "ノートを作成しています"
    }

    private var deleteLabel: LocalizedStringKey {
        if case .day = subject { return "まとめを削除" }
        return "ノートを削除"
    }

    private var deleteQuestion: LocalizedStringKey {
        if case .day = subject { return "この日のまとめを削除しますか？" }
        return "このノートを削除しますか？"
    }

    private var emptyLabel: LocalizedStringKey {
        if case .day = subject { return "まとめる決定事項・やること・残ったことはありませんでした" }
        return "記録する決定事項・やること・未解決の問いはありませんでした"
    }

    private func noteCard(_ note: GeneratedNote) -> some View {
        let sections: [GeneratedNoteSection] = switch style {
        case .compact: note.sections.filter { $0.kind == .summary && !$0.items.isEmpty }
        case .full, .readOnly: note.sections.filter { !$0.items.isEmpty }
        }
        return VStack(alignment: .leading, spacing: 10) {
            header(note)
            if !note.staleReasons.isEmpty { staleNotice(note) }
            if note.omittedSourceCount > 0 {
                Label("プロバイダの入力上限に収めるため、\(note.omittedSourceCount)件の記録を省きました", systemImage: "scissors")
                    .font(LoreTheme.captionFont)
                    .foregroundStyle(.secondary)
                    .wrapsFully(!isCompact)
                    .accessibilityIdentifier("\(accessibilityPrefix).omitted")
            }
            if note.isEmpty {
                Text(emptyLabel)
                    .font(.system(size: LoreTheme.TextSize.body))
                    .foregroundStyle(.secondary)
            }
            ForEach(sections, id: \.kind) { section in
                sectionView(section)
            }
            if case .compact = style {
                Button("タイムラインで読む") { env.lifeLog.jumpToTimelineItem(scope.timelineItemID) }
                    .buttonStyle(.link)
                    .font(LoreTheme.captionFont)
                    .accessibilityIdentifier("\(accessibilityPrefix).open")
            } else {
                Text("このMacのマイクの記録だけから作成しています。オンライン会議の他の参加者の発言は含まれません。")
                    .font(.system(size: LoreTheme.TextSize.micro))
                    .foregroundStyle(.tertiary)
                    .wrapsFully(!isCompact)
            }
        }
        .padding(12)
        .panelSurface(cornerRadius: LoreTheme.cardCornerRadius)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityPrefix)
    }

    private func header(_ note: GeneratedNote) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
            if case .day = subject {
                Text("1日のまとめ")
                    .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
                    .fixedSize()
                Text(verbatim: "·").foregroundStyle(.secondary)
            }
            Text("AIが生成")
                .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
                .fixedSize()
                .accessibilityIdentifier("\(accessibilityPrefix).generated-mark")
            // The inspector is too narrow for the provider; the timeline card next to it names it.
            if !isCompact {
                Text(verbatim: "· \(note.backend.displayName)")
                    .font(LoreTheme.captionFont)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityIdentifier("\(accessibilityPrefix).provider")
            }
            Spacer(minLength: 8)
            if showsActions {
                iconButton("doc.on.doc", label: "Markdownでコピー", id: "copy") { copy(note) }
                iconButton("arrow.clockwise", label: "再生成", id: "regenerate") { generate() }
                    .disabled(!canSend || isGenerating)
                iconButton("trash", label: deleteLabel, id: "delete") { confirmsDelete = true }
            }
        }
    }

    private func staleNotice(_ note: GeneratedNote) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(LoreTheme.warning)
            VStack(alignment: .leading, spacing: 2) {
                if note.staleReasons.contains(.eventChanged) {
                    Text("予定の時間が変わったため、内容が古い可能性があります")
                }
                if note.staleReasons.contains(.sourcesDeleted) {
                    Text("元の発話またはメモが削除されています")
                }
            }
            .font(LoreTheme.captionFont)
            .wrapsFully(!isCompact)
            if showsActions {
                Button("再生成") { generate() }
                    .buttonStyle(.link)
                    .font(LoreTheme.captionFont)
                    .disabled(!canSend || isGenerating)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(accessibilityPrefix).stale")
    }

    private func sectionView(_ section: GeneratedNoteSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(Self.title(section.kind, digest: kind == .dailyDigest)))
                .font(LoreTheme.sectionFont)
                .foregroundStyle(.secondary)
            ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                Button {
                    if let source = item.sources.first { env.lifeLog.jumpToTimelineItem(source) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: "•").foregroundStyle(.tertiary)
                        (Text(verbatim: item.text) + (item.owner.map { Text(verbatim: "  ") + Text("担当: \($0)").foregroundStyle(.secondary) } ?? Text(verbatim: "")))
                            .multilineTextAlignment(.leading)
                            .wrapsFully(!isCompact)
                    }
                    .font(.system(size: LoreTheme.TextSize.body))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .allowsHitTesting(showsActions)
                .help(Text("元の記録へ移動"))
                .accessibilityLabel(Text(verbatim: item.text))
                .accessibilityIdentifier("\(accessibilityPrefix).item-\(section.kind.rawValue)-\(index)")
            }
        }
    }

    /// A digest calls open questions "things left open", because a day leaves more than questions open.
    static func title(_ kind: GeneratedNoteSectionKind, digest: Bool = false) -> String {
        switch kind {
        case .summary: "この日のこと"
        case .decisions: "決定事項"
        case .actionItems: "やること"
        case .openQuestions: digest ? "残ったこと" : "未解決の問い"
        }
    }

    private func iconButton(_ symbol: String, label: LocalizedStringKey, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: LoreTheme.TextSize.caption))
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Text(label))
        .accessibilityLabel(Text(label))
        .accessibilityIdentifier("\(accessibilityPrefix).\(id)")
    }

    private func generate() {
        Task {
            do { try await ai.generate(kind: kind, scope: scope) } catch {
                // The service keeps the reason in `failures`, which this view shows next to "Retry".
            }
        }
    }

    private func copy(_ note: GeneratedNote) {
        let title = switch subject {
        case .event(let event): event.title
        case .day(let day): day
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GeneratedNoteMarkdown.render(note, title: title), forType: .string)
    }
}

private extension View {
    /// Full height inside a scrolling timeline. The inspector does not scroll, and a text that keeps its full
    /// height there reports a huge minimum height at the narrow width the window measures with, which
    /// stretches the whole window layout, so it is capped instead.
    @ViewBuilder
    func wrapsFully(_ fully: Bool) -> some View {
        if fully {
            fixedSize(horizontal: false, vertical: true)
        } else {
            lineLimit(3)
        }
    }
}
