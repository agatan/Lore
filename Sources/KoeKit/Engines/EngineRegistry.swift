import AVFoundation
import Foundation
import Observation

/// 推論エンジンの保持と準備。
///
/// 聞き取りは OS 内蔵の SpeechAnalyzer で固定(設計 C-52)。
/// 仕上げだけは選べる: 既定はオンデバイスの Foundation Models、
/// ユーザーが明示的に選んだときだけ Groq API(`FormattingBackend`)。
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
        groq: GroqLlm = GroqLlm()
    ) {
        self.stt = stt
        self.onDeviceLlm = llm
        self.groq = groq
    }

    /// いま整形に使うエンジン。セッション開始時にここから 1 つ取り、
    /// 途中で設定が変わってもそのセッションは最後まで同じエンジンで通す。
    public var llm: any LlmEngine {
        switch backend {
        case .onDevice: onDeviceLlm
        case .groq: groq
        }
    }

    public func apply(backend: FormattingBackend, groqModel: String) {
        self.backend = backend
        groq.apply(model: groqModel)
    }

    // MARK: 準備

    /// 録音開始を待たせないための事前準備。起動時・セッション終了後に呼ぶ。
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

    public func refreshAvailability(languagePreference: LanguagePreference = .auto) async {
        sttAvailability = await stt.availability(languagePreference: languagePreference)
        llmAvailability = await llm.availability()
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
