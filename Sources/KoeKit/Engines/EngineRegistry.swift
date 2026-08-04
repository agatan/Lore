import AVFoundation
import Foundation
import Observation

/// 推論エンジンの保持と準備。
///
/// Koe は **OS 内蔵のモデルだけ**を使う(設計 C-52)。選択肢は無く、
/// 聞き取りは SpeechAnalyzer、仕上げは Foundation Models で固定する。
/// 差し替えの余地を残さないぶん、ここは「準備して渡す」だけの薄い層になる。
///
/// それでも protocol 境界(`SttEngine` / `LlmEngine`)は残す。
/// パイプラインが `SpeechAnalyzer` の型に直接依存しないことで、
/// テストで差し替えられ、`DictationCoordinator` の状態機械を単体で検証できる。
@MainActor
@Observable
public final class EngineRegistry {
    @ObservationIgnored public let stt: any SttEngine
    @ObservationIgnored public let llm: any LlmEngine
    /// prepare() で判明した希望フォーマットのキャッシュ。録音開始を待たせないために持つ。
    @ObservationIgnored private var preparedFormat: AVAudioFormat?

    /// 聞き取りの利用可否。日本語の音声モデルが未取得のことがあるので UI に出す。
    public private(set) var sttAvailability: EngineAvailability = .ready
    /// 仕上げの利用可否。Apple Intelligence が無効だと使えない。
    public private(set) var llmAvailability: EngineAvailability = .ready

    public init(stt: any SttEngine = SpeechAnalyzerStt(), llm: any LlmEngine = FoundationModelsLlm()) {
        self.stt = stt
        self.llm = llm
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
