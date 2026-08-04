import SwiftUI

/// 見た目の定数。色とコーナー半径をここに集約して、画面ごとにばらけないようにする。
public enum KoeTheme {
    /// 声・波形のアクセント。紫寄りのインディゴから水色へ。
    public static let accent = Color(red: 0.42, green: 0.37, blue: 0.97)
    public static let accentSecondary = Color(red: 0.25, green: 0.78, blue: 0.87)
    public static let recording = Color(red: 0.96, green: 0.31, blue: 0.42)
    public static let success = Color(red: 0.20, green: 0.78, blue: 0.55)
    public static let warning = Color(red: 0.98, green: 0.68, blue: 0.22)

    public static let voiceGradient = LinearGradient(
        colors: [accent, accentSecondary],
        startPoint: .leading,
        endPoint: .trailing
    )

    public static let recordingGradient = LinearGradient(
        colors: [recording, Color(red: 0.99, green: 0.52, blue: 0.35)],
        startPoint: .leading,
        endPoint: .trailing
    )

    public static let hudCornerRadius: CGFloat = 26
    public static let panelCornerRadius: CGFloat = 16
    public static let cardCornerRadius: CGFloat = 10

    /// フェーズごとの主色。HUD とメニューバーで同じ意味を持たせる。
    public static func tint(for phase: SessionPhase) -> Color {
        switch phase {
        case .idle: .secondary
        case .recording: recording
        case .recognizing, .formatting, .inserting: accent
        case .finished(let outcome):
            switch outcome {
            case .completed: success
            case .cancelled: .secondary
            case .formattingSkipped, .clipboardOnly: warning
            case .failed: recording
            }
        }
    }

    public static func label(for phase: SessionPhase) -> String {
        switch phase {
        case .idle: "待機中"
        case .recording: "録音中"
        case .recognizing: "認識中"
        case .formatting: "整形中"
        case .inserting: "挿入中"
        case .finished(let outcome):
            switch outcome {
            case .completed: "挿入しました"
            case .cancelled: "キャンセルしました"
            case .formattingSkipped: "整形をスキップ"
            case .clipboardOnly: "クリップボードにコピー"
            case .failed: "失敗しました"
            }
        }
    }

    public static func symbol(for phase: SessionPhase) -> String {
        switch phase {
        case .idle: "mic"
        case .recording: "mic.fill"
        case .recognizing: "waveform"
        case .formatting: "wand.and.sparkles"
        case .inserting: "text.cursor"
        case .finished(let outcome):
            switch outcome {
            case .completed: "checkmark.circle.fill"
            case .cancelled: "xmark.circle.fill"
            case .formattingSkipped: "exclamationmark.triangle.fill"
            case .clipboardOnly: "doc.on.clipboard.fill"
            case .failed: "exclamationmark.octagon.fill"
            }
        }
    }
}

extension Duration {
    /// 0:07 形式。
    var clockText: String {
        let total = components.seconds
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var millisecondsText: String {
        let ms = components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000
        return "\(ms) ms"
    }
}
