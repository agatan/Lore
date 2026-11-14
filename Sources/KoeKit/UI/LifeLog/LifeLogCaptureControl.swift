import SwiftUI

/// ライフログの状態と開始・停止操作を、main / mini / menu barで同じ意味に揃える。
struct LifeLogCaptureControl: View {
    var lifeLog: LifeLogCoordinator
    /// 自動記録中の終了時刻、または待機中の次の開始時刻。
    var scheduleCaption: AppEnvironment.LifeLogScheduleCaption? = nil
    var accessibilityIdentifier: String
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(statusTint)
                .symbolEffect(.variableColor.iterative, isActive: lifeLog.isCapturing)
                .symbolEffect(.rotate, options: .repeating, isActive: lifeLog.isRecoveringCapture)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(LocalizedStringKey(statusTitle))
                    .font(.system(size: 12, weight: .medium))
                // 停止中は見出しだけで状態が伝わるため、同じ意味の補足を重ねない。
                // 自動記録の時刻は停止中でも次の動きを示す情報なので出す。
                if let caption = subtitle {
                    Text(caption)
                        .font(KoeTheme.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .accessibilityIdentifier("\(accessibilityIdentifier).schedule")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggle) {
                Label(LocalizedStringKey(buttonTitle), systemImage: lifeLog.hasCaptureIntent ? "stop.fill" : "record.circle")
                    .font(.system(size: 12, weight: .medium))
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
            .tint(lifeLog.hasCaptureIntent ? KoeTheme.recording : KoeTheme.accent)
            .controlSize(.regular)
            .help(LocalizedStringKey(actionLabel))
            .accessibilityLabel(LocalizedStringKey(actionLabel))
            .accessibilityIdentifier(accessibilityIdentifier)
        }
    }

    private var status: LifeLogCaptureStatus { LifeLogCaptureStatus(lifeLog: lifeLog, scheduleCaption: scheduleCaption) }
    private var subtitle: LocalizedStringKey? { status.subtitle }
    private var buttonTitle: String { status.buttonTitle }
    private var statusTint: Color { status.tint }
    private var statusSymbol: String { status.symbol }
    private var statusTitle: String { status.title }
    private var actionLabel: String { status.actionLabel }
}

/// 記録状態の文言・symbol・色。Menu barとmain/miniのbarで同じ判断を使う。
@MainActor
struct LifeLogCaptureStatus {
    var lifeLog: LifeLogCoordinator
    var scheduleCaption: AppEnvironment.LifeLogScheduleCaption?

    /// 停止中は見出しだけで状態が伝わるため、同じ意味の補足を重ねない。
    /// 自動記録の時刻は停止中でも次の動きを示す情報なので出す。
    var subtitle: LocalizedStringKey? {
        guard lifeLog.hasCaptureIntent else { return scheduleCaption?.text }
        // 再接続や一時停止は自動記録の時刻より優先して伝える。
        if lifeLog.isCapturing, let scheduleCaption { return scheduleCaption.text }
        return LocalizedStringKey(lifeLog.captureStatusText)
    }

    var buttonTitle: String {
        lifeLog.hasCaptureIntent ? "停止" : "記録を開始"
    }

    var tint: Color {
        if lifeLog.isCapturing { return KoeTheme.recording }
        if lifeLog.isRecoveringCapture || lifeLog.hasCaptureIntent { return KoeTheme.warning }
        return .secondary
    }

    var symbol: String {
        if lifeLog.isRecoveringCapture { return "arrow.trianglehead.2.clockwise.rotate.90" }
        if lifeLog.isCapturing { return "waveform" }
        if lifeLog.hasCaptureIntent { return "ellipsis" }
        return "waveform.slash"
    }

    var title: String {
        if lifeLog.isSuspendedForVoiceMemo { return "ライフログ一時停止中" }
        if lifeLog.isRecoveringCapture { return "ライフログ再接続中" }
        if lifeLog.isCapturing { return "ライフログ記録中" }
        if lifeLog.hasCaptureIntent { return "ライフログ開始中" }
        return "ライフログ停止中"
    }

    var actionLabel: String {
        lifeLog.hasCaptureIntent ? "ライフログ録音を停止" : "ライフログ録音を開始"
    }
}

extension AppEnvironment.LifeLogScheduleCaption {
    var text: LocalizedStringKey {
        switch self {
        case .recordingUntil(let time): "自動記録中・\(time)まで"
        case .nextStart(let time): "次の自動記録 \(time)"
        }
    }
}
