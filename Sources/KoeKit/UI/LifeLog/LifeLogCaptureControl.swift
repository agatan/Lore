import SwiftUI

/// ライフログの状態と開始・停止操作を、main / mini / menu barで同じ意味に揃える。
struct LifeLogCaptureControl: View {
    var lifeLog: LifeLogCoordinator
    var accessibilityIdentifier: String
    var onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusTint.opacity(0.14))
                    .frame(width: 42, height: 42)
                Image(systemName: statusSymbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(statusTint)
                    .symbolEffect(.variableColor.iterative, isActive: lifeLog.isCapturing)
                    .symbolEffect(.rotate, options: .repeating, isActive: lifeLog.isRecoveringCapture)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 12.5, weight: .semibold))
                Text(lifeLog.captureStatusText)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onToggle) {
                Image(systemName: lifeLog.hasCaptureIntent ? "stop.fill" : "record.circle.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(buttonFill, in: Circle())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .help(actionLabel)
            .accessibilityLabel(actionLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
        }
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

    private var buttonFill: AnyShapeStyle {
        lifeLog.hasCaptureIntent
            ? AnyShapeStyle(KoeTheme.recordingGradient)
            : AnyShapeStyle(KoeTheme.voiceGradient)
    }

    private var actionLabel: String {
        lifeLog.hasCaptureIntent ? "ライフログ録音を停止" : "ライフログ録音を開始"
    }
}
