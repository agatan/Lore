import AppKit
import SwiftUI

/// メニューバーのアイコン。どの状態でもKoe markの9本の棒を同じ形で使い、
/// 状態は右下の小さな色の点だけで足す。SF Symbolsと自作markを状態で入れ替えない。
///
/// - 音声入力の録音中は、棒が直近の入力levelで動く小さな波形になる（設定で入力level表示を有効にした時）。
/// - 録音中はrose、処理中はblue、完了はmint、要確認はgoldの点。ライフログ記録中もroseの点。
/// - 点がない時はtemplate画像にして、menu barの明暗と強調表示をsystemに任せる。
struct MenuBarLabel: View {
    var coordinator: DictationCoordinator
    var lifeLog: LifeLogCoordinator
    var settings: AppSettings

    var body: some View {
        let badge = MenuBarStatusIcon.badge(phase: coordinator.phase, lifeLog: lifeLog)
        let levels = coordinator.isRecording && settings.showLevelMeterInMenuBar
            ? Array(coordinator.levelHistory.suffix(MenuBarStatusIcon.barCount))
            : nil
        let image = MenuBarStatusIcon.image(levels: levels, badge: badge)
        Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .accessibilityLabel(Text(LocalizedStringKey(accessibilityText)))
    }

    private var accessibilityText: String {
        if coordinator.phase != .idle { return KoeTheme.label(for: coordinator.phase) }
        if lifeLog.isCapturing || lifeLog.isRecoveringCapture { return lifeLog.captureStatusText }
        return "Koe"
    }
}

@MainActor
enum MenuBarStatusIcon {
    enum Badge: Equatable {
        case recording
        case processing
        case done
        case attention
        /// ライフログの再接続中。塗らない輪で「止まってはいないが記録できていない」を示す。
        case reconnecting

        var color: NSColor {
            switch self {
            case .recording: NSColor(KoeTheme.recording)
            case .processing: NSColor(KoeTheme.accent)
            case .done: NSColor(KoeTheme.success)
            case .attention, .reconnecting: NSColor(KoeTheme.warning)
            }
        }
    }

    static let size = NSSize(width: 24, height: 20)
    /// Koe markの棒の高さ。App iconの波形と同じ山の形。
    static let markHeights: [CGFloat] = [5, 9, 13, 17, 11, 7, 14, 9, 5]
    static var barCount: Int { markHeights.count }

    /// 音声入力の状態を優先し、音声入力が待機中または録音中ならライフログ記録の点を見せる。
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

    /// `levels`を渡すと棒の高さを入力levelで置き換え、右端が最新の小さな波形にする。
    static func image(levels: [Float]? = nil, badge: Badge?) -> NSImage {
        let heights = barHeights(levels: levels)
        let image = NSImage(size: size, flipped: false) { _ in
            drawMark(heights: heights, color: badge == nil ? .black : .labelColor)
            if let badge { drawBadge(badge) }
            return true
        }
        image.isTemplate = badge == nil
        return image
    }

    /// 既存の呼び出し口。ライフログ記録中のアイコン。
    static func lifeLogRecording() -> NSImage {
        image(badge: .recording)
    }

    static func barHeights(levels: [Float]?) -> [CGFloat] {
        guard let levels, !levels.isEmpty else { return markHeights }
        let padded = Array(repeating: Float(0), count: max(0, barCount - levels.count)) + levels.suffix(barCount)
        return padded.map { level in
            // 小さい声でも動きが見えるよう緩く持ち上げ、無音でも点として残す。
            let amplitude = min(1, pow(CGFloat(max(0, level)), 0.6) * 1.2)
            return 3 + amplitude * 14
        }
    }

    private static func drawMark(heights: [CGFloat], color: NSColor) {
        let barWidth: CGFloat = 1.5
        let gap: CGFloat = 0.45
        let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
        var x = 1 + (18 - totalWidth) / 2
        color.setFill()
        for height in heights {
            let bar = NSRect(x: x, y: 1 + (18 - height) / 2, width: barWidth, height: height)
            NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
            x += barWidth + gap
        }
    }

    /// 点の周りを透明に抜き、markと点が重なっても形が潰れないようにする。
    private static func drawBadge(_ badge: Badge) {
        let rect = NSRect(x: 14, y: 0.5, width: 9, height: 9)
        if let context = NSGraphicsContext.current {
            context.saveGraphicsState()
            context.compositingOperation = .clear
            NSBezierPath(ovalIn: rect).fill()
            context.restoreGraphicsState()
        }
        let inner = rect.insetBy(dx: 1.25, dy: 1.25)
        if badge == .reconnecting {
            let ring = NSBezierPath(ovalIn: inner.insetBy(dx: 0.75, dy: 0.75))
            ring.lineWidth = 1.5
            badge.color.setStroke()
            ring.stroke()
        } else {
            badge.color.setFill()
            NSBezierPath(ovalIn: inner).fill()
        }
    }
}
