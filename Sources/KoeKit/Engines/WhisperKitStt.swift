import AVFAudio
import Foundation
import WhisperKit

/// 適応的に確定された発話区間を一括認識するライフログ用STT。
/// マイク、無音判定、復旧用audio保存はKoe側で完了し、WhisperKitは常時実行しない。
public actor WhisperKitStt: SttEngine {
    public nonisolated let identifier = EngineIdentifier.whisperKit
    public nonisolated let modelName: String?

    private let model: WhisperModel
    private let modelRoot: URL
    private var whisperKit: WhisperKit?
    private var isLoading = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []

    public init(model: WhisperModel, modelRoot: URL? = nil) {
        self.model = model
        self.modelName = model.displayName
        self.modelRoot = modelRoot ?? Self.defaultModelRoot
    }

    public func availability(languagePreference: LanguagePreference) async -> EngineAvailability {
        installedModelFolder() == nil
            ? .needsDownload("ライフログ設定から \(model.displayName) を取得してください")
            : .ready
    }

    public func prepare(hints: SttHints) async throws -> AVAudioFormat? {
        guard installedModelFolder() != nil else {
            throw EngineError.notReady("ライフログ設定から \(model.displayName) を取得してください")
        }
        return AudioFormats.canonical
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
        if isLoading {
            try? await waitForLoading()
        }
        await whisperKit?.unloadModels()
        whisperKit = nil
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: modelRoot, withIntermediateDirectories: true)
        _ = try await WhisperKit.download(
            variant: model.rawValue,
            downloadBase: modelRoot,
            progressCallback: { value in progress(value.fractionCompleted) }
        )
        _ = try await ModelUtilities.loadTokenizer(
            for: model.whisperKitVariant,
            tokenizerFolder: modelRoot
        )
        guard installedModelFolder() != nil else {
            throw EngineError.failed("ダウンロードしたWhisperモデルを検証できませんでした")
        }
        progress(1)
    }

    public func deleteInstalledModel() async throws {
        await unload()
        if let folder = compiledModelFolder() {
            try FileManager.default.removeItem(at: folder)
        }
        let tokenizerFolder = tokenizerFolder()
        if FileManager.default.fileExists(atPath: tokenizerFolder.path) {
            try FileManager.default.removeItem(at: tokenizerFolder)
        }
    }

    public func isInstalled() -> Bool { installedModelFolder() != nil }

    private func transcribeBurst(
        audio: AsyncStream<AudioChunk>,
        hints: SttHints,
        continuation: AsyncThrowingStream<SttEvent, Error>.Continuation
    ) async throws {
        var samples: [Float] = []
        for await chunk in audio {
            try Task.checkCancellation()
            samples.append(contentsOf: try Self.samples(from: chunk.buffer))
        }
        guard !samples.isEmpty else {
            continuation.yield(.sessionFinished(text: "", language: .unknown))
            return
        }

        let engine = try await loadedWhisperKit()
        let language: String? = switch hints.languagePreference {
        case .auto: nil
        case .ja: "ja"
        case .en: "en"
        case .zhHans: "zh"
        }
        var decodeOptions = DecodingOptions(language: language, skipSpecialTokens: true, wordTimestamps: true)
        if let prompt = hints.vocabularyPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !prompt.isEmpty,
           let tokenizer = engine.tokenizer {
            decodeOptions.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            decodeOptions.usePrefillPrompt = true
        }
        let results = try await engine.transcribe(audioArray: samples, decodeOptions: decodeOptions)
        let segments = results.flatMap(\.segments).sorted { $0.start < $1.start }
        for segment in segments {
            let text = TranscriptText.sanitized(segment.text)
            guard !text.isEmpty else { continue }
            continuation.yield(.segment(
                text: text,
                startOffset: Double(segment.start),
                endOffset: Double(segment.end)
            ))
        }
        let text = TranscriptText.sanitized(results.map(\.text).joined(separator: " "))
        continuation.yield(.partial(text: text))
        let recognizedLanguage: RecognizedLanguage = switch results.first?.language {
        case "ja": .ja
        case "en": .en
        case "zh": .zhHans
        default: .unknown
        }
        continuation.yield(.sessionFinished(text: text, language: recognizedLanguage))
    }

    private func loadedWhisperKit() async throws -> WhisperKit {
        if let whisperKit { return whisperKit }
        if isLoading {
            try await waitForLoading()
            guard let whisperKit else {
                throw EngineError.failed("WhisperKitの初期化結果を取得できませんでした")
            }
            return whisperKit
        }
        guard let folder = installedModelFolder() else {
            throw EngineError.notReady("ライフログ設定から \(model.displayName) を取得してください")
        }
        isLoading = true
        do {
            let value = try await WhisperKit(WhisperKitConfig(
                downloadBase: modelRoot,
                modelFolder: folder.path,
                verbose: false,
                prewarm: true,
                load: true,
                download: false
            ))
            whisperKit = value
            finishLoading()
            return value
        } catch {
            finishLoading(throwing: error)
            throw error
        }
    }

    private func waitForLoading() async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadWaiters.append(continuation)
        }
    }

    private func finishLoading(throwing error: Error? = nil) {
        isLoading = false
        let waiters = loadWaiters
        loadWaiters = []
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    private func installedModelFolder() -> URL? {
        guard Self.containsTokenizer(tokenizerFolder()) else { return nil }
        return compiledModelFolder()
    }

    private func compiledModelFolder() -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: modelRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.lastPathComponent == "openai_whisper-\(model.rawValue)",
                  Self.containsCompiledModels(url) else { continue }
            return url
        }
        return nil
    }

    private func tokenizerFolder() -> URL {
        modelRoot.appending(path: "models/openai/\(model.tokenizerRepositoryName)", directoryHint: .isDirectory)
    }

    private static func containsTokenizer(_ folder: URL) -> Bool {
        ["tokenizer.json", "tokenizer_config.json"].allSatisfy {
            FileManager.default.fileExists(atPath: folder.appending(path: $0).path)
        }
    }

    private static func containsCompiledModels(_ folder: URL) -> Bool {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return false }
        var count = 0
        for case let url as URL in enumerator where url.pathExtension == "mlmodelc" {
            count += 1
            enumerator.skipDescendants()
            if count >= 3 { return true }
        }
        return false
    }

    private nonisolated static func samples(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              buffer.format.channelCount == 1,
              let channel = buffer.floatChannelData?[0] else {
            throw EngineError.failed("WhisperKitへ渡す音声は16 kHz mono Float32である必要があります")
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    public nonisolated static var defaultModelRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Koe/Models/WhisperKit", directoryHint: .isDirectory)
    }
}

private extension WhisperModel {
    var whisperKitVariant: ModelVariant {
        switch self {
        case .small: .small
        case .largeV3, .largeV3Turbo: .largev3
        }
    }

    var tokenizerRepositoryName: String {
        switch self {
        case .small: "whisper-small"
        case .largeV3, .largeV3Turbo: "whisper-large-v3"
        }
    }
}
