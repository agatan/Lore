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
            .background(.quaternary.opacity(0.4))
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch env.mainSection {
        case .history:
            HistoryBrowserView(env: env)
        case .general, .modes, .vocabulary, .models, .privacy:
            ScrollView {
                settingsPane
                    .padding(22)
                    .frame(maxWidth: 660, alignment: .leading)
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
