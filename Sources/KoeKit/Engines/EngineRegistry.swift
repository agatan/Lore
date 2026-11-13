import AVFoundation
import Foundation
import Observation

/// 推論エンジンの保持と準備。
///
/// 聞き取りは音声入力とライフログで個別に、OS内蔵SpeechAnalyzerか明示選択したwhisper.cppを使う。
/// whisper.cppは用途ごとに推論stateを分け、GGML重みだけを共有する。
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
    /// OS内蔵SpeechAnalyzer。whisper.cppを選んだ用途では使わない。
    @ObservationIgnored public let stt: any SttEngine
    @ObservationIgnored private var dictationWhisper: WhisperCppStt
    @ObservationIgnored private var lifeLogWhisper: WhisperCppStt
    @ObservationIgnored public private(set) var dictationSttBackend: SttBackend = .speechAnalyzer
    @ObservationIgnored public private(set) var lifeLogSttBackend: SttBackend = .speechAnalyzer
    @ObservationIgnored private let onDeviceLlm: any LlmEngine
    @ObservationIgnored public let groq: GroqLlm
    @ObservationIgnored public let openAI: RemoteLlm
    @ObservationIgnored public let anthropic: RemoteLlm
    @ObservationIgnored public let gemini: RemoteLlm
    @ObservationIgnored public let ollama: RemoteLlm
    @ObservationIgnored public let lmStudio: RemoteLlm
    @ObservationIgnored private let lifeLogGroq: GroqLlm
    @ObservationIgnored private let lifeLogOpenAI: RemoteLlm
    @ObservationIgnored private let lifeLogAnthropic: RemoteLlm
    @ObservationIgnored private let lifeLogGemini: RemoteLlm
    @ObservationIgnored private let lifeLogOllama: RemoteLlm
    @ObservationIgnored private let lifeLogLmStudio: RemoteLlm
    /// prepare() で判明した希望フォーマットのキャッシュ。録音開始を待たせないために持つ。
    @ObservationIgnored private var preparedFormat: AVAudioFormat?

    /// SpeechAnalyzerの利用可否。日本語の音声モデルが未取得のことがあるので UI に出す。
    public private(set) var sttAvailability: EngineAvailability = .ready
    /// 共有whisper.cpp modelの取得状態。
    public private(set) var whisperAvailability: EngineAvailability = .ready
    /// いま選ばれている仕上げの利用可否。
    public private(set) var llmAvailability: EngineAvailability = .ready
    public private(set) var lifeLogLlmAvailability: EngineAvailability = .ready
    /// 仕上げをどこで動かすか。設定から `apply(...)` で流し込む。
    public private(set) var backend: FormattingBackend = .onDevice
    public private(set) var lifeLogBackend: FormattingBackend = .onDevice

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
        dictationWhisper = WhisperCppStt(model: .largeV3Turbo)
        lifeLogWhisper = WhisperCppStt(model: .largeV3Turbo)
        self.onDeviceLlm = llm
        self.groq = groq
        self.openAI = openAI
        self.anthropic = anthropic
        self.gemini = gemini
        self.ollama = ollama
        self.lmStudio = lmStudio
        lifeLogGroq = GroqLlm(apiKeySource: { try SecretStore.read(.lifeLogGroqApiKey) })
        lifeLogOpenAI = RemoteLlm(identifier: .openAI, providerName: "OpenAI", api: .openAI, model: "gpt-5.4-mini", apiKeySource: { try SecretStore.read(.lifeLogOpenAIApiKey) })
        lifeLogAnthropic = RemoteLlm(identifier: .anthropic, providerName: "Claude", api: .anthropic, model: "claude-sonnet-5", apiKeySource: { try SecretStore.read(.lifeLogAnthropicApiKey) })
        lifeLogGemini = RemoteLlm(identifier: .gemini, providerName: "Gemini", api: .gemini, model: "gemini-3.6-flash", apiKeySource: { try SecretStore.read(.lifeLogGeminiApiKey) })
        lifeLogOllama = RemoteLlm(identifier: .ollama, providerName: "Ollama", api: .openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!, authorizationValue: nil), model: "gpt-oss:20b")
        lifeLogLmStudio = RemoteLlm(identifier: .lmStudio, providerName: "LM Studio", api: .openAICompatible(baseURL: URL(string: "http://localhost:1234/v1")!, authorizationValue: nil), model: "openai/gpt-oss-20b")
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

    public var lifeLogLlm: any LlmEngine {
        switch lifeLogBackend {
        case .onDevice: onDeviceLlm
        case .openAI: lifeLogOpenAI
        case .anthropic: lifeLogAnthropic
        case .gemini: lifeLogGemini
        case .groq: lifeLogGroq
        case .ollama: lifeLogOllama
        case .lmStudio: lifeLogLmStudio
        }
    }

    /// 音声入力とボイスメモの聞き取り。セッション開始時に取り、途中で設定が変わっても使い続ける。
    public var dictationStt: any SttEngine {
        dictationSttBackend == .whisperCpp ? dictationWhisper : stt
    }

    public var lifeLogStt: any SttEngine {
        lifeLogSttBackend == .whisperCpp ? lifeLogWhisper : stt
    }

    public var lifeLogSttAvailability: EngineAvailability {
        lifeLogSttBackend == .whisperCpp ? whisperAvailability : sttAvailability
    }

    public var dictationSttAvailability: EngineAvailability {
        dictationSttBackend == .whisperCpp ? whisperAvailability : sttAvailability
    }

    public var usesWhisper: Bool {
        dictationSttBackend == .whisperCpp || lifeLogSttBackend == .whisperCpp
    }

    public func applyStt(dictation: SttBackend, lifeLog: SttBackend, model: WhisperModel) {
        dictationSttBackend = dictation
        lifeLogSttBackend = lifeLog
        // 実行中jobは旧engineを保持して最後まで使う。新しいstateは次のjobで作る。
        if dictationWhisper.model != model { dictationWhisper = WhisperCppStt(model: model) }
        if lifeLogWhisper.model != model { lifeLogWhisper = WhisperCppStt(model: model) }
    }

    /// API応答に含まれる実測usageへ、呼び出し用途を付けて上位へ渡す。
    public func setUsageSink(_ sink: @escaping @Sendable (LlmUsageEvent) -> Void) {
        let dictation: LlmUsageSink = { provider, model, usage in
            sink(LlmUsageEvent(purpose: .dictation, provider: provider, model: model, usage: usage))
        }
        let lifeLog: LlmUsageSink = { provider, model, usage in
            sink(LlmUsageEvent(purpose: .lifeLog, provider: provider, model: model, usage: usage))
        }
        groq.setUsageSink(dictation)
        openAI.setUsageSink(dictation)
        anthropic.setUsageSink(dictation)
        gemini.setUsageSink(dictation)
        lifeLogGroq.setUsageSink(lifeLog)
        lifeLogOpenAI.setUsageSink(lifeLog)
        lifeLogAnthropic.setUsageSink(lifeLog)
        lifeLogGemini.setUsageSink(lifeLog)
    }

    /// 履歴を読む語彙分析は、外部送信の選択とは独立して常にオンデバイスで行う。
    /// `llm` を使うとクラウド選択時に過去の履歴まで送信され、UI の「文章処理だけ」という
    /// 説明とプライバシー境界が崩れる。
    var analysisLlm: any LlmEngine { onDeviceLlm }
    public func apply(backend: FormattingBackend, model: String) {
        apply(backend: backend, model: model, purpose: .dictation)
    }

    public func apply(backend: FormattingBackend, model: String, purpose: LlmPurpose) {
        if purpose == .dictation { self.backend = backend } else { lifeLogBackend = backend }
        switch backend {
        case .onDevice: break
        case .openAI: (purpose == .dictation ? openAI : lifeLogOpenAI).apply(model: model)
        case .anthropic: (purpose == .dictation ? anthropic : lifeLogAnthropic).apply(model: model)
        case .gemini: (purpose == .dictation ? gemini : lifeLogGemini).apply(model: model)
        case .groq: (purpose == .dictation ? groq : lifeLogGroq).apply(model: model)
        case .ollama: (purpose == .dictation ? ollama : lifeLogOllama).apply(model: model)
        case .lmStudio: (purpose == .dictation ? lmStudio : lifeLogLmStudio).apply(model: model)
        }
    }

    public func availableModels(for backend: FormattingBackend) async throws -> [String] {
        try await availableModels(for: backend, purpose: .dictation)
    }

    public func availableModels(for backend: FormattingBackend, purpose: LlmPurpose) async throws -> [String] {
        switch backend {
        case .onDevice: []
        case .openAI: try await (purpose == .dictation ? openAI : lifeLogOpenAI).availableModels()
        case .anthropic: try await (purpose == .dictation ? anthropic : lifeLogAnthropic).availableModels()
        case .gemini: try await (purpose == .dictation ? gemini : lifeLogGemini).availableModels()
        case .groq: try await (purpose == .dictation ? groq : lifeLogGroq).availableModels()
        case .ollama: try await (purpose == .dictation ? ollama : lifeLogOllama).availableModels()
        case .lmStudio: try await (purpose == .dictation ? lmStudio : lifeLogLmStudio).availableModels()
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

    /// 音声入力の録音開始時に使うフォーマット。SpeechAnalyzerはキャッシュが無い初回だけ prepare を待つ。
    /// whisper.cppは録音を待たせず、録音と並行して推論stateを用意する。
    public func captureFormat(hints: SttHints) async throws -> AVAudioFormat {
        if dictationSttBackend == .whisperCpp {
            let whisper = dictationWhisper
            let format = try await whisper.prepare(hints: hints) ?? AudioFormats.canonical
            Task.detached(priority: .userInitiated) {
                do {
                    try await whisper.warmUp()
                } catch {
                    // 認識時に同じ理由で失敗し、利用者へはそのsessionの失敗として表示する。
                    KoeLog.engine.error("whisper.cppの事前準備に失敗: \(error.localizedDescription, privacy: .public)")
                }
            }
            return format
        }
        if let cached = preparedFormat { return cached }
        let format = try await stt.prepare(hints: hints) ?? AudioFormats.canonical
        preparedFormat = format
        return format
    }

    public func refreshAvailability(languagePreference: LanguagePreference = .auto, checkLlm: Bool = true) async {
        await refreshSttAvailability(languagePreference: languagePreference)
        if checkLlm {
            await refreshLlmAvailability(for: .dictation)
            await refreshLlmAvailability(for: .lifeLog)
        }
    }

    public func refreshSttAvailability(languagePreference: LanguagePreference = .auto) async {
        // Speech frameworkの在庫APIはasyncでも呼び出しthreadを長時間占有することがある。
        // EngineRegistryはMainActorなので、ここで直接待つとwindowとglobal hotkeyまで止まる。
        let stt = self.stt
        sttAvailability = await Task.detached(priority: .utility) {
            await stt.availability(languagePreference: languagePreference)
        }.value
        whisperAvailability = await dictationWhisper.availability(languagePreference: languagePreference)
    }

    public func refreshLlmAvailability(for purpose: LlmPurpose) async {
        if purpose == .dictation {
            llmAvailability = await llm.availability()
        } else {
            lifeLogLlmAvailability = await lifeLogLlm.availability()
        }
    }

    /// 日本語の音声モデルを取得する。OS が管理する資産だが、取得は明示操作で行う。
    public func installSpeechAssets(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await stt.install(progress: progress)
        await refreshSttAvailability()
    }

    /// modelは音声入力とライフログで共有するため、どちらの用途から取得しても同じfileになる。
    public func installWhisperModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await dictationWhisper.install(progress: progress)
        whisperAvailability = await dictationWhisper.availability(languagePreference: .auto)
    }

    public func deleteWhisperModel() async throws {
        await lifeLogWhisper.unload()
        try await dictationWhisper.deleteInstalledModel()
        whisperAvailability = await dictationWhisper.availability(languagePreference: .auto)
    }

    /// 音声入力のアイドル時のモデル解放(NFR-5)。ライフログの推論stateは記録側が所有するので残す。
    public func unloadDictationEngines() async {
        preparedFormat = nil
        await stt.unload()
        await dictationWhisper.unload()
        await llm.unload()
        if backend != .onDevice || lifeLogBackend != .onDevice {
            await lifeLogLlm.unload()
        }
    }

    /// ライフログ記録の停止時に、ライフログ用whisper.cpp stateを解放する。
    /// 実行中jobは自身のstateを保持して完了し、未処理chunkの再処理は次のjobで作り直す。
    public func unloadLifeLogStt() async {
        await lifeLogWhisper.unload()
    }
}
