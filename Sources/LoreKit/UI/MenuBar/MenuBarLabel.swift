import AppKit
import SwiftUI

/// メニューバーのアイコン。App iconと同じ「L.」を描き、状態は「.」の色だけで示す。
///
/// - 録音中（音声入力またはライフログ）はrose、処理中は「L」と同じ色の輪、完了はmint、要確認はgold。ライフログの再接続中はgoldの輪。
/// - 入力level表示が有効な音声入力の録音中は、「.」が直近の声の大きさで膨らむ。
/// - 状態がない時はtemplate画像にして、menu barの明暗と強調表示をsystemに任せる。
struct MenuBarLabel: View {
    var coordinator: DictationCoordinator
    var lifeLog: LifeLogCoordinator
    var settings: AppSettings

    var body: some View {
        let badge = MenuBarStatusIcon.badge(phase: coordinator.phase, lifeLog: lifeLog)
        let level = coordinator.isRecording && settings.showLevelMeterInMenuBar
            ? coordinator.levelHistory.last
            : nil
        let image = MenuBarStatusIcon.image(level: level, badge: badge)
        Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .accessibilityLabel(Text(LocalizedStringKey(accessibilityText)))
    }

    private var accessibilityText: String {
        if coordinator.phase != .idle { return LoreTheme.label(for: coordinator.phase) }
        if lifeLog.isCapturing || lifeLog.isRecoveringCapture { return lifeLog.captureStatusText }
        return "Lore"
    }
}

@MainActor
enum MenuBarStatusIcon {
    enum Badge: Equatable {
        case recording
        /// 処理中。「L」と同じ色の輪で、声はもう受け取って仕上げていることを示す。
        case processing
        case done
        case attention
        /// ライフログの再接続中。goldの輪で「止まってはいないが記録できていない」を示す。
        case reconnecting

        var color: NSColor {
            switch self {
            case .recording: NSColor(LoreTheme.recording)
            case .processing: .labelColor
            case .done: NSColor(LoreTheme.success)
            case .attention, .reconnecting: NSColor(LoreTheme.warning)
            }
        }
    }

    static let size = NSSize(width: 22, height: 18)

    /// 音声入力の状態を優先し、音声入力が待機中または録音中ならライフログ記録の色を見せる。
    static func badge(phase: SessionPhase, lifeLog: LifeLogCoordinator) -> Badge? {
        switch phase {
        case .recording: return .recording
        case .recognizing, .formatting, .inserting: return .processing
        case .finished(.completed): return .done
        case .finished(.formattingSkipped), .finished(.clipboardOnly), .finished(.failed): return .attention
        case .idle, .finished(.cancelled): break
        }
        if lifeLog.isCapturing { return .recording }
        if lifeLog.isRecoveringCapture { return .reconnecting }
        return nil
    }

    /// `level`を渡すと「.」の半径を声の大きさで広げる。
    static func image(level: Float? = nil, badge: Badge?) -> NSImage {
        let radius = dotRadius(level: level)
        let image = NSImage(size: size, flipped: false) { _ in
            drawL(color: badge == nil ? .black : .labelColor)
            drawDot(badge: badge, radius: radius)
            return true
        }
        image.isTemplate = badge == nil
        return image
    }

    /// 既存の呼び出し口。ライフログ記録中のアイコン。
    static func lifeLogRecording() -> NSImage {
        image(badge: .recording)
    }

    static let baseDotRadius: CGFloat = 2.6
    static let maximumDotRadius: CGFloat = 3.8

    static func dotRadius(level: Float?) -> CGFloat {
        guard let level else { return baseDotRadius }
        // 小さい声でも動きが見えるよう緩く持ち上げ、上限で頭打ちにする。
        let amplitude = min(1, pow(CGFloat(max(0, level)), 0.6) * 1.2)
        return baseDotRadius + amplitude * (maximumDotRadius - baseDotRadius)
    }

    private static func drawL(color: NSColor) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 5.5, y: 15.5))
        path.line(to: NSPoint(x: 5.5, y: 3.5))
        path.line(to: NSPoint(x: 11.5, y: 3.5))
        path.lineWidth = 2.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        path.stroke()
    }

    /// 「.」は足の高さに中心を揃え、膨らむ時も「L」へ重ならない位置に置く。
    private static func drawDot(badge: Badge?, radius: CGFloat) {
        let center = NSPoint(x: 17, y: 3.5 + max(0, radius - baseDotRadius))
        let rect = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
        guard let badge else {
            NSColor.black.setFill()
            NSBezierPath(ovalIn: rect).fill()
            return
        }
        if badge == .reconnecting || badge == .processing {
            let ring = NSBezierPath(ovalIn: rect.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            badge.color.setStroke()
            ring.stroke()
        } else {
            badge.color.setFill()
            NSBezierPath(ovalIn: rect).fill()
        }
    }
}
