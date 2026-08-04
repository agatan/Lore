import AVFoundation
import Foundation
import Observation
import Synchronization

/// エンジンへ渡す「いま選択されているモデル」。
///
/// エンジンは Sendable な文脈で動くので、MainActor の設定オブジェクトを直接見せられない。
/// 設定変更のたびにここへ書き写す。
public final class ModelSelection: Sendable {
    private let storage: Mutex<String>

    public init(_ initial: String) {
        storage = Mutex(initial)
    }

    public var current: String {
        storage.withLock { $0 }
    }

    public func set(_ value: String) {
        storage.withLock { $0 = value }
    }
}

/// 利用できるエンジンの一覧と、選択されたエンジンの解決。
///
/// エンジンの追加はここへの登録だけで済む(パイプライン本体は触らない)。
@MainActor
@Observable
public final class EngineRegistry {
    @ObservationIgnored private var stt: [EngineIdentifier: any SttEngine] = [:]
    @ObservationIgnored private var llm: [EngineIdentifier: any LlmEngine] = [:]
    /// prepare() で判明した希望フォーマットのキャッシュ。録音開始を待たせないために持つ。
    @ObservationIgnored private var preparedFormats: [EngineIdentifier: AVAudioFormat] = [:]

    public private(set) var sttAvailability: [EngineIdentifier: EngineAvailability] = [:]
    public private(set) var llmAvailability: [EngineIdentifier: EngineAvailability] = [:]

    @ObservationIgnored public let whisperSelection = ModelSelection(WhisperModelCatalog.defaultModelID)
    @ObservationIgnored public let mlxSelection = ModelSelection(MlxModelCatalog.defaultModelID)

    public init() {
        register(stt: SpeechAnalyzerStt())
        register(llm: FoundationModelsLlm())

        let whisperSelection = whisperSelection
        register(stt: WhisperKitStt(variant: { whisperSelection.current }))
        let mlxSelection = mlxSelection
        register(llm: MlxLlm(modelID: { mlxSelection.current }))
    }

    /// 設定で選ばれたモデルをエンジン側へ反映する。
    public func updateModelSelection(whisper: String, mlx: String) {
        whisperSelection.set(whisper)
        mlxSelection.set(mlx)
        preparedFormats.removeAll()
    }

    public func register(stt engine: any SttEngine) {
        self.stt[engine.identifier] = engine
    }

    public func register(llm engine: any LlmEngine) {
        self.llm[engine.identifier] = engine
    }

    // MARK: 選択肢

    public var transcriptionChoices: [ModelChoice] {
        TranscriptionCatalog.all.filter { stt[$0.engine] != nil }
    }

    public var formattingChoices: [ModelChoice] {
        FormattingCatalog.all.filter { llm[$0.engine] != nil }
    }

    /// 選択肢ごとの利用可否。ダウンロード済みかはファイルの有無で判断する。
    public func availability(for choice: ModelChoice) -> EngineAvailability {
        switch choice.engine {
        case .speechAnalyzer:
            return sttAvailability[.speechAnalyzer] ?? .ready
        case .whisperKit:
            guard let modelID = choice.modelID else { return .unavailable("モデルが指定されていません") }
            return ModelStore.isDownloaded(whisperVariant: modelID)
                ? .ready
                : .needsDownload(choice.downloadSizeText.map { "\($0) のダウンロードが必要です" } ?? "ダウンロードが必要です")
        case .foundationModels:
            return llmAvailability[.foundationModels] ?? .ready
        case .mlx:
            guard MlxLlm.isMetalLibraryBundled else {
                return .unavailable("この Koe では使えません(Metal シェーダ無しでビルドされています)")
            }
            guard let modelID = choice.modelID else { return .unavailable("モデルが指定されていません") }
            return ModelStore.isDownloaded(mlxModelID: modelID)
                ? .ready
                : .needsDownload(choice.downloadSizeText.map { "\($0) のダウンロードが必要です" } ?? "ダウンロードが必要です")
        default:
            return .unavailable("未対応のエンジンです")
        }
    }

    /// 選択されたエンジン。未登録・未実装なら既定に落とす(設定だけ先に切り替わっていても壊れない)。
    public func sttEngine(_ id: EngineIdentifier) -> any SttEngine {
        stt[id] ?? stt[.speechAnalyzer] ?? SpeechAnalyzerStt()
    }

    public func llmEngine(_ id: EngineIdentifier) -> (any LlmEngine)? {
        llm[id] ?? llm[.foundationModels]
    }

    public func isRegistered(stt id: EngineIdentifier) -> Bool { stt[id] != nil }
    public func isRegistered(llm id: EngineIdentifier) -> Bool { llm[id] != nil }

    // MARK: 準備

    /// 録音開始を待たせないための事前準備。起動時・設定変更時・セッション終了後に呼ぶ。
    public func prewarm(sttID: EngineIdentifier, hints: SttHints) async {
        let engine = sttEngine(sttID)
        if let format = try? await engine.prepare(hints: hints) {
            preparedFormats[engine.identifier] = format
        }
    }

    /// 録音開始時に使うフォーマット。キャッシュが無い初回だけ prepare を待つ。
    public func captureFormat(for id: EngineIdentifier, hints: SttHints) async throws -> AVAudioFormat {
        if let cached = preparedFormats[id] { return cached }
        let engine = sttEngine(id)
        let format = try await engine.prepare(hints: hints) ?? AudioFormats.canonical
        preparedFormats[id] = format
        return format
    }

    public func refreshAvailability(languagePreference: LanguagePreference = .auto) async {
        for (id, engine) in stt {
            sttAvailability[id] = await engine.availability(languagePreference: languagePreference)
        }
        for (id, engine) in llm {
            llmAvailability[id] = await engine.availability()
        }
    }

    /// アイドル時のモデル解放(NFR-5)。
    public func unloadAll() async {
        preparedFormats.removeAll()
        for engine in stt.values { await engine.unload() }
        for engine in llm.values { await engine.unload() }
    }
}
