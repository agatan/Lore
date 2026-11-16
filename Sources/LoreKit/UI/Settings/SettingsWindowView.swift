import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case common
    case aiProviders
    case privacy
    case sync
    case automation
    case dictation
    case modes
    case vocabulary
    case lifeLog
    case calendar
    case lifeLogAI

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .common: "一般"
        case .aiProviders: "AIプロバイダ"
        case .privacy: "プライバシー"
        case .sync: "同期"
        case .automation: "連携"
        case .dictation: "音声入力"
        case .modes: "モード"
        case .vocabulary: "語彙"
        case .lifeLog: "ライフログ"
        case .calendar: "カレンダー"
        case .lifeLogAI: "ライフログAI"
        }
    }

    var symbol: String {
        switch self {
        case .common: "gearshape"
        case .aiProviders: "cpu"
        case .privacy: "hand.raised"
        case .sync: "arrow.triangle.2.circlepath"
        case .automation: "link"
        case .dictation: "waveform.and.mic"
        case .modes: "slider.horizontal.3"
        case .vocabulary: "character.book.closed"
        case .lifeLog: "calendar.day.timeline.left"
        case .calendar: "calendar"
        case .lifeLogAI: "sparkles"
        }
    }

    /// Sidebarの塊ごとの機能の色。
    var tint: Color {
        switch self {
        case .common, .privacy, .aiProviders: LoreTheme.generalTint
        case .lifeLog, .calendar, .lifeLogAI: LoreTheme.lifeLogTint
        case .dictation, .modes, .vocabulary: LoreTheme.dictationTint
        case .sync, .automation: LoreTheme.connectTint
        }
    }
}

struct SettingsWindowView: View {
    var env: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { env.settingsSection }, set: { env.settingsSection = $0 ?? .common })) {
                // 見出しを付けると項目名と重なる（「音声入力」の下に「音声入力」）ため、
                // システム設定と同じく見出しのない塊で分ける。
                Section {
                    row(.common)
                    row(.privacy)
                    row(.aiProviders)
                }
                Section {
                    row(.lifeLog)
                    row(.calendar)
                    row(.lifeLogAI)
                }
                Section {
                    row(.dictation)
                    row(.modes)
                    row(.vocabulary)
                }
                Section {
                    row(.sync)
                    row(.automation)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 184, ideal: 204, max: 240)
        } detail: {
            // Window titleはSwiftUIの環境localeでなくprocessの言語で解決されるため、表示言語で引いた文字列を渡す。
            detail.navigationTitle(LoreLocalization.string(
                String.LocalizationValue(env.settingsSection.title),
                language: env.settings.applicationLanguage
            ))
        }
        .frame(minWidth: 960, minHeight: 680)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }

    private func row(_ section: SettingsSection) -> some View {
        SidebarLabel(title: section.title, symbol: section.symbol, tint: section.tint)
            .tag(section)
            .accessibilityIdentifier("settings.section.\(section.rawValue)")
    }

    @ViewBuilder
    private var detail: some View {
        switch env.settingsSection {
        case .modes:
            // Modeの編集はscrollせず、windowの高さの中で入力欄を伸び縮みさせる。
            // 高さをwindowに固定し、中身の理想の高さでpaneが押し広げられないようにする。
            GeometryReader { proxy in
                ModesSettingsView(env: env)
                    .padding(22)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            }
        default:
            ScrollView {
                settingsPane
                    .padding(22)
                    .frame(maxWidth: 740, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var settingsPane: some View {
        switch env.settingsSection {
        case .common: GeneralSettingsView(env: env)
        case .aiProviders: AIProvidersSettingsView(env: env)
        case .privacy: PrivacySettingsView(env: env)
        case .sync: SyncSettingsView(env: env)
        case .automation: AutomationSettingsView()
        case .dictation: DictationSettingsView(env: env)
        case .modes: EmptyView()
        case .vocabulary: VocabularySettingsView(env: env)
        case .lifeLog: LifeLogSettingsView(env: env)
        case .calendar: LifeLogCalendarSettingsView(env: env)
        case .lifeLogAI: LifeLogAISettingsView(env: env)
        }
    }
}
