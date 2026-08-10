import AVFAudio
import Foundation

/// 録音ストリームの 1 単位。
///
/// `AVAudioPCMBuffer` は Sendable ではないが、タップ側で生成したバッファを
/// 所有権ごと 1 回だけ受け渡す使い方に限定するため `@unchecked Sendable` とする。
public struct AudioChunk: @unchecked Sendable {
    public let buffer: AVAudioPCMBuffer
    /// 録音開始からの累積フレーム位置。時刻付けが必要なエンジン向け。
    public let frameOffset: AVAudioFramePosition

    public init(buffer: AVAudioPCMBuffer, frameOffset: AVAudioFramePosition) {
        self.buffer = buffer
        self.frameOffset = frameOffset
    }
}

public enum AudioFormats {
    /// エンジンが希望を出さなかった場合の既定フォーマット。
    public static var canonical: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }
}

/// エンジンの使用可否。UI にそのまま出せる文言を持たせる。
public enum EngineAvailability: Sendable, Equatable {
    case ready
    /// モデルや音声アセットの取得が必要。
    case needsDownload(String)
    case unavailable(String)

    public var isReady: Bool { self == .ready }

    public var message: String? {
        switch self {
        case .ready: nil
        case .needsDownload(let text), .unavailable(let text): text
        }
    }
}

// MARK: - STT

public struct SttHints: Sendable {
    /// 認識のバイアスに使う語彙(SpeechAnalyzer の contextualStrings 等)。
    public var contextualStrings: [String]
    /// Whisper の initial prompt など、文字列プロンプトを取るエンジン向け。
    public var vocabularyPrompt: String?
    public var languagePreference: LanguagePreference

    public init(
        contextualStrings: [String] = [],
        vocabularyPrompt: String? = nil,
        languagePreference: LanguagePreference = .auto
    ) {
        self.contextualStrings = contextualStrings
        self.vocabularyPrompt = vocabularyPrompt
        self.languagePreference = languagePreference
    }
}

public enum SttEvent: Sendable {
    /// HUD 表示用の暫定テキスト(確定済み + 未確定を連結した全文)。
    case partial(text: String)
    /// 確定テキスト。ストリーム完了直前に 1 回だけ流れる。
    case final(text: String, language: RecognizedLanguage)
}

/// 音声認識エンジン。
///
/// 契約: 入力 `AsyncStream` が終了したら「録音停止」を意味する。エンジンは残りを確定させ、
/// `.final` を 1 回流してからストリームを終了する。
public protocol SttEngine: Sendable {
    var identifier: EngineIdentifier { get }
    var modelName: String? { get }

    func availability(languagePreference: LanguagePreference) async -> EngineAvailability
    /// 必要なモデルを準備し、受け取りたい音声フォーマットを返す。nil なら `AudioFormats.canonical`。
    func prepare(hints: SttHints) async throws -> AVAudioFormat?
    func transcribe(audio: AsyncStream<AudioChunk>, hints: SttHints) -> AsyncThrowingStream<SttEvent, Error>
    /// アイドル時のモデル解放(NFR-5)。
    func unload() async
    /// モデル・音声アセットを取得する。進捗は 0...1。
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
}

extension SttEngine {
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        throw EngineError.notReady("このエンジンには取得できるモデルがありません")
    }
}

// MARK: - LLM

public protocol LlmEngine: Sendable {
    var identifier: EngineIdentifier { get }
    var modelName: String? { get }

    /// 1 回の呼び出しで渡せる入力(system + user)の目安(文字数)。
    ///
    /// 口述の整形は入力が短いので気にしなくてよいが、履歴分析のように
    /// **入力量を呼び出し側が決める**処理は、この予算に収まるよう自分で分割する責任がある。
    /// エンジンごとに桁が違う値なので、既定実装は置かない(黙って超過させない)。
    var inputCharacterBudget: Int { get }

    func availability() async -> EngineAvailability
    /// 整形を実行する。タイムアウト超過は throw して呼び出し側のフォールバックに委ねる。
    func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String
    func unload() async
    /// モデルを取得する。進捗は 0...1。
    func install(progress: @escaping @Sendable (Double) -> Void) async throws
}

extension LlmEngine {
    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        throw EngineError.notReady("このエンジンには取得できるモデルがありません")
    }
}

public enum EngineError: LocalizedError, Sendable {
    case timedOut
    case notReady(String)
    /// このプロセスでは回復できない。アプリを起動し直すしか手が無い(C-15d)。
    case needsAppRestart(String)
    case cancelled
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .timedOut: "処理がタイムアウトしました"
        case .notReady(let text), .needsAppRestart(let text): text
        case .cancelled: "キャンセルされました"
        case .failed(let text): text
        }
    }
}
