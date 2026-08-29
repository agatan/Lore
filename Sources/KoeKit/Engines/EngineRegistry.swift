import AVFoundation
import Foundation
import Observation

/// 推論エンジンの保持と準備。
///
/// 聞き取りは OS 内蔵の SpeechAnalyzer で固定(設計 C-52)。
/// 仕上げだけは選べる: 既定はオンデバイスの Foundation Models、
/// ユーザーが明示的に選んだときだけクラウドまたはローカルLLM(`FormattingBackend`)。
/// **選択肢はこの 1 箇所に閉じ込める**。どちらが動いているかを知りたい側は
/// `backend` と `llm` を見れば済み、分岐がパイプラインに漏れない。
///
/// protocol 境界(`SttEngine` / `LlmEngine`)を保つのはテストのためでもある。
/// パイプラインが具象エンジンに依存しないので、`DictationCoordinator` の
/// 状態機械を単体で検証できる。
@MainActor
@Observable
public final class EngineRegistry {
    @ObservationIgnored public let stt: any SttEngine
    @ObservationIgnored private let onDeviceLlm: any LlmEngine
    @ObservationIgnored public let groq: GroqLlm
    @ObservationIgnored public let openAI: RemoteLlm
    @ObservationIgnored public let anthropic: RemoteLlm
    @ObservationIgnored public let gemini: RemoteLlm
    @ObservationIgnored public let ollama: RemoteLlm
    @ObservationIgnored public let lmStudio: RemoteLlm
    /// prepare() で判明した希望フォーマットのキャッシュ。録音開始を待たせないために持つ。
    @ObservationIgnored private var preparedFormat: AVAudioFormat?

    /// 聞き取りの利用可否。日本語の音声モデルが未取得のことがあるので UI に出す。
    public private(set) var sttAvailability: EngineAvailability = .ready
    /// いま選ばれている仕上げの利用可否。
    public private(set) var llmAvailability: EngineAvailability = .ready
    /// 仕上げをどこで動かすか。設定から `apply(...)` で流し込む。
    public private(set) var backend: FormattingBackend = .onDevice

    public init(
        stt: any SttEngine = SpeechAnalyzerStt(),
        llm: any LlmEngine = FoundationModelsLlm(),
        groq: GroqLlm = GroqLlm(),
        openAI: RemoteLlm = RemoteLlm(identifier: .openAI, providerName: "OpenAI", api: .openAI, model: "gpt-5.4-mini", apiKeySource: { try SecretStore.read(.openAIApiKey) }),
        anthropic: RemoteLlm = RemoteLlm(identifier: .anthropic, providerName: "Claude", api: .anthropic, model: "claude-sonnet-5", apiKeySource: { try SecretStore.read(.anthropicApiKey) }),
        gemini: RemoteLlm = RemoteLlm(identifier: .gemini, providerName: "Gemini", api: .gemini, model: "gemini-3.6-flash", apiKeySource: { try SecretStore.read(.geminiApiKey) }),
        ollama: RemoteLlm = RemoteLlm(identifier: .ollama, providerName: "Ollama", api: .openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!, authorizationValue: nil), model: "gpt-oss:20b"),
        lmStudio: RemoteLlm = RemoteLlm(identifier: .lmStudio, providerName: "LM Studio", api: .openAICompatible(baseURL: URL(string: "http://localhost:1234/v1")!, authorizationValue: nil), model: "openai/gpt-oss-20b")
    ) {
        self.stt = stt
        self.onDeviceLlm = llm
        self.groq = groq
        self.openAI = openAI
        self.anthropic = anthropic
        self.gemini = gemini
        self.ollama = ollama
        self.lmStudio = lmStudio
    }

    /// いま整形に使うエンジン。セッション開始時にここから 1 つ取り、
    /// 途中で設定が変わってもそのセッションは最後まで同じエンジンで通す。
    public var llm: any LlmEngine {
        switch backend {
        case .onDevice: onDeviceLlm
        case .openAI: openAI
        case .anthropic: anthropic
        case .gemini: gemini
        case .groq: groq
        case .ollama: ollama
        case .lmStudio: lmStudio
        }
    }

    /// 履歴を読む語彙分析は、外部送信の選択とは独立して常にオンデバイスで行う。
    /// `llm` を使うとクラウド選択時に過去の履歴まで送信され、UI の「文章処理だけ」という
    /// 説明とプライバシー境界が崩れる。
    var analysisLlm: any LlmEngine { onDeviceLlm }
    public func apply(backend: FormattingBackend, model: String) {
        self.backend = backend
        switch backend {
        case .onDevice: break
        case .openAI: openAI.apply(model: model)
        case .anthropic: anthropic.apply(model: model)
        case .gemini: gemini.apply(model: model)
        case .groq: groq.apply(model: model)
        case .ollama: ollama.apply(model: model)
        case .lmStudio: lmStudio.apply(model: model)
        }
    }

    public func availableModels(for backend: FormattingBackend) async throws -> [String] {
        switch backend {
        case .onDevice: []
        case .openAI: try await openAI.availableModels()
        case .anthropic: try await anthropic.availableModels()
        case .gemini: try await gemini.availableModels()
        case .groq: try await groq.availableModels()
        case .ollama: try await ollama.availableModels()
        case .lmStudio: try await lmStudio.availableModels()
        }
    }

    // MARK: 準備

    /// 明示的に必要な場面だけで行う事前準備。アプリ起動時には呼ばない。
    /// macOS 26では音声入力前のSpeechAnalyzer初期化がOS内部でtrapする場合がある。
    public func prewarm(hints: SttHints) async {
        if let format = try? await stt.prepare(hints: hints) {
            preparedFormat = format
        }
    }

    /// 録音開始時に使うフォーマット。キャッシュが無い初回だけ prepare を待つ。
    public func captureFormat(hints: SttHints) async throws -> AVAudioFormat {
        if let cached = preparedFormat { return cached }
        let format = try await stt.prepare(hints: hints) ?? AudioFormats.canonical
        preparedFormat = format
        return format
    }

    public func refreshAvailability(languagePreference: LanguagePreference = .auto, checkLlm: Bool = true) async {
        sttAvailability = await stt.availability(languagePreference: languagePreference)
        if checkLlm { llmAvailability = await llm.availability() }
    }

    /// 日本語の音声モデルを取得する。OS が管理する資産だが、取得は明示操作で行う。
    public func installSpeechAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await stt.install(progress: progress)
        await refreshAvailability()
    }

    /// アイドル時のモデル解放(NFR-5)。
    public func unloadAll() async {
        preparedFormat = nil
        await stt.unload()
        await llm.unload()
    }
}
