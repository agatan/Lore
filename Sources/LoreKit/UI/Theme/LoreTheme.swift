import SwiftUI

/// 見た目の定数。色とコーナー半径をここに集約して、画面ごとにばらけないようにする。
public enum LoreTheme {
    /// App iconのblue/cyanを全画面の固定brand colorとして使う。
    public static let accent = Color(red: 0.30, green: 0.53, blue: 0.92)
    public static let accentSecondary = Color(red: 0.25, green: 0.70, blue: 0.87)
    public static let recording = Color(red: 0.89, green: 0.33, blue: 0.44)
    public static let recordingSecondary = Color(red: 0.94, green: 0.46, blue: 0.52)
    public static let success = Color(red: 0.22, green: 0.68, blue: 0.55)
    public static let warning = Color(red: 0.90, green: 0.62, blue: 0.25)
    /// 利用者が自分で書き残したmemoの印。警告と取り違えないよう、goldより赤みを足す。
    public static let memo = Color(red: 0.93, green: 0.52, blue: 0.24)

    public static let voiceGradient = LinearGradient(
        colors: [accent, accentSecondary],
        startPoint: .leading,
        endPoint: .trailing
    )

    public static let recordingGradient = LinearGradient(
        colors: [recording, recordingSecondary],
        startPoint: .leading,
        endPoint: .trailing
    )

    public static let hudCornerRadius: CGFloat = 26
    public static let panelCornerRadius: CGFloat = 12
    public static let cardCornerRadius: CGFloat = 8

    /// 日付など、画面の主題を示す大見出し。1画面に1つだけ置く。
    public static let titleFont = Font.system(size: 28, weight: .bold, design: .rounded)
    /// 本文、補足、見出しの3段だけを使い、画面ごとに字の大きさを増やさない。
    public static let bodyFont = Font.system(size: 13)
    public static let captionFont = Font.system(size: 11)
    public static let sectionFont = Font.system(size: 11, weight: .semibold)
    /// 時刻は桁幅を揃えた本文書体で置く。等幅書体は日本語の本文と並ぶと硬く見える。
    public static let timeFont = Font.system(size: 11).monospacedDigit()

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
