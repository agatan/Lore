import SwiftUI

/// 記録buttonの隣に置く一時停止。記録中は長さを選ぶmenu、一時停止中は再開button。
/// 停止中と、予定のために録音を止めている間は出さない。
struct LifeLogPauseControl: View {
    var env: AppEnvironment
    /// 例: `life-log`、`menu.life-log`。
    var accessibilityPrefix: String
    var diameter: CGFloat = 26

    var body: some View {
        if env.lifeLog.hasCaptureIntent {
            switch env.lifeLog.hold {
            case .paused:
                Button { env.resumeLifeLog() } label: { glyph("play.fill") }
                    .buttonStyle(.plain)
                    .help("ライフログを再開")
                    .accessibilityLabel("ライフログを再開")
                    .accessibilityIdentifier("\(accessibilityPrefix).resume")
            case .event:
                EmptyView()
            case nil:
                Menu {
                    ForEach(LifeLogPauseLength.allCases, id: \.self) { length in
                        Button(LocalizedStringKey(length.title)) { pause(length) }
                            .disabled(length == .untilEventEnds && env.currentLifeLogEvent() == nil)
                            .accessibilityIdentifier("\(accessibilityPrefix).pause.\(length.accessibilitySuffix)")
                    }
                } label: {
                    glyph("pause.fill")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("ライフログを一時停止")
                .accessibilityLabel("ライフログを一時停止")
                .accessibilityIdentifier("\(accessibilityPrefix).pause")
            }
        }
    }

    private func glyph(_ symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: diameter * 0.42, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: diameter, height: diameter)
            .background(Color.secondary.opacity(0.14), in: Circle())
            .contentShape(Circle())
    }

    private func pause(_ length: LifeLogPauseLength) {
        do {
            try env.pauseLifeLog(length)
        } catch {
            env.lifeLog.showNotice(error.localizedDescription)
        }
    }
}

extension LifeLogPauseLength {
    var title: String {
        switch self {
        case .fifteenMinutes: "15分"
        case .thirtyMinutes: "30分"
        case .oneHour: "1時間"
        case .untilEventEnds: "いまの予定が終わるまで"
        }
    }

    var accessibilitySuffix: String {
        switch self {
        case .fifteenMinutes: "15m"
        case .thirtyMinutes: "30m"
        case .oneHour: "1h"
        case .untilEventEnds: "event"
        }
    }
}
