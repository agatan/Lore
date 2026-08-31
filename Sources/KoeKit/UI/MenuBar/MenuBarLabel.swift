import AppKit
import SwiftUI

/// メニューバーのアイコン。ライフログ実録音中はKoeアイコン右下のバッジで判別できるようにする。
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

    @ViewBuilder
    var body: some View {
        if lifeLog.isCapturing {
            Image(nsImage: MenuBarStatusIcon.lifeLogRecording())
                .renderingMode(.original)
                .accessibilityLabel(lifeLog.captureStatusText)
        } else {
            standardLabel
        }
    }

    private var standardLabel: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: isRecording)
                .contentTransition(.symbolEffect(.replace))
            if settings.showLevelMeterInMenuBar, isRecording {
                MiniLevelMeter(level: coordinator.inputLevel, tint: .primary)
            }
            if lifeLog.isRecoveringCapture {
                Image(systemName: "record.circle.fill")
                    .font(.system(size: 8, weight: .bold))
                    .accessibilityLabel(lifeLog.captureStatusText)
            }
        }
    }
}

@MainActor
enum MenuBarStatusIcon {
    static func lifeLogRecording() -> NSImage {
        let size = NSSize(width: 24, height: 20)
        let image = NSImage(size: size, flipped: false) { rect in
            drawKoeMark()

            let badgeRect = NSRect(x: 14, y: 0.5, width: 9, height: 9)
            let badgeBorder = NSBezierPath(ovalIn: badgeRect)
            NSColor.windowBackgroundColor.setFill()
            badgeBorder.fill()

            let badge = NSBezierPath(ovalIn: badgeRect.insetBy(dx: 1.25, dy: 1.25))
            NSGradient(colors: [
                NSColor(red: 0.89, green: 0.33, blue: 0.44, alpha: 1),
                NSColor(red: 0.94, green: 0.46, blue: 0.52, alpha: 1),
            ])?.draw(in: badge, angle: 0)
            return true
        }
        image.isTemplate = false
        return image
    }

    private static func drawKoeMark() {
        let heights: [CGFloat] = [5, 9, 13, 17, 11, 7, 14, 9, 5]
        let barWidth: CGFloat = 1.5
        let gap: CGFloat = 0.45
        let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
        var x = 1 + (18 - totalWidth) / 2
        NSColor.labelColor.setFill()
        for height in heights {
            let bar = NSRect(x: x, y: 1 + (18 - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }
}
