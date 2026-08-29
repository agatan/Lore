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

/// メイン用途は同階層のtabとして切り替える。ライフログ内のCalendar sidebarと
/// アプリnavigationを二重に並べないことで、常に3カラムの情報構造を保つ。
public struct MainWindowView: View {
    var env: AppEnvironment

    public init(env: AppEnvironment) { self.env = env }

    public var body: some View {
        detail
            .frame(minWidth: 1_080, minHeight: 680)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("表示", selection: Binding(get: { env.mainSection }, set: { env.mainSection = $0 })) {
                        ForEach(MainSection.allCases) { section in
                            Text(section.title).tag(section)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 270)
                }
            }
            .task { env.refreshPermissions() }
            .sheet(isPresented: Binding(
                get: {
                    if AppEnvironment.usesScreenshotDemoData {
                        return AppEnvironment.forcesOnboardingForScreenshot
                    }
                    return !env.settings.onboardingCompleted
                },
                set: { _ in }
            )) {
                OnboardingView(env: env)
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
                Text("文字起こしに失敗しても発話を回収できるよう、短い音声チャンクをこのMacだけに保存します。音声をGroqへ送ることはありません。既定では30日後に削除します。")
            }
    }

    @ViewBuilder
    private var detail: some View {
        switch env.mainSection {
        case .lifeLog: LifeLogWindow(env: env)
        case .history: HistoryBrowserView(env: env)
        }
    }
}
