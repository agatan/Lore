import AVFoundation
import Foundation
import Speech

/// macOS 26 標準の SpeechAnalyzer による STT。既定エンジン。
///
/// ストリーミングで volatile(暫定) / final(確定) が得られるため、録音停止時に残る
/// 未確定分だけを確定させれば済み、停止後レイテンシが最小になる(FR-2.4)。
public final class SpeechAnalyzerStt: SttEngine {
    public let identifier = EngineIdentifier.speechAnalyzer

    public init() {}

    public var modelName: String? { "システム音声モデル" }

    public func availability(languagePreference: LanguagePreference) async -> EngineAvailability {
        do {
            let locale = try await State.supportedLocale(for: Self.locale(for: languagePreference))
            switch try await State.assetState(for: locale) {
            case .installed:
                return .ready
            case .downloading:
                return .needsDownload("音声モデルのダウンロード中です")
            case .needsInstall:
                return .needsDownload("音声モデル(\(locale.localizedDisplayName))の取得が必要です")
            case .notReserved:
                return .unavailable(Self.needsRestartMessage(locale))
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
        let transcriber = try await State.readyTranscriber(for: locale)
        return await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
    }

    public func install(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await install(locale: Self.locale(for: .auto), progress: progress)
    }

    public func install(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        let supported = try await State.supportedLocale(for: locale)
        let transcriber = State.transcriber(locale: supported)
        _ = try await State.assetState(for: supported)
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

    /// 手放すのは**メモリに載ったモデルだけ**(NFR-5)。
    ///
    /// ロケールの予約には触らない。予約はメモリではなく Speech デーモン側の生きた状態で、
    /// 解放すると `AssetInventory.status` はアセットがディスクにあっても `.supported`
    /// に戻る。次の録音を止めるだけで、得るものが無い。
    public func unload() async {
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
        let transcriber = try await State.readyTranscriber(for: locale)

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
                    let segment = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !segment.isEmpty {
                        continuation.yield(.segment(
                            text: segment,
                            startOffset: result.range.start.seconds,
                            endOffset: result.range.end.seconds
                        ))
                    }
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
            continuation.yield(.sessionFinished(text: salvaged, language: LanguageDetector.detect(salvaged, preference: hints.languagePreference)))
            continuation.finish()
            return
        }

        let text = (finalized + volatileTail).trimmingCharacters(in: .whitespacesAndNewlines)
        continuation.yield(.sessionFinished(text: text, language: LanguageDetector.detect(text, preference: hints.languagePreference)))
        continuation.finish()
    }

    /// SpeechAnalyzer はロケール指定型なので、自動判定時は日本語モデルを主にする(設計 §4.3)。
    static func locale(for preference: LanguagePreference) -> Locale {
        preference.fixedLocale ?? Locale(identifier: "ja-JP")
    }

    /// 聞き取りモデルがいま使えるかどうか。
    ///
    /// `AssetInventory.Status` は Sendable でないため写しを持つ。同時に、
    /// `.supported` に潰されている「ディスクに無い」と「予約が効いていない」を分ける。
    /// 前者はユーザーがダウンロードすれば直り、後者はダウンロードしても直らない。
    enum AssetState: Sendable, Equatable {
        case installed
        case downloading
        /// アセットがディスクに無い。取得すれば使えるようになる。
        case needsInstall
        /// アセットはディスクにあるが、このプロセスへの割り当てが取れない。
        case notReserved
        case unsupported
        case unknown
    }

    /// 予約が取れなくなったときの説明。
    ///
    /// **取得も再試行も促してはいけない**。アセットは取得済みで、このプロセスの
    /// `AssetInventory` はもう何をしても戻らない(C-15d)。打つ手は起動し直すことだけ。
    static func needsRestartMessage(_ locale: Locale) -> String {
        "音声モデル(\(locale.localizedDisplayName))を使えなくなりました。Koe を再起動してください"
    }

    /// Speech framework への問い合わせをまとめた層。**状態は持たない**。
    ///
    /// ロケールの予約はプロセスに紐づく生きた状態で、こちらが握っているつもりでも
    /// 失われうる。アプリ側で「予約済み」を覚えると、失われたときに再予約を飛ばして
    /// 永久に未取得と判定してしまうため、キャッシュせず毎回問い合わせる。
    private enum State {
        /// 解析を始められる状態の transcriber。
        ///
        /// `AssetInventory.reserve(locale:)` を呼ぶまで、ロケールのアセットが入っていても
        /// `status` は `.supported` のままで、その状態で `SpeechAnalyzer.start` を呼ぶと
        /// framework 内部(`prepareModulesIfNeeded` → `setWorkers`)で trap する。
        /// 予約と状態確認を通ったものだけを返す。
        static func readyTranscriber(for locale: Locale) async throws -> SpeechTranscriber {
            let supported = try await supportedLocale(for: locale)
            switch try await assetState(for: supported) {
            case .installed:
                return transcriber(locale: supported)
            case .downloading:
                throw EngineError.notReady("音声モデルのダウンロード中です。完了後に再試行してください")
            case .needsInstall:
                throw EngineError.notReady(
                    "音声モデル(\(supported.localizedDisplayName))が未取得です。設定 > モデル から取得してください"
                )
            case .notReserved:
                throw EngineError.needsAppRestart(SpeechAnalyzerStt.needsRestartMessage(supported))
            case .unsupported:
                throw EngineError.notReady("\(supported.identifier) は SpeechAnalyzer 非対応です")
            case .unknown:
                throw EngineError.notReady("音声モデルの状態を判定できません")
            }
        }

        /// 予約してからアセット状態を返す。
        ///
        /// `locale` は `supportedLocale(for:)` が返した正規形であることが前提。
        static func assetState(for locale: Locale) async throws -> AssetState {
            try await reserve(locale)
            let state = await status(of: locale)
            guard state != .installed else { return .installed }

            // `.supported` には「ディスクに無い」と「予約が効いていない」が潰れている。
            // どちらなのかは在庫を直接見て切り分ける。取り違えると、取得済みのモデルに
            // 対してダウンロードを促す(押しても直らない)。
            guard await isInstalledOnDisk(locale), await !isReserved(locale) else { return state }
            await logLostInventory(locale)
            return .notReserved
        }

        /// アセットがこの Mac のディスクに入っているか。**予約とは独立に答えられる**ので、
        /// 「未取得」と言い切ってよいかの判定はこちらを根拠にする。
        private static func isInstalledOnDisk(_ locale: Locale) async -> Bool {
            await SpeechTranscriber.installedLocales.contains { $0.identifier == locale.identifier }
        }

        /// 予約が本当に効いているか。
        ///
        /// `reserve` の戻り値は「**新たに**予約したか」なので判定に使えない。予約済みでも、
        /// 在庫 API が死んでいて何も起きなかったときも、等しく `false` を返す。
        private static func isReserved(_ locale: Locale) async -> Bool {
            await AssetInventory.reservedLocales.contains { $0.identifier == locale.identifier }
        }

        /// 断る理由をそのまま残す。ここが無いと OS ログからの逆算になる。
        private static func logLostInventory(_ locale: Locale) async {
            let reserved = await AssetInventory.reservedLocales.map(\.identifier).joined(separator: ",")
            KoeLog.engine.error(
                "音声モデルの在庫 API が死んでいます(取得済みだが予約できない) locale=\(locale.identifier, privacy: .public) reserved=[\(reserved, privacy: .public)]"
            )
        }

        private static func status(of locale: Locale) async -> AssetState {
            switch await AssetInventory.status(forModules: [transcriber(locale: locale)]) {
            case .installed: .installed
            case .downloading: .downloading
            case .supported: .needsInstall
            case .unsupported: .unsupported
            @unknown default: .unknown
            }
        }

        /// 状態を見る前に必ず呼ぶ。冪等で、予約済みなら 1ms 未満で返る(実測 0.2ms)。
        private static func reserve(_ locale: Locale) async throws {
            do {
                _ = try await AssetInventory.reserve(locale: locale)
            } catch {
                throw EngineError.notReady(
                    "音声モデルの割り当てに失敗しました(\(error.localizedDescription))。"
                    + "予約できる言語は最大 \(AssetInventory.maximumReservedLocales) 個です"
                )
            }
        }

        /// 予約・状態確認・解析のすべてでこの値を使う。ロケールの表記が混ざると
        /// `release(reservedLocale:)` が黙って何もしない(正規形 `ja_JP` しか受け付けない)。
        static func supportedLocale(for locale: Locale) async throws -> Locale {
            guard SpeechTranscriber.isAvailable else {
                throw EngineError.notReady("この Mac では SpeechAnalyzer を利用できません")
            }
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
                throw EngineError.notReady("\(locale.identifier) は SpeechAnalyzer 非対応です")
            }
            return supported
        }

        /// `SpeechTranscriber` は**セッションごとに作り直す**。同じインスタンスを 2 つ目の
        /// `SpeechAnalyzer` に渡すと `setWorkers(for:reusingFrom:)` で trap する(C-16)。
        /// `results` も 1 回しか列挙できない。モデル自体は `modelRetention: .lingering` で
        /// 温存されるため、作り直しのコストは実用上問題にならない。
        static func transcriber(locale: Locale) -> SpeechTranscriber {
            SpeechTranscriber(
                locale: locale,
                transcriptionOptions: [],
                reportingOptions: [.volatileResults],
                attributeOptions: []
            )
        }
    }
}

private extension Locale {
    var localizedDisplayName: String {
        Locale(identifier: "ja_JP").localizedString(forIdentifier: identifier) ?? identifier
    }
}
