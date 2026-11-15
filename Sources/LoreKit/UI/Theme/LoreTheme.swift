import AppKit
import SwiftUI

/// 見た目の定数。色とコーナー半径をここに集約して、画面ごとにばらけないようにする。
public enum LoreTheme {
    // MARK: Color
    //
    // App iconと同じ3色で組む。墨（操作と選択）、白（面）、点のrose（いま記録している声）。
    // 他の色は状態の意味を持つときだけ使い、飾りには使わない。
    // Sidebarの選択、pop-up、switchなどsystemのcontrolはmacOSのアクセントカラーのままにする。
    // 灰色で上書きすると、使えるcontrolが無効に見える。

    /// 操作、選択、強調に使う墨色。ライトでは墨、ダークでは白に近い色へ反転する。
    public static let accent = adaptive(light: NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1), dark: NSColor(white: 0.94, alpha: 1))
    /// 墨色で塗った面に載せる文字と記号の色。
    public static let onAccent = adaptive(light: .white, dark: NSColor(red: 0.09, green: 0.09, blue: 0.12, alpha: 1))
    /// App iconの点。録音中、今日、現在時刻など「いま」を示す所だけに使う。
    public static let recording = Color(red: 0.93, green: 0.33, blue: 0.47)
    /// カレンダーの予定。会話の脇に置く参考情報なので、色を持たない灰色にする。
    public static let event = adaptive(light: NSColor(red: 0.50, green: 0.52, blue: 0.57, alpha: 1), dark: NSColor(red: 0.62, green: 0.64, blue: 0.69, alpha: 1))
    public static let success = Color(red: 0.22, green: 0.66, blue: 0.50)
    public static let warning = Color(red: 0.88, green: 0.60, blue: 0.22)
    /// 失敗と取り返しのつかない操作。録音中のroseと取り違えないよう黄みの赤にする。
    public static let danger = Color(red: 0.86, green: 0.30, blue: 0.24)

    /// 機能の色。Sidebarの記号を載せる角丸tile（`SidebarIcon`）にだけ使い、面や文字は塗らない。
    /// 白の記号が読める中間の明るさで揃え、録音のroseと状態の色（緑・黄・赤）を避ける。
    public static let lifeLogTint = Color(red: 0.40, green: 0.38, blue: 0.80)
    public static let dictationTint = Color(red: 0.20, green: 0.52, blue: 0.88)
    public static let generalTint = Color(red: 0.52, green: 0.54, blue: 0.58)
    public static let connectTint = Color(red: 0.14, green: 0.56, blue: 0.66)

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: Shape

    /// 角丸は4段だけ。キー表示やチップ、行やカード、パネルやシート、浮かぶ操作部。
    public static let smallCornerRadius: CGFloat = 6
    public static let cardCornerRadius: CGFloat = 10
    public static let panelCornerRadius: CGFloat = 14
    public static let floatingCornerRadius: CGFloat = 24

    // MARK: Type
    //
    // 字の大きさは下の段だけを使う。太さは regular / medium / semibold / bold から選ぶ。
    // 丸ゴシック（rounded）は大見出しと数値だけ、等幅は同期コードやprompt等の機械向けの文字だけに使う。

    public enum TextSize {
        /// バッジ、キー表示、補助ラベル。
        public static let micro: CGFloat = 10
        /// 時刻、補足、説明文。
        public static let caption: CGFloat = 11
        /// 行の副文、設定の小見出し。
        public static let callout: CGFloat = 12
        /// 本文。
        public static let body: CGFloat = 13
        /// タイムラインの発話など、一日を読み返す本文。
        public static let reading: CGFloat = 14
        /// カードやシートの見出し、検索欄。
        public static let headline: CGFloat = 15
        /// 一件を大きく読ませる本文（履歴の挿入文）や操作部の記号。
        public static let title: CGFloat = 17
        /// 集計の数値。
        public static let metric: CGFloat = 26
        /// 画面の主題（日付、初回画面の題）。1画面に1つだけ置く。
        public static let display: CGFloat = 28
    }

    public static let titleFont = Font.system(size: TextSize.display, weight: .bold, design: .rounded)
    public static let bodyFont = Font.system(size: TextSize.body)
    public static let captionFont = Font.system(size: TextSize.caption)
    public static let sectionFont = Font.system(size: TextSize.caption, weight: .semibold)
    /// 時刻は桁幅を揃えた本文書体で置く。等幅書体は日本語の本文と並ぶと硬く見える。
    public static let timeFont = Font.system(size: TextSize.caption).monospacedDigit()

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
            case .failed: danger
            }
        }
    }

    public static func label(for phase: SessionPhase) -> String {
        switch phase {
        case .idle: "待機中"
        case .recording: "録音中"
        case .recognizing: "認識中"
        case .formatting: "整形中"
        case .inserting: "入力中"
        case .finished(let outcome):
            switch outcome {
            case .completed: "入力しました"
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
