import SwiftUI

public enum SettingsSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case common
    case models
    case privacy
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
        case .models: "モデル"
        case .privacy: "プライバシー"
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
                    row(.models)
                    row(.privacy)
                    row(.automation)
                }
                Section("音声入力") {
                    row(.dictation)
                    row(.modes)
                    row(.vocabulary)
                }
                Section("ライフログ") {
                    row(.lifeLog)
                    row(.calendar)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
        } detail: {
            detail.navigationTitle(env.settingsSection.title)
        }
        .frame(minWidth: 900, minHeight: 640)
    }

    private func row(_ section: SettingsSection) -> some View {
        Label(section.title, systemImage: section.symbol)
            .badge(section == .vocabulary ? env.pendingSuggestions.count : 0)
            .tag(section)
    }

    @ViewBuilder
    private var detail: some View {
        switch env.settingsSection {
        case .modes:
            ModesSettingsView(env: env)
                .padding(22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        default:
            ScrollView {
                settingsPane
                    .padding(22)
                    .frame(maxWidth: 700, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var settingsPane: some View {
        switch env.settingsSection {
        case .common: GeneralSettingsView(env: env)
        case .models: ModelsSettingsView(env: env)
        case .privacy: PrivacySettingsView(env: env)
        case .automation: AutomationSettingsView()
        case .dictation: DictationSettingsView(env: env)
        case .modes: EmptyView()
        case .vocabulary: VocabularySettingsView(env: env)
        case .lifeLog: LifeLogSettingsView(env: env)
        case .calendar: LifeLogCalendarSettingsView(env: env)
        }
    }
}
