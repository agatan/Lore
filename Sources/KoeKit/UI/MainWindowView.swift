import SwiftUI

/// 履歴と設定を 1 つのウィンドウにまとめたメイン画面。
///
/// 別ウィンドウに分けると行き来が面倒で、どちらを見ているのか分からなくなる。
/// サイドバーで切り替える形にして、履歴からそのまま設定へ移れるようにする。
public enum MainSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case history
    case general
    case modes
    case vocabulary
    case models
    case privacy

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .history: "履歴"
        case .general: "一般"
        case .modes: "モード"
        case .vocabulary: "語彙"
        case .models: "モデル"
        case .privacy: "プライバシー"
        }
    }

    var symbol: String {
        switch self {
        case .history: "clock.arrow.circlepath"
        case .general: "gearshape"
        case .modes: "slider.horizontal.3"
        case .vocabulary: "character.book.closed"
        case .models: "cpu"
        case .privacy: "hand.raised"
        }
    }

    static var settingsSections: [MainSection] {
        [.general, .modes, .vocabulary, .models, .privacy]
    }

    /// 本文の横幅の上限。`nil` = ウィンドウの幅を使い切る。
    ///
    /// 1 カラムの設定は行が長すぎると読みにくいので絞る。ただしモードは
    /// 「一覧 + 編集」の 2 カラムなので、同じ上限をかけると編集側が極端に狭くなる
    /// (プロンプト欄が数語で折り返す)。段組みの数が違うものに同じ幅を当てない。
    var contentMaxWidth: CGFloat? {
        switch self {
        case .modes: nil
        default: 660
        }
    }
}

public struct MainWindowView: View {
    var env: AppEnvironment

    public init(env: AppEnvironment) {
        self.env = env
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 176, ideal: 188, max: 240)
        } detail: {
            detail
                .navigationTitle(env.mainSection.title)
        }
        .frame(minWidth: 940, minHeight: 580)
        .task { env.refreshPermissions() }
    }

    private var sidebar: some View {
        List(selection: Binding(get: { env.mainSection }, set: { env.mainSection = $0 ?? .history })) {
            Section {
                row(.history)
            }
            Section("設定") {
                ForEach(MainSection.settingsSections) { section in
                    row(section)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            footer
        }
    }

    private func row(_ section: MainSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(badge(for: section))
            .tag(section)
    }

    private func badge(for section: MainSection) -> Int {
        switch section {
        case .history: 0
        case .vocabulary: env.pendingSuggestions.count
        default: 0
        }
    }

    /// 権限が欠けていると中核機能が動かないので、常に見える場所に出す。
    @ViewBuilder
    private var footer: some View {
        if !env.isAccessibilityGranted || !env.isMicrophoneGranted {
            Button {
                env.mainSection = .general
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(KoeTheme.warning)
                    Text("権限が未設定")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .raisedGlass(cornerRadius: KoeTheme.cardCornerRadius, tint: KoeTheme.warning)
            .padding(8)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch env.mainSection {
        case .history:
            HistoryBrowserView(env: env)
        case .modes:
            // 「一覧 + 編集」の 2 カラムなので、ペイン全体をスクロールさせない。
            // 外側にスクロールを置くと高さが無限に提案され、子が縦を使い切れなくなる。
            // スクロールはカラムごとに持たせる。
            ModesSettingsView(env: env)
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .general, .vocabulary, .models, .privacy:
            ScrollView {
                settingsPane
                    .padding(22)
                    .frame(maxWidth: env.mainSection.contentMaxWidth ?? .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var settingsPane: some View {
        switch env.mainSection {
        case .general: GeneralSettingsView(env: env)
        case .modes: ModesSettingsView(env: env)
        case .vocabulary: VocabularySettingsView(env: env)
        case .models: ModelsSettingsView(env: env)
        case .privacy: PrivacySettingsView(env: env)
        case .history: EmptyView()
        }
    }
}
