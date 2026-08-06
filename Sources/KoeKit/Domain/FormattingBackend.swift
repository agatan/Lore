import Foundation

/// 文章の仕上げをどこで動かすか。
///
/// Koe の既定は「この Mac の中だけ」。`groq` を選んだときに限り、
/// **文字起こしと指示文(共有ルール・モードの指示・語彙)が外部 API に送られる**。
/// 両者の本質的な差はそこだけなので、見た目の名前とは別に
/// `sendsTranscriptOffDevice` として型に持たせ、HUD・プライバシー画面・履歴の説明が
/// この 1 箇所を唯一の出どころにする。
public enum FormattingBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple Foundation Models(オンデバイス)。
    case onDevice
    /// Groq の Chat Completions API。
    case groq

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: "この Mac の中で仕上げる"
        case .groq: "Groq API で仕上げる"
        }
    }

    /// 発話した内容がこの Mac の外に出るか。
    public var sendsTranscriptOffDevice: Bool {
        switch self {
        case .onDevice: false
        case .groq: true
        }
    }
}
