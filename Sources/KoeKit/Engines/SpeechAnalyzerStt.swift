import AVFoundation
import Foundation
import Speech

/// macOS 26 標準の SpeechAnalyzer による STT。既定エンジン。
///
/// ストリーミングで volatile(暫定) / final(確定) が得られるため、録音停止時に残る
/// 未確定分だけを確定させれば済み、停止後レイテンシが最小になる(FR-2.4)。
public final class SpeechAnalyzerStt: SttEngine {
    public let identifier = EngineIdentifier.speechAnalyzer

    private let state = State()

    public init() {}

    public var modelName: String? { "システム音声モデル" }

    public func availability(languagePreference: LanguagePreference) async -> EngineAvailability {
        guard SpeechTranscriber.isAvailable else {
            return .unavailable("この Mac では SpeechAnalyzer を利用できません")
        }
        let locale = Self.locale(for: languagePreference)
        do {
            let transcriber = try await state.transcriber(for: locale)
            switch try await state.assetState(for: transcriber, locale: locale) {
            case .installed:
                return .ready
            case .downloading:
                return .needsDownload("音声モデルのダウンロード中です")
            case .needsInstall:
                return .needsDownload("音声モデル(\(locale.localizedDisplayName))の取得が必要です")
            case .unsupported:
                return .unavailable("\(locale.identifier) は SpeechAnalyzer 非対応です")
            case .unknown:
                return .unavailable("音声モデルの状態を判定できません")
            }
        } catch {
            return .unavailable(error.localizedDescription)
        }
    }

    public func prepare(hints: SttHints) async throws -> AVAudioFormat? {
        let locale = Self.locale(for: hints.languagePreference)
        // 起動時の prewarm でロケールを予約しておく(予約なしで解析を始めると trap する)。
        let transcriber = try await state.readyTranscriber(for: locale)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await install(locale: Self.locale(for: .auto), progress: progress)
    }

    public func install(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let transcriber = try await state.transcriber(for: locale)
        _ = try await state.assetState(for: transcriber, locale: locale)
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            progress(1)
            return
        }
        let observation = request.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            progress(p.fractionCompleted)
        }
        defer { observation.invalidate() }
        try await request.downloadAndInstall()
        progress(1)
    }

    public func unload() async {
        await state.reset()
        await SpeechModels.endRetention()
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
        let locale = Self.locale(for: hints.languagePreference)
        // アセットが揃っていない状態で start すると Speech framework の中で trap する。
        // ここで弾いて、通常の失敗としてフォールバック経路に流す。
        let transcriber = try await state.readyTranscriber(for: locale)

        let context = AnalysisContext()
        if !hints.contextualStrings.isEmpty {
            // 語彙を認識バイアスとして渡す(FR-2.5)。効き方はエンジン依存なので、
            // 表記矯正の本命はあくまで LLM 整形段(設計 D-6)。
            context.contextualStrings[.general] = Array(hints.contextualStrings.prefix(200))
        }

        let (inputs, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(
            modules: [transcriber],
            options: SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .lingering)
        )
        try await analyzer.setContext(context)

        // 音声の供給。ストリームの終了 = 録音停止なので、そのまま最終確定へ進む。
        let feeding = Task {
            for await chunk in audio {
                inputContinuation.yield(AnalyzerInput(buffer: chunk.buffer))
            }
            inputContinuation.finish()
        }

        var finalized = ""
        var volatileTail = ""

        do {
            try await analyzer.start(inputSequence: inputs)
        } catch {
            feeding.cancel()
            inputContinuation.finish()
            throw error
        }

        // 入力が尽きたら残りを確定させる。results の終了条件でもある。
        let finishing = Task {
            await feeding.value
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        }

        do {
            for try await result in transcriber.results {
                let text = String(result.text.characters)
                if result.isFinal {
                    finalized += text
                    volatileTail = ""
                } else {
                    volatileTail = text
                }
                continuation.yield(.partial(text: finalized + volatileTail))
            }
            _ = try await finishing.value
        } catch {
            finishing.cancel()
            feeding.cancel()
            await analyzer.cancelAndFinishNow()
            // ここまでに確定した分があれば失わずに返す(NFR-3)。
            let salvaged = (finalized + volatileTail).trimmingCharacters(in: .whitespacesAndNewlines)
            if salvaged.isEmpty {
                throw error
            }
            continuation.yield(.final(text: salvaged, language: LanguageDetector.detect(salvaged, preference: hints.languagePreference)))
            continuation.finish()
            return
        }

        let text = (finalized + volatileTail).trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.yield(.final(text: text, language: LanguageDetector.detect(text, preference: hints.languagePreference)))
        continuation.finish()
    }

    /// SpeechAnalyzer はロケール指定型なので、自動判定時は日本語モデルを主にする(設計 §4.3)。
    static func locale(for preference: LanguagePreference) -> Locale {
        preference.fixedLocale ?? Locale(identifier: "ja-JP")
    }

    /// アセットの状態(`AssetInventory.Status` の Sendable な写し)。
    enum AssetState: Sendable {
        case installed
        case downloading
        case needsInstall
        case unsupported
        case unknown
    }

    /// ロケールの予約状態だけを持つ。
    ///
    /// `SpeechTranscriber` は**セッションごとに作り直す**。同じインスタンスを 2 つ目の
    /// `SpeechAnalyzer` に渡すと `setWorkers(for:reusingFrom:)` で trap する(2 回目の録音で必ず落ちた)。
    /// `results` も 1 回しか列挙できない。モデル自体は `modelRetention: .lingering` で温存されるため、
    /// 作り直しのコストは実用上問題にならない。
    private actor State {
        private var reserved: Set<String> = []

        /// 解析を始められる状態の transcriber。
        ///
        /// `AssetInventory.reserve(locale:)` を呼ぶまで、ロケールのアセットが入っていても
        /// `status` は `.supported` のままで、その状態で `SpeechAnalyzer.start` を呼ぶと
        /// framework 内部(`prepareModulesIfNeeded` → `setWorkers`)で trap する。
        /// 予約と状態確認を通ったものだけを返す。
        func readyTranscriber(for locale: Locale) async throws -> SpeechTranscriber {
            let transcriber = try await transcriber(for: locale)
            switch try await assetState(for: transcriber, locale: locale) {
            case .installed:
                return transcriber
            case .downloading:
                throw EngineError.notReady("音声モデルのダウンロード中です。完了後に再試行してください")
            case .needsInstall:
                throw EngineError.notReady(
                    "音声モデル(\(locale.localizedDisplayName))が未取得です。設定 > モデル から取得してください"
                )
            case .unsupported:
                throw EngineError.notReady("\(locale.identifier) は SpeechAnalyzer 非対応です")
            case .unknown:
                throw EngineError.notReady("音声モデルの状態を判定できません")
            }
        }

        /// 予約してからアセット状態を返す。予約は冪等。
        ///
        /// `AssetInventory.Status` は Sendable でないため、アクタ境界を越えない自前の表現に変換する。
        func assetState(for transcriber: SpeechTranscriber, locale: Locale) async throws -> AssetState {
            try await reserveIfNeeded(locale)
            switch await AssetInventory.status(forModules: [transcriber]) {
            case .installed: return .installed
            case .downloading: return .downloading
            case .supported: return .needsInstall
            case .unsupported: return .unsupported
            @unknown default: return .unknown
            }
        }

        private func reserveIfNeeded(_ locale: Locale) async throws {
            let key = locale.identifier(.bcp47)
            guard !reserved.contains(key) else { return }
            do {
                _ = try await AssetInventory.reserve(locale: locale)
                reserved.insert(key)
            } catch {
                throw EngineError.notReady(
                    "音声モデルの割り当てに失敗しました(\(error.localizedDescription))。"
                    + "予約できる言語は最大 \(AssetInventory.maximumReservedLocales) 個です"
                )
            }
        }

        func transcriber(for locale: Locale) async throws -> SpeechTranscriber {
            guard SpeechTranscriber.isAvailable else {
                throw EngineError.notReady("この Mac では SpeechAnalyzer を利用できません")
            }
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw EngineError.notReady("\(locale.identifier) は SpeechAnalyzer 非対応です")
            }
            return SpeechTranscriber(
                locale: supported,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
        }

        func reset() async {
            for key in reserved {
                _ = await AssetInventory.release(reservedLocale: Locale(identifier: key))
            }
            reserved.removeAll()
        }
    }
}

private extension Locale {
    var localizedDisplayName: String {
        Locale(identifier: "ja_JP").localizedString(forIdentifier: identifier) ?? identifier
    }
}
