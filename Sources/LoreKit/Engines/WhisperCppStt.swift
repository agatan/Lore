import AVFAudio
import CryptoKit
import Foundation
import Synchronization
import whisper

/// GGML modelで発話区間を一括認識するSTT。
///
/// GGML重みは`WhisperModelCache`で用途をまたいで1つだけ保持し、このactorは用途ごとの推論stateを持つ。
/// 音声入力とライフログは別stateなので互いの推論を待たない。同じstateでの推論と結果読取りは
/// このactorとstate handleの排他で直列化する。
public actor WhisperCppStt: SttEngine {
    public nonisolated let identifier = EngineIdentifier.whisperCpp
    public nonisolated let modelName: String?
    public nonisolated let model: WhisperModel

    private let modelRoot: URL
    private let cache: WhisperModelCache
    private var state: WhisperStateHandle?

    public init(model: WhisperModel, modelRoot: URL? = nil, cache: WhisperModelCache = .shared) {
        self.model = model
        self.modelName = model.displayName
        self.modelRoot = modelRoot ?? Self.defaultModelRoot
        self.cache = cache
    }

    public func availability(languagePreference: LanguagePreference) async -> EngineAvailability {
        isInstalled()
            ? .ready
            : .needsDownload("設定から \(model.displayName) を取得してください")
    }

    public func prepare(hints: SttHints) async throws -> AVAudioFormat? {
        guard isInstalled() else {
            throw EngineError.notReady("設定から \(model.displayName) を取得してください")
        }
        return AudioFormats.canonical
    }

    /// 録音中に推論stateを用意し、停止後の認識からmodel loadを外す。
    public func warmUp() throws {
        _ = try loadedState()
    }

    public nonisolated func transcribe(
        audio: AsyncStream<AudioChunk>,
        hints: SttHints
    ) -> AsyncThrowingStream<SttEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.transcribeBurst(audio: audio, hints: hints, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish(throwing: EngineError.cancelled)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func unload() async {
        state = nil
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        let delegate = ModelDownloadProgressDelegate(progress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(
            for: URLRequest(url: model.downloadURL),
            delegate: delegate
        )
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw EngineError.failed("Whisper modelの取得先が正常に応答しませんでした")
        }
        try Task.checkCancellation()

        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard byteCount == model.byteCount else {
            throw EngineError.failed("取得したWhisper modelの容量が一致しません")
        }
        guard try Self.sha256(of: temporaryURL) == model.sha256 else {
            throw EngineError.failed("取得したWhisper modelのSHA-256が一致しません")
        }
        try Task.checkCancellation()

        let destination = modelURL
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        progress(1)
    }

    public func deleteInstalledModel() async throws {
        await unload()
        if FileManager.default.fileExists(atPath: modelURL.path) {
            try FileManager.default.removeItem(at: modelURL)
        }
    }

    public func isInstalled() -> Bool {
        guard let values = try? modelURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            return false
        }
        return values.isRegularFile == true && Int64(values.fileSize ?? 0) == model.byteCount
    }

    private func transcribeBurst(
        audio: AsyncStream<AudioChunk>,
        hints: SttHints,
        continuation: AsyncThrowingStream<SttEvent, Error>.Continuation
    ) async throws {
        var recorded: [Float] = []
        for await chunk in audio {
            try Task.checkCancellation()
            recorded.append(contentsOf: try Self.samples(from: chunk.buffer))
        }
        let span = WhisperInputPolicy.speechSpan(of: recorded, sampleRate: AudioFormats.canonical.sampleRate)
        guard !span.isEmpty else {
            continuation.yield(.sessionFinished(text: "", language: .unknown))
            return
        }
        let samples = Array(recorded[span])
        let spanOffset = Double(span.lowerBound) / AudioFormats.canonical.sampleRate

        let state = try loadedState()
        let cancellation = WhisperCancellationFlag()
        let language = switch hints.languagePreference {
        case .auto: "auto"
        case .ja: "ja"
        case .en: "en"
        case .zhHans: "zh"
        }
        let prompt = WhisperInputPolicy.fittedPrompt(hints.vocabularyPrompt) {
            state.weights.tokenCount(of: $0) <= WhisperInputPolicy.maximumPromptTokens
        }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        // GPU実行時もCPU側でmel生成とdecoder samplingを行う。Metal M6実測では1〜10 threadで差が無いため、
        // 他appへ譲れるよう少数に抑える。
        params.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))
        params.translate = false
        params.no_context = true
        params.no_timestamps = false
        params.single_segment = false
        params.print_special = false
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.suppress_nst = true
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<WhisperCancellationFlag>.fromOpaque(userData)
                .takeUnretainedValue().isCancelled
        }
        params.abort_callback_user_data = Unmanaged.passUnretained(cancellation).toOpaque()

        let inference = try await withTaskCancellationHandler {
            try state.withExclusiveAccess { context, statePointer in
                try Task.checkCancellation()
                let result = language.withCString { languagePointer in
                    (prompt ?? "").withCString { promptPointer in
                        params.language = languagePointer
                        params.initial_prompt = prompt == nil ? nil : promptPointer
                        return samples.withUnsafeBufferPointer { buffer in
                            whisper_full_with_state(context, statePointer, params, buffer.baseAddress, Int32(buffer.count))
                        }
                    }
                }
                if cancellation.isCancelled || Task.isCancelled {
                    throw CancellationError()
                }
                guard result == 0 else {
                    throw EngineError.failed("whisper.cppが文字起こしを完了できませんでした (code: \(result))")
                }

                var segments: [WhisperSegment] = []
                for index in 0..<whisper_full_n_segments_from_state(statePointer) {
                    guard let textPointer = whisper_full_get_segment_text_from_state(statePointer, index) else { continue }
                    let text = TranscriptText.whisperSanitized(String(cString: textPointer))
                    guard !text.isEmpty, !WhisperInputPolicy.isPromptEcho(text, prompt: prompt) else { continue }
                    segments.append(WhisperSegment(
                        text: text,
                        startOffset: spanOffset + Double(whisper_full_get_segment_t0_from_state(statePointer, index)) / 100,
                        endOffset: spanOffset + Double(whisper_full_get_segment_t1_from_state(statePointer, index)) / 100
                    ))
                }
                return WhisperInference(
                    segments: segments,
                    language: Self.recognizedLanguage(statePointer)
                )
            }
        } onCancel: {
            cancellation.cancel()
        }

        for segment in inference.segments {
            continuation.yield(.segment(
                text: segment.text,
                startOffset: segment.startOffset,
                endOffset: segment.endOffset
            ))
        }
        let text = TranscriptText.sanitized(inference.segments.map(\.text).joined(separator: " "))
        continuation.yield(.partial(text: text))
        continuation.yield(.sessionFinished(text: text, language: inference.language))
    }

    private func loadedState() throws -> WhisperStateHandle {
        if let state { return state }
        guard isInstalled() else {
            throw EngineError.notReady("設定から \(model.displayName) を取得してください")
        }
        let weights = try cache.weights(at: modelURL)
        guard let pointer = whisper_init_state(weights.pointer) else {
            throw EngineError.failed("whisper.cppの推論状態を作成できませんでした")
        }
        let handle = WhisperStateHandle(weights: weights, pointer: pointer)
        state = handle
        return handle
    }

    private nonisolated static func recognizedLanguage(_ state: OpaquePointer) -> RecognizedLanguage {
        guard let pointer = whisper_lang_str(whisper_full_lang_id_from_state(state)) else { return .unknown }
        return switch String(cString: pointer) {
        case "ja": .ja
        case "en": .en
        case "zh": .zhHans
        default: .unknown
        }
    }

    private var modelURL: URL {
        modelRoot.appending(path: model.fileName)
    }

    private nonisolated static func samples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount == 1,
              let channel = buffer.floatChannelData?[0] else {
            throw EngineError.failed("whisper.cppへ渡す音声は16 kHz mono Float32である必要があります")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static var defaultModelRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lore/Models/WhisperCpp", directoryHint: .isDirectory)
    }

    public nonisolated static var legacyModelRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Lore/Models/WhisperKit", directoryHint: .isDirectory)
    }
}

private final class WhisperCancellationFlag: @unchecked Sendable {
    private let cancelled = Mutex(false)

    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

/// process内で共有するGGML重み。全stateが手放した時点で解放する。
public final class WhisperModelCache: Sendable {
    public static let shared = WhisperModelCache()

    private let entries = Mutex<[String: WeakWhisperWeights]>([:])

    public init() {}

    /// 同じfileのmodelがloadされていれば共有し、無ければ一度だけloadする。
    func weights(at url: URL) throws -> WhisperWeights {
        try entries.withLock { entries in
            if let weights = entries[url.path]?.value { return weights }
            var params = whisper_context_default_params()
            params.use_gpu = true
            params.flash_attn = true
            guard let pointer = url.path.withCString({ whisper_init_from_file_with_params_no_state($0, params) }) else {
                throw EngineError.failed("whisper.cpp modelを読み込めませんでした。削除して再取得してください")
            }
            let weights = WhisperWeights(pointer: pointer)
            entries = entries.filter { $0.value.value != nil }
            entries[url.path] = WeakWhisperWeights(value: weights)
            return weights
        }
    }
}

private struct WeakWhisperWeights {
    weak var value: WhisperWeights?
}

final class WhisperWeights: @unchecked Sendable {
    let pointer: OpaquePointer

    init(pointer: OpaquePointer) {
        self.pointer = pointer
    }

    /// 語彙表を読むだけなので、どのstateの推論中にも呼べる。
    func tokenCount(of text: String) -> Int {
        let capacity = WhisperInputPolicy.maximumPromptTokens + 1
        var tokens = [whisper_token](repeating: 0, count: capacity)
        let count = text.withCString { whisper_tokenize(pointer, $0, &tokens, Int32(capacity)) }
        // 容量を超えると負数で必要数を返す。
        return Int(count < 0 ? -count : count)
    }

    deinit {
        whisper_free(pointer)
    }
}

private final class WhisperStateHandle: @unchecked Sendable {
    let weights: WhisperWeights
    private let pointer: OpaquePointer
    private let inferenceLock = Mutex(())

    init(weights: WhisperWeights, pointer: OpaquePointer) {
        self.weights = weights
        self.pointer = pointer
    }

    func withExclusiveAccess<Result>(_ body: (OpaquePointer, OpaquePointer) throws -> Result) rethrows -> Result {
        try inferenceLock.withLock { _ in try body(weights.pointer, pointer) }
    }

    deinit {
        whisper_free_state(pointer)
    }
}

private struct WhisperSegment: Sendable {
    let text: String
    let startOffset: TimeInterval
    let endOffset: TimeInterval
}

private struct WhisperInference: Sendable {
    let segments: [WhisperSegment]
    let language: RecognizedLanguage
}

private final class ModelDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}
}

extension WhisperModel {
    var fileName: String {
        switch self {
        case .small: "ggml-small-q5_1.bin"
        case .largeV3: "ggml-large-v3-q5_0.bin"
        case .largeV3Turbo: "ggml-large-v3-turbo-q5_0.bin"
        }
    }

    var byteCount: Int64 {
        switch self {
        case .small: 190_085_487
        case .largeV3: 1_081_140_203
        case .largeV3Turbo: 574_041_195
        }
    }

    var sha256: String {
        switch self {
        case .small: "ae85e4a935d7a567bd102fe55afc16bb595bdb618e11b2fc7591bc08120411bb"
        case .largeV3: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"
        case .largeV3Turbo: "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)?download=true")!
    }
}
