import AppKit
import SwiftUI

/// モードの編集(FR-4.4)。アプリごとの差異はここだけで表現する。
struct ModesSettingsView: View {
    /// 一覧で選べるもの。共通ルールを一覧の先頭に固定して、
    /// モードを書くときに「既に何が指示されているか」を同じ画面で読めるようにする(C-53)。
    enum Selection: Hashable {
        case sharedRules
        case mode(Mode.ID)
    }

    var env: AppEnvironment
    @State private var selection: Selection = .sharedRules
    @State private var draft: Mode?
    @State private var sharedDraft = ""
    @State private var showDeleteConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("アプリごとに仕上げ方を切り替えます。Defaultは、どのアプリにも当てはまらないときに使われます。")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)

            HStack(alignment: .top, spacing: 20) {
                modeList
                editor
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task { selectIfNeeded() }
        .onChange(of: env.modes.count) { _, _ in selectIfNeeded() }
        // 保存やDefaultのリセットで env 側が更新されたら、編集中の写しも合わせる。
        .onChange(of: env.sharedRules) { _, newValue in
            if !sharedHasChanges || sharedDraft.isEmpty { sharedDraft = newValue }
        }
    }

    private var modeList: some View {
        VStack(spacing: 8) {
            List(selection: $selection) {
                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("共通ルール")
                            .font(.system(size: 12, weight: .medium))
                        Text("すべてのモードの前に入る")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if env.isSharedRulesEdited {
                        Pill(text: "編集済み", tint: KoeTheme.accent, localized: true)
                    }
                }
                .tag(Selection.sharedRules)
                .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))

                Divider().opacity(0.5)

                ForEach(env.modes) { mode in
                    HStack(spacing: 6) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(mode.isFallback ? "フォールバック" : "\(mode.bundleIDs.count) アプリ")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if mode.id == BuiltinModes.defaultModeID {
                            Pill(text: "標準", tint: .secondary, localized: true)
                        }
                    }
                    .tag(Selection.mode(mode.id))
                    .accessibilityIdentifier("mode.row.\(mode.id)")
                    .listRowInsets(EdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10))
                }
            }
            // .sidebar はペインの中でもサイドバーの素材(ガラス)を継承してしまい、
            // 周りのカードと表現が食い違う。面は sunkenSurface に一元化する。
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(width: 210)
            .frame(maxHeight: .infinity)
            .sunkenSurface(cornerRadius: KoeTheme.panelCornerRadius)
            .onChange(of: selection) { _, _ in loadDraft() }

            HStack(spacing: 6) {
                Button {
                    Task { await addMode() }
                } label: {
                    Image(systemName: "plus")
                }
                .help("モードを追加")

                Button {
                    Task {
                        guard let mode = currentMode, let copy = await env.duplicateMode(mode) else { return }
                        selection = .mode(copy.id)
                    }
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(currentMode == nil || currentMode?.id == BuiltinModes.defaultModeID)
                .help("複製")

                Button {
                    showDeleteConfirm = true
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(currentMode == nil || currentMode?.id == BuiltinModes.defaultModeID)
                .help("削除")

                Spacer()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(width: 210)
        }
        .confirmationDialog(
            "「\(currentMode?.name ?? "")」を削除しますか？",
            isPresented: $showDeleteConfirm
        ) {
            Button("削除", role: .destructive) {
                Task {
                    guard case .mode(let id) = selection else { return }
                    await env.deleteMode(id: id)
                    selection = env.modes.first.map { Selection.mode($0.id) } ?? .sharedRules
                }
            }
        } message: { Text("この操作は取り消せません。") }
    }

    @ViewBuilder
    private var editor: some View {
        switch selection {
        case .sharedRules: sharedRulesEditor
        case .mode: modeEditor
        }
    }

    /// 共通ルールの編集。中身をそのまま見せるのが目的なので、入力欄を大きく取る。
    @ViewBuilder
    private var sharedRulesEditor: some View {
        VStack(alignment: .leading, spacing: 16) {
            SettingsCard(
                title: "共通ルール",
                footnote: "すべてのモードの指示より前に、この内容がそのまま渡されます。ここに書いてあることをモード側で繰り返す必要はありません。逆向きの指示を書くと、どちらが効くか分からなくなります。",
                fillsVertically: true
            ) {
                TextEditor(text: $sharedDraft)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 200, maxHeight: .infinity)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .sunkenSurface()
            }
            .frame(maxHeight: .infinity)

            HStack {
                Button("標準の内容に戻す") {
                    Task {
                        await env.resetSharedRules()
                        sharedDraft = env.sharedRules
                    }
                }
                .buttonStyle(.bordered)
                .disabled(!env.isSharedRulesEdited && sharedDraft == env.sharedRules)
                Spacer()
                Text(sharedHasChanges ? "未保存の変更があります" : "保存済み")
                    .font(.system(size: 10.5))
                    .foregroundStyle(sharedHasChanges ? KoeTheme.warning : Color.secondary.opacity(0.7))
                Button("保存") {
                    Task { await env.saveSharedRules(sharedDraft) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!sharedHasChanges)
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    private var sharedHasChanges: Bool { sharedDraft != env.sharedRules }

    @ViewBuilder
    private var modeEditor: some View {
        if let draft {
            // 縦スクロールは MainWindowView 側のペインが持っている。
            // ここで入れ子にすると高さが決まらず、スクロールの対象も曖昧になる。
            VStack(alignment: .leading, spacing: 16) {
                SettingsCard(title: "基本") {
                    SettingsRow(title: "名前") {
                        TextField("", text: bind(\.name))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 220)
                    }
                    SettingsRow(title: "言語") {
                        Picker("", selection: bind(\.languagePreference)) {
                            ForEach(LanguagePreference.allCases) { preference in
                                Text(LocalizedStringKey(preference.displayName)).tag(preference)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }
                }

                SettingsCard(
                    title: "このモードを使うアプリ",
                    footnote: "空にすると、どのアプリにも当てはまらない「既定のモード」になります。`com.jetbrains.*` のように * で複数まとめて指定できます。"
                ) {
                    bundleIDEditor(draft)
                }

                // このカードだけ縦を使い切る。長い指示文を書く場所なので、
                // 余白を空けておくより入力欄を広く取るほうが役に立つ。
                SettingsCard(
                    title: "仕上げの指示",
                    footnote: "どのモードにも共通の指示(言いよどみの削除・句読点・言い直しの整理・語彙の統一)が先に入ります。ここにはこのモード固有の指示だけを書きます。",
                    fillsVertically: true
                ) {
                    TextEditor(text: bind(\.prompt))
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 140, maxHeight: .infinity)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .sunkenSurface()
                }
                .frame(maxHeight: .infinity)

                HStack {
                    if draft.id == BuiltinModes.defaultModeID {
                        Button("標準の内容に戻す") {
                            Task {
                                await env.resetMode(id: draft.id)
                                loadDraft()
                            }
                        }
                        .buttonStyle(.bordered)
                    }
                    Spacer()
                    Text(hasChanges ? "未保存の変更があります" : "保存済み")
                        .font(.system(size: 10.5))
                        .foregroundStyle(hasChanges ? KoeTheme.warning : Color.secondary.opacity(0.7))
                    Button("保存") {
                        Task { await save() }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
                    .keyboardShortcut("s", modifiers: .command)
                }
            }
        } else {
            VStack {
                Spacer()
                Text("モードを選択してください")
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func bundleIDEditor(_ mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if mode.bundleIDs.isEmpty {
                Text("未設定(既定のモードとして使われます)")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(Array(mode.bundleIDs.enumerated()), id: \.offset) { index, bundleID in
                        HStack(spacing: 4) {
                            Text(bundleID)
                                .font(.system(size: 10.5, design: .monospaced))
                            Button {
                                draft?.bundleIDs.remove(at: index)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 9))
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background {
                            Capsule().fill(KoeTheme.accent.opacity(0.12))
                        }
                    }
                }
            }

            HStack(spacing: 8) {
                if let bundleID = env.coordinator.frontmostBundleID,
                   !mode.bundleIDs.contains(bundleID) {
                    Button {
                        draft?.bundleIDs.append(bundleID)
                    } label: {
                        Label(
                            "\(env.coordinator.frontmostAppName ?? bundleID) を追加",
                            systemImage: "arrow.down.app"
                        )
                        .font(.system(size: 11))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                Button {
                    chooseApplication()
                } label: {
                    Label("アプリを選択…", systemImage: "folder")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    // MARK: 操作

    private var currentMode: Mode? {
        guard case .mode(let id) = selection else { return nil }
        return env.modes.first { $0.id == id }
    }

    private var hasChanges: Bool {
        guard let draft, let current = currentMode else { return false }
        return draft.name != current.name
            || draft.prompt != current.prompt
            || draft.bundleIDs != current.bundleIDs
            || draft.languagePreference != current.languagePreference
    }

    private func bind<Value>(_ keyPath: WritableKeyPath<Mode, Value>) -> Binding<Value> {
        Binding(
            get: { draft?[keyPath: keyPath] ?? BuiltinModes.defaultMode[keyPath: keyPath] },
            set: { draft?[keyPath: keyPath] = $0 }
        )
    }

    private func selectIfNeeded() {
        if case .mode(let id) = selection, !env.modes.contains(where: { $0.id == id }) {
            selection = env.modes.first.map { Selection.mode($0.id) } ?? .sharedRules
        }
        loadDraft()
    }

    private func loadDraft() {
        draft = currentMode
        sharedDraft = env.sharedRules
    }

    private func save() async {
        guard let draft else { return }
        await env.save(mode: draft)
        loadDraft()
    }

    private func addMode() async {
        let mode = Mode(
            name: "新しいモード",
            bundleIDs: [],
            prompt: "ここにこのモード固有の整形指示を書きます。",
            sortOrder: (env.modes.map(\.sortOrder).max() ?? 0) + 10
        )
        await env.save(mode: mode)
        selection = .mode(mode.id)
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = true
        panel.prompt = "追加"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier else { continue }
            if draft?.bundleIDs.contains(bundleID) == false {
                draft?.bundleIDs.append(bundleID)
            }
        }
    }
}

/// bundle ID のチップを折り返して並べる軽量レイアウト。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? 400
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth, rowWidth > 0 {
                totalHeight += rowHeight + spacing
                rowWidth = 0
                rowHeight = 0
            }
            rowWidth += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: totalHeight + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
