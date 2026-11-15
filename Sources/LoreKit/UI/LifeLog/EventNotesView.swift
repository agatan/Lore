import AppKit
import SwiftUI

/// The AI notes under one event in the main window timeline, and the controls to make them.
/// All decisions (may it send, is it stale) come from the domain; this view only draws them.
struct EventNotesView: View {
    var env: AppEnvironment
    var event: CalendarEventSnapshot

    @State private var confirmsDelete = false

    private var ai: LifeLogAIService { env.lifeLogAI }
    private var scope: GeneratedNoteScope { .event(EventOccurrence(event)) }
    private var note: GeneratedNote? { env.lifeLog.day.eventNotes(for: event) }
    private var isExcluded: Bool { env.settings.lifeLogAI.excludes(event, excludedEventIDs: ai.excludedEventIDs) }
    private var canSend: Bool { env.settings.lifeLogAI.sendPermission == .allowed && !isExcluded }
    private var isGenerating: Bool { ai.generatingScopes.contains(scope.key) }
    private var failure: String? { ai.failures[scope.key] }
    private var accessibilityPrefix: String { "life-log.event-notes-\(event.id)" }

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
                    Text("ノートを作成しています")
                        .font(LoreTheme.captionFont)
                        .foregroundStyle(.secondary)
                }
            } else if canSend, !event.isAllDay {
                // The button appears when the event ends, without waiting for another redraw.
                // `context.date` is the scheduled date even before it arrives, so compare with the clock.
                TimelineView(.explicit([event.endsAt])) { _ in
                    if event.endsAt <= Date() {
                        Button {
                            generate()
                        } label: {
                            Label("ノートを作成", systemImage: "sparkles")
                        }
                        .buttonStyle(.link)
                        .font(LoreTheme.captionFont)
                        .accessibilityIdentifier("\(accessibilityPrefix).generate")
                    }
                }
            }
            if let failure, !isGenerating {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(failure)
                        .font(LoreTheme.captionFont)
                        .foregroundStyle(LoreTheme.danger)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("再試行") { generate() }
                        .buttonStyle(.link)
                        .font(LoreTheme.captionFont)
                        .disabled(!canSend)
                        .accessibilityIdentifier("\(accessibilityPrefix).retry")
                }
            }
        }
        .padding(.top, 6)
        .confirmationDialog("このノートを削除しますか？", isPresented: $confirmsDelete) {
            Button("ノートを削除", role: .destructive) {
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

    private func noteCard(_ note: GeneratedNote) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            header(note)
            if !note.staleReasons.isEmpty { staleNotice(note) }
            if note.isEmpty {
                Text("記録する決定事項・やること・未解決の問いはありませんでした")
                    .font(.system(size: LoreTheme.TextSize.body))
                    .foregroundStyle(.secondary)
            }
            ForEach(note.sections.filter { !$0.items.isEmpty }, id: \.kind) { section in
                sectionView(section)
            }
            Text("このMacのマイクの記録だけから作成しています。オンライン会議の他の参加者の発言は含まれません。")
                .font(.system(size: LoreTheme.TextSize.micro))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
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
            Text("AIが生成")
                .font(.system(size: LoreTheme.TextSize.caption, weight: .semibold))
                .accessibilityIdentifier("\(accessibilityPrefix).generated-mark")
            Text(verbatim: "· \(note.backend.displayName)")
                .font(LoreTheme.captionFont)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("\(accessibilityPrefix).provider")
            Spacer(minLength: 8)
            iconButton("doc.on.doc", label: "Markdownでコピー", id: "copy") { copy(note) }
            iconButton("arrow.clockwise", label: "再生成", id: "regenerate") { generate() }
                .disabled(!canSend || isGenerating)
            iconButton("trash", label: "ノートを削除", id: "delete") { confirmsDelete = true }
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
            .fixedSize(horizontal: false, vertical: true)
            Button("再生成") { generate() }
                .buttonStyle(.link)
                .font(LoreTheme.captionFont)
                .disabled(!canSend || isGenerating)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("\(accessibilityPrefix).stale")
    }

    private func sectionView(_ section: GeneratedNoteSection) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(Self.title(section.kind)))
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
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: LoreTheme.TextSize.body))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(Text("元の記録へ移動"))
                .accessibilityLabel(Text(verbatim: item.text))
                .accessibilityIdentifier("\(accessibilityPrefix).item-\(section.kind.rawValue)-\(index)")
            }
        }
    }

    static func title(_ kind: GeneratedNoteSectionKind) -> String {
        switch kind {
        case .decisions: "決定事項"
        case .actionItems: "やること"
        case .openQuestions: "未解決の問い"
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
            do { try await ai.generate(kind: .eventNotes, scope: scope) } catch {
                // The service keeps the reason in `failures`, which this view shows next to "Retry".
            }
        }
    }

    private func copy(_ note: GeneratedNote) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(GeneratedNoteMarkdown.render(note, title: event.title), forType: .string)
    }
}
