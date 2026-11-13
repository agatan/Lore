import SwiftUI

/// ライフログの状態と開始・停止操作を、main / mini / menu barで同じ意味に揃える。
struct LifeLogCaptureControl: View {
    var lifeLog: LifeLogCoordinator
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
                if lifeLog.hasCaptureIntent {
                    Text(LocalizedStringKey(lifeLog.captureStatusText))
                        .font(KoeTheme.captionFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
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

    private var buttonTitle: String {
        lifeLog.hasCaptureIntent ? "停止" : "記録を開始"
    }

    private var statusTint: Color {
        if lifeLog.isCapturing { return KoeTheme.recording }
        if lifeLog.isRecoveringCapture || lifeLog.hasCaptureIntent { return KoeTheme.warning }
        return .secondary
    }

    private var statusSymbol: String {
        if lifeLog.isRecoveringCapture { return "arrow.trianglehead.2.clockwise.rotate.90" }
        if lifeLog.isCapturing { return "waveform" }
        if lifeLog.hasCaptureIntent { return "ellipsis" }
        return "waveform.slash"
    }

    private var statusTitle: String {
        if lifeLog.isSuspendedForVoiceMemo { return "ライフログ一時停止中" }
        if lifeLog.isRecoveringCapture { return "ライフログ再接続中" }
        if lifeLog.isCapturing { return "ライフログ記録中" }
        if lifeLog.hasCaptureIntent { return "ライフログ開始中" }
        return "ライフログ停止中"
    }

    private var actionLabel: String {
        lifeLog.hasCaptureIntent ? "ライフログ録音を停止" : "ライフログ録音を開始"
    }
}
