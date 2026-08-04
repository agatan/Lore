import AVFAudio
import Foundation
import WhisperKit

/// WhisperKit(CoreML)による高精度系 STT。
///
/// Whisper は本質的にバッチ処理なので、録音中は音声を溜め、一定間隔で
/// 溜まった分を再認識して暫定表示に流す。確定は停止後の 1 回。
/// SpeechAnalyzer より停止後レイテンシは大きい(設計 D-5 で受け入れたトレードオフ)。
public final class WhisperKitStt: SttEngine {
    public let identifier = EngineIdentifier.whisperKit

    /// 暫定認識を回す間隔。短くすると HUD の追従は良くなるが CPU を食う。
    static let partialInterval: Duration = .seconds(3)
    /// これより長くなったら暫定認識を止める(長い発話で CPU を食い続けないため)。
    static let partialMaxSeconds = 90.0
    static let sampleRate = 16_000.0

    private let state = State()
    private let variant: @Sendable () -> String

    public init(variant: @escaping @Sendable () -> String) {
        self.variant = variant
    }

    public var modelName: String? {
        let id = variant()
        return TranscriptionCatalog.all.first { $0.modelID == id }?.name ?? id
    }

    public func availability(languagePreference: LanguagePreference) async -> EngineAvailability {
        let id = variant()
        guard ModelStore.isDownloaded(whisperVariant: id) else {
            return .needsDownload("モデル(\(modelName ?? id))の取得が必要です")
        }
        return .ready
    }

    public func prepare(hints: SttHints) async throws -> AVAudioFormat? {
        try await state.load(variant: variant())
        // Whisper は 16kHz mono 固定。
        return AudioFormats.canonical
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        _ = try await ModelStore.downloadWhisper(variant: variant(), progress: progress)
        state.reset()
        try await state.load(variant: variant())
        progress(1)
    }

    public func unload() async {
        state.reset()
    }

    public func transcribe(
        audio: AsyncStream<AudioChunk>,
        hints: SttHints
    ) -> AsyncThrowingStream<SttEvent, Error> {
        AsyncThrowingStream { continuation in
            let work = Task {
                do {
                    try await self.run(audio: audio, hints: hints, continuation: continuation)
                } catch is CancellationError {
                    continuation.finish(throwing: EngineError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private func run(
        audio: AsyncStream<AudioChunk>,
        hints: SttHints,
        continuation: AsyncThrowingStream<SttEvent, Error>.Continuation
    ) async throws {
        try await state.load(variant: variant())

        // 音声の取り込みと暫定認識を同じタスクで回すと、認識中は取り込みが止まり、
        // 停止後もバッファの消化に認識が挟まって「認識中」から進まなくなる。
        // 取り込みは絶対に止めず、暫定認識は別タスクの best-effort にする。
        let buffer = SampleBuffer()
        let partials = Task { [weak self] in
            await self?.streamPartials(from: buffer, hints: hints, continuation: continuation)
        }

        for await chunk in audio {
            buffer.append(Self.floats(from: chunk.buffer))
        }
        // WhisperKit は直列利用前提なので、暫定認識が走り切るのを待ってから確定に入る。
        // 待たないと最終認識と同時に走り、同じインスタンスを二重に使ってしまう。
        partials.cancel()
        await partials.value

        let samples = buffer.snapshot()
        guard !samples.isEmpty else {
            continuation.yield(.final(text: "", language: .unknown))
            continuation.finish()
            return
        }

        let text = try await state.transcribe(samples: samples, hints: hints)
        let detected = LanguageDetector.detect(text, preference: hints.languagePreference)
        continuation.yield(.final(text: text, language: detected))
        continuation.finish()
    }

    /// 録音中の暫定表示。遅れても構わないので、失敗は無視して次の周期に任せる。
    private func streamPartials(
        from buffer: SampleBuffer,
        hints: SttHints,
        continuation: AsyncThrowingStream<SttEvent, Error>.Continuation
    ) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: Self.partialInterval)
            guard !Task.isCancelled else { return }

            let samples = buffer.snapshot()
            let seconds = Double(samples.count) / Self.sampleRate
            // 長くなるほど 1 回の認識が重くなるため、一定を超えたら暫定表示をやめる。
            guard seconds >= 1, seconds <= Self.partialMaxSeconds else { continue }

            guard let text = try? await state.transcribe(samples: samples, hints: hints),
                  !text.isEmpty, !Task.isCancelled
            else { continue }
            continuation.yield(.partial(text: text))
        }
    }

    /// 取り込みタスクと暫定認識タスクで共有するサンプル置き場。
    /// 追記と読み出しが別タスクから来るのでロックで守る。
    private final class SampleBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var samples: [Float] = []

        func append(_ new: [Float]) {
            lock.lock()
            samples.append(contentsOf: new)
            lock.unlock()
        }

        func snapshot() -> [Float] {
            lock.lock()
            defer { lock.unlock() }
            return samples
        }
    }

    /// Whisper は Float の配列を取る。フォーマットが Int16 でも取りこぼさないようにする。
    static func floats(from buffer: AVAudioPCMBuffer) -> [Float] {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return [] }
        let stride = Int(buffer.stride)

        if let channel = buffer.floatChannelData?[0] {
            return (0..<count).map { channel[$0 * stride] }
        }
        if let channel = buffer.int16ChannelData?[0] {
            let scale = Float(Int16.max)
            return (0..<count).map { Float(channel[$0 * stride]) / scale }
        }
        if let channel = buffer.int32ChannelData?[0] {
            let scale = Float(Int32.max)
            return (0..<count).map { Float(channel[$0 * stride]) / scale }
        }
        return []
    }

    /// `WhisperKit` は Sendable でなく、メソッドも nonisolated async なので、
    /// actor に入れると「アクタ境界を越えて非 Sendable を渡す」ことになってしまう。
    /// 同時に走るセッションは常に 1 つ(`DictationCoordinator` が保証)なので、
    /// ここは直列利用を前提にした保持箱として扱う。
    private final class State: @unchecked Sendable {
        private var loadedVariant: String?
        private var whisper: WhisperKit?

        func load(variant: String) async throws {
            if loadedVariant == variant, whisper != nil { return }
            guard let folder = ModelStore.whisperModelFolder(variant: variant) else {
                throw EngineError.notReady("モデル(\(variant))が取得されていません")
            }
            // download: false = このエンジンからはネットワークに出ない(取得は ModelStore の役目)。
            let config = WhisperKitConfig(
                model: variant,
                downloadBase: ModelStore.whisperDirectory,
                modelFolder: folder.path,
                verbose: false,
                logLevel: .error,
                prewarm: true,
                load: true,
                download: false
            )
            whisper = try await WhisperKit(config)
            loadedVariant = variant
        }

        func transcribe(samples: [Float], hints: SttHints) async throws -> String {
            guard let whisper else { throw EngineError.notReady("モデルが読み込まれていません") }
            let options = decodingOptions(for: hints)
            let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
            return results.map(\.text).joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        private func decodingOptions(for hints: SttHints) -> DecodingOptions {
            let language = hints.languagePreference.fixedLocale
                .map { $0.language.languageCode?.identifier ?? "ja" }
            // 語彙は initial prompt としてバイアスに使う(FR-2.5)。
            let promptTokens: [Int]? = hints.vocabularyPrompt.flatMap { prompt -> [Int]? in
                guard let tokenizer = whisper?.tokenizer else { return nil }
                let tokens = tokenizer.encode(text: " " + prompt)
                    .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                return tokens.isEmpty ? nil : Array(tokens.suffix(180))
            }

            return DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: language,
                temperature: 0,
                usePrefillPrompt: true,
                detectLanguage: language == nil,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                promptTokens: promptTokens
                // chunkingStrategy は既定(nil)。口述の長さでは分割の利点が無く、
                // 短い音声で .vad を指定すると挙動が不安定になる。
            )
        }

        func reset() {
            whisper = nil
            loadedVariant = nil
        }
    }
}
