import Foundation

/// 文章の仕上げをどこで動かすか。
///
/// Lore の既定は「この Mac の中だけ」。クラウドを選んだときに限り、
/// **文字起こしと指示文(共有ルール・モードの指示・語彙)が選択した外部APIに送られる**。
/// 両者の本質的な差はそこだけなので、見た目の名前とは別に
/// `sendsTranscriptOffDevice` として型に持たせ、HUD・プライバシー画面・履歴の説明が
/// この 1 箇所を唯一の出どころにする。
public enum FormattingBackend: String, Codable, Sendable, CaseIterable, Identifiable {
    /// Apple Foundation Models(オンデバイス)。
    case onDevice
    /// OpenAI Responses API。
    case openAI
    /// Anthropic Messages API。
    case anthropic
    /// Google Gemini generateContent API。
    case gemini
    /// Groq の Chat Completions API。
    case groq
    /// この Mac で動く Ollama の OpenAI 互換 API。
    case ollama
    /// この Mac で動く LM Studio の OpenAI 互換 API。
    case lmStudio

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .onDevice: "Apple Foundation Models"
        case .openAI: "OpenAI"
        case .anthropic: "Claude"
        case .gemini: "Gemini"
        case .groq: "Groq"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        }
    }

    public var location: Location {
        switch self {
        case .onDevice, .ollama, .lmStudio: .onMac
        case .openAI, .anthropic, .gemini, .groq: .cloud
        }
    }

    public enum Location: String, Sendable, CaseIterable {
        case onMac
        case cloud
    }

    /// The model a provider starts with. Formatting and Life Log AI keep their own choice.
    public var defaultModel: String {
        switch self {
        case .onDevice: "Apple Foundation Models"
        case .openAI: "gpt-5.4-mini"
        case .anthropic: "claude-sonnet-5"
        case .gemini: "gemini-3.6-flash"
        case .groq: GroqLlm.defaultModel
        case .ollama: "gpt-oss:20b"
        case .lmStudio: "openai/gpt-oss-20b"
        }
    }

    /// 発話した内容がこの Mac の外に出るか。
    public var sendsTranscriptOffDevice: Bool {
        switch self {
        case .onDevice, .ollama, .lmStudio: false
        case .openAI, .anthropic, .gemini, .groq: true
        }
    }
}
