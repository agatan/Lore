import SwiftUI

public enum MainSection: String, CaseIterable, Identifiable, Hashable, Sendable {
    case lifeLog
    case history

    public var id: String { rawValue }

    var title: String {
        switch self {
        case .lifeLog: "ライフログ"
        case .history: "音声入力"
        }
    }

    var symbol: String {
        switch self {
        case .lifeLog: "calendar.day.timeline.left"
        case .history: "waveform.and.mic"
        }
    }
}

/// Mail・Notesと同じく、全高のsidebarにnavigationとその表示の補助(calendar)を置き、
/// 右のcontentを1つの主題に集中させる。Toolbarはcontent側の操作だけを持つ。
public struct MainWindowView: View {
    var env: AppEnvironment

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        Group {
            if showsOnboarding {
                OnboardingView(env: env)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                NavigationSplitView {
                    MainSidebar(env: env)
                        .navigationSplitViewColumnWidth(min: 252, ideal: 276, max: 340)
                } detail: {
                    detail
                }
            }
        }
            .frame(minWidth: 1_080, minHeight: 680)
            // Sidebarの記号と選択色もsystemの青ではなくLoreの墨色に揃える。
            .tint(LoreTheme.accent)
            .toolbar(removing: .title)
            // Toolbarの下に硬い罫線を引かず、scroll edge effectで内容との境界を作る。
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .task {
                env.mainSection = .lifeLog
                await env.boot()
            }
            .confirmationDialog(
                "ライフログの音声を保存しますか？",
                isPresented: Binding(
                    get: { env.presentsLifeLogAudioConsent },
                    set: { if !$0 { env.cancelLifeLogAudioStorageConsent() } }
                )
            ) {
                Button("保存して記録を開始") {
                    env.confirmLifeLogAudioStorageAndStart()
                }
                Button("キャンセル", role: .cancel) {
                    env.cancelLifeLogAudioStorageConsent()
                }
            } message: {
                Text("文字起こしに失敗しても発話を回収できるよう、短い音声チャンクをこのMacだけに保存します。音声を外部へ送ることはありません。既定では文字起こしが終わった音声から削除します。")
            }
    }

    private var showsOnboarding: Bool {
        if AppEnvironment.usesScreenshotDemoData {
            return AppEnvironment.forcesOnboardingForScreenshot
        }
        return !env.settings.onboardingCompleted
    }

    @ViewBuilder
    private var detail: some View {
        switch env.mainSection {
        case .lifeLog: LifeLogWindow(env: env)
        case .history: HistoryBrowserView(env: env)
        }
    }
}

/// Main windowのsidebar。上から navigation、ライフログ表示中だけ月間calendar。
/// その日の流れは右のinspectorが受け持ち、sidebarは「どこを見るか」だけを選ぶ場所にする。
/// 面や枠は足さず、system sidebarの素材と見出しだけで区切る。
private struct MainSidebar: View {
    var env: AppEnvironment

    var body: some View {
        List(selection: Binding(get: { env.mainSection }, set: { if let value = $0 { env.mainSection = value } })) {
            Section {
                ForEach(MainSection.allCases) { section in
                    // 行の選択に加えてAXPressで切り替えられるよう、行の中身をbuttonにする。
                    Button { env.mainSection = section } label: {
                        Label(LocalizedStringKey(section.title), systemImage: section.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(LocalizedStringKey(section.title))
                    .accessibilityIdentifier("main.section.\(section.rawValue)")
                    .tag(section)
                }
            }
            if env.mainSection == .lifeLog {
                Section {
                    MonthActivityCalendar(
                        selectedDate: Binding(get: { env.lifeLog.selectedDate }, set: { _ in }),
                        activity: env.lifeLog.monthActivity,
                        onSelect: { date in
                            Task {
                                await env.lifeLog.select(date: date)
                                if !AppEnvironment.usesScreenshotDemoData {
                                    await env.lifeLog.refreshCalendar(selectedCalendars: Set(env.settings.lifeLogCalendarTitles))
                                }
                            }
                        },
                        onMonthChanged: { date in Task { await env.lifeLog.loadActivity(containing: date) } }
                    )
                    .padding(.top, 2)
                    .padding(.bottom, 6)
                    .selectionDisabled()
                }
            }
        }
        .listStyle(.sidebar)
        .accessibilityIdentifier("main.section-picker")
    }
}
