import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case common
    case models
    case privacy
    case sync
    case automation
    case dictation
    case modes
    case vocabulary
    case lifeLog
    case calendar

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .common: "一般"
        case .models: "AI整形"
        case .privacy: "プライバシー"
        case .sync: "同期"
        case .automation: "連携"
        case .dictation: "音声入力"
        case .modes: "モード"
        case .vocabulary: "語彙"
        case .lifeLog: "ライフログ"
        case .calendar: "カレンダー"
        }
    }

    var symbol: String {
        switch self {
        case .common: "gearshape"
        case .models: "cpu"
        case .privacy: "hand.raised"
        case .sync: "arrow.triangle.2.circlepath"
        case .automation: "link"
        case .dictation: "waveform.and.mic"
        case .modes: "slider.horizontal.3"
        case .vocabulary: "character.book.closed"
        case .lifeLog: "calendar.day.timeline.left"
        case .calendar: "calendar"
        }
    }
}

struct SettingsWindowView: View {
    var env: AppEnvironment

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { env.settingsSection }, set: { env.settingsSection = $0 ?? .common })) {
                Section("共通") {
                    row(.common)
                    row(.vocabulary)
                    row(.privacy)
                    row(.sync)
                    row(.automation)
                }
                Section("音声入力") {
                    row(.dictation)
                    row(.models)
                    row(.modes)
                }
                Section("ライフログ") {
                    row(.lifeLog)
                    row(.calendar)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 184, ideal: 204, max: 240)
        } detail: {
            detail.navigationTitle(LocalizedStringKey(env.settingsSection.title))
        }
        .frame(minWidth: 960, minHeight: 680)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        // Sidebarの記号と選択色もsystemの青ではなくLoreの墨色に揃える。
        .tint(LoreTheme.accent)
    }

    private func row(_ section: SettingsSection) -> some View {
        Label(LocalizedStringKey(section.title), systemImage: section.symbol)
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
        case .models: ModelsSettingsView(env: env)
        case .privacy: PrivacySettingsView(env: env)
        case .sync: SyncSettingsView(env: env)
        case .automation: AutomationSettingsView()
        case .dictation: DictationSettingsView(env: env)
        case .modes: EmptyView()
        case .vocabulary: VocabularySettingsView(env: env)
        case .lifeLog: LifeLogSettingsView(env: env)
        case .calendar: LifeLogCalendarSettingsView(env: env)
        }
    }
}
