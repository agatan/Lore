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
    /// prepare() で判明した希望フォーマットのキャッシュ。録音開始を待たせないために持つ。
    @ObservationIgnored private var preparedFormat: AVAudioFormat?

    /// SpeechAnalyzerの利用可否。日本語の音声モデルが未取得のことがあるので UI に出す。
    public private(set) var sttAvailability: EngineAvailability = .ready
    /// 共有whisper.cpp modelの取得状態。
    public private(set) var whisperAvailability: EngineAvailability = .ready
    /// いま選ばれている仕上げの利用可否。
    public private(set) var llmAvailability: EngineAvailability = .ready
    /// 仕上げをどこで動かすか。設定から `apply(...)` で流し込む。
    public private(set) var backend: FormattingBackend = .onDevice

    public init(
        stt: any SttEngine = SpeechAnalyzerStt(),
        llm: any LlmEngine = FoundationModelsLlm(),
        groq: GroqLlm = GroqLlm(),
        openAI: RemoteLlm = EngineRegistry.makeRemote(.openAI),
        anthropic: RemoteLlm = EngineRegistry.makeRemote(.anthropic),
        gemini: RemoteLlm = EngineRegistry.makeRemote(.gemini),
        ollama: RemoteLlm = EngineRegistry.makeRemote(.ollama),
        lmStudio: RemoteLlm = EngineRegistry.makeRemote(.lmStudio)
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
    }

    /// The single description of each remote provider: endpoint, display name, and Keychain key.
    /// Ollama and LM Studio are fixed to localhost.
    public nonisolated static func makeRemote(
        _ backend: FormattingBackend,
        model: String? = nil,
        session: URLSession = .shared
    ) -> RemoteLlm {
        let model = model ?? backend.defaultModel
        return switch backend {
        case .openAI: RemoteLlm(identifier: .openAI, providerName: "OpenAI", api: .openAI, model: model, session: session, apiKeySource: { try SecretStore.read(.openAIApiKey) })
        case .anthropic: RemoteLlm(identifier: .anthropic, providerName: "Claude", api: .anthropic, model: model, session: session, apiKeySource: { try SecretStore.read(.anthropicApiKey) })
        case .gemini: RemoteLlm(identifier: .gemini, providerName: "Gemini", api: .gemini, model: model, session: session, apiKeySource: { try SecretStore.read(.geminiApiKey) })
        case .lmStudio: RemoteLlm(identifier: .lmStudio, providerName: "LM Studio", api: .openAICompatible(baseURL: URL(string: "http://localhost:1234/v1")!, authorizationValue: nil), model: model, session: session)
        case .onDevice, .groq: preconditionFailure("\(backend) has its own engine type")
        case .ollama: RemoteLlm(identifier: .ollama, providerName: "Ollama", api: .openAICompatible(baseURL: URL(string: "http://localhost:11434/v1")!, authorizationValue: nil), model: model, session: session)
        }
    }

    /// A fresh engine for one Life Log AI request, so its model never changes the formatting model.
    public func lifeLogAIEngine(backend: FormattingBackend, model: String, session: URLSession = .shared) -> any LlmEngine {
        switch backend {
        case .onDevice: onDeviceLlm
        case .groq: GroqLlm(model: model, session: session)
        case .openAI, .anthropic, .gemini, .ollama, .lmStudio: Self.makeRemote(backend, model: model, session: session)
        }
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

    /// 履歴を読む語彙分析は、外部送信の選択とは独立して常にオンデバイスで行う。
    /// `llm` を使うとクラウド選択時に過去の履歴まで送信され、UI の「文章処理だけ」という
    /// 説明とプライバシー境界が崩れる。
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
                    LoreLog.engine.error("whisper.cppの事前準備に失敗: \(error.localizedDescription, privacy: .public)")
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
        if checkLlm { await refreshLlmAvailability() }
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

    public func refreshLlmAvailability() async {
        llmAvailability = await llm.availability()
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
    }

    /// ライフログ記録の停止時に、ライフログ用whisper.cpp stateを解放する。
    /// 実行中jobは自身のstateを保持して完了し、未処理chunkの再処理は次のjobで作り直す。
    public func unloadLifeLogStt() async {
        await lifeLogWhisper.unload()
    }
}
