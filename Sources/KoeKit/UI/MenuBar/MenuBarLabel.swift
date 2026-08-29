import SwiftUI

/// メニューバーのアイコン。常駐アプリらしくモノクロで、状態はシンボルの差し替えで示す。
struct MenuBarLabel: View {
    var coordinator: DictationCoordinator
    var lifeLog: LifeLogCoordinator
    var settings: AppSettings

    private var isRecording: Bool { coordinator.isRecording }

    private var symbol: String {
        switch coordinator.phase {
        case .idle: "waveform"
        case .recording: "waveform.badge.mic"
        case .recognizing, .formatting, .inserting: "waveform.badge.magnifyingglass"
        case .finished(let outcome):
            switch outcome {
            case .completed: "waveform.badge.checkmark"
            case .cancelled: "waveform"
            case .formattingSkipped, .clipboardOnly: "waveform.badge.exclamationmark"
            case .failed: "waveform.badge.xmark"
            }
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isRecording)
                .contentTransition(.symbolEffect(.replace))
            if settings.showLevelMeterInMenuBar, isRecording {
                MiniLevelMeter(level: coordinator.inputLevel, tint: .primary)
            }
            if lifeLog.isCapturing || lifeLog.isRecoveringCapture {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .symbolEffect(.pulse, options: .repeating, isActive: lifeLog.isCapturing)
                    .accessibilityLabel(lifeLog.captureStatusText)
            }
        }
    }
}
