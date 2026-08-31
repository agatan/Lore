import AppKit
import Foundation
import Observation

public enum SpeechCaptureDestination: Sendable, Equatable {
    case dictation
    case voiceMemo

    var writesHistory: Bool { self == .dictation }
    var insertsIntoFrontmostApp: Bool { self == .dictation }
    var suspendsLifeLogCapture: Bool { self == .voiceMemo }
}

/// 口述セッションの状態機械を駆動する唯一の場所。
///
/// 順序を強制するのがこのクラスの仕事: STT 確定 → 永続化 → 整形 → 挿入。
/// 整形と挿入のどんな失敗も、生テキストの喪失には繋げない(NFR-3)。
@MainActor
@Observable
public final class DictationCoordinator {
    public struct Dependencies {
        public var settings: AppSettings
        public var engines: EngineRegistry
        /// DB のオープンは非同期なので、保存先は都度取得する(起動直後でも状態機械は組み立てられる)。
        public var historyStore: @MainActor () -> HistoryStore?
        public var modes: @MainActor () -> [Mode]
        public var sharedRules: @MainActor () -> String
        public var vocabulary: @MainActor () -> [VocabularyEntry]
        public var onRecordChanged: @MainActor (SessionRecord) -> Void
        /// このプロセスでは直せない失敗の通知(`EngineError.needsAppRestart`)。
        /// 状態機械は「もう先へ進めない」ことだけを知り、畳み方はアプリ側が決める。
        public var onNeedsAppRestart: @MainActor () -> Void

        public init(
            settings: AppSettings,
            engines: EngineRegistry,
            historyStore: @MainActor @escaping () -> HistoryStore?,
            modes: @MainActor @escaping () -> [Mode],
            sharedRules: @MainActor @escaping () -> String = { BuiltinSharedRules.text },
            vocabulary: @MainActor @escaping () -> [VocabularyEntry],
            onRecordChanged: @MainActor @escaping (SessionRecord) -> Void,
            onNeedsAppRestart: @MainActor @escaping () -> Void = {}
        ) {
            self.settings = settings
            self.engines = engines
            self.historyStore = historyStore
            self.modes = modes
            self.sharedRules = sharedRules
            self.vocabulary = vocabulary
            self.onRecordChanged = onRecordChanged
            self.onNeedsAppRestart = onNeedsAppRestart
        }
    }

    /// HUD 用の波形バッファ長。
    static let levelHistoryLength = 64

    /// 挿入まで通ったときの居残り時間。
    ///
    /// 結果は挿入先のアプリに出ているので、HUD に確認の役目は無い。
    /// フェードアウト(0.2 秒)が始まるきっかけを作るだけの長さにする。
    static let hudSuccessLingerDuration: Duration = .milliseconds(120)
    /// 読んでもらう必要がある終わり方(失敗・クリップボード退避・整形スキップ)の居残り時間。
    static let hudNoticeLingerDuration: Duration = .seconds(2)
    /// 停止後、STT の確定を待つ上限。エンジンが応答しないときに
    /// 「認識中」から永遠に戻らないための保険。
    ///
    /// SpeechAnalyzer は録音中に逐次確定していくので、停止後に残るのは末尾だけ。
    /// 録音長に比例させる必要はない。打ち切っても暫定テキストで先へ進める。
    static let finalizationTimeout: Duration = .seconds(30)

    // MARK: 観測される状態

    public private(set) var phase: SessionPhase = .idle
    public private(set) var liveTranscript = ""
    public private(set) var inputLevel: Float = 0
    public private(set) var levelHistory: [Float] = Array(repeating: 0, count: levelHistoryLength)
    public private(set) var activeMode: Mode?
    public private(set) var recordingElapsed: Duration = .zero
    /// 録音に使っている入力デバイス名。録音が始まって実際に束ねてから入る。
    public private(set) var inputDeviceName: String?
    public private(set) var lastRecord: SessionRecord?
    public private(set) var captureDestination: SpeechCaptureDestination = .dictation
    public private(set) var activityLabel: String?
    /// HUD・メニューに出す補足(整形スキップ理由など)。
    public private(set) var statusDetail: String?
    /// 次回以降のモードを手動で固定する(FR-4.5)。nil = アプリから自動判定。
    public var pinnedModeID: Mode.ID? {
        didSet { refreshResolvedMode() }
    }
    /// 自動判定の結果(録音前のプレビュー表示用)。
    public private(set) var previewMode: Mode?

    public var isRecording: Bool {
        if case .recording = phase { return true }
        return false
    }

    public var isBusy: Bool { phase.isActive }

    // MARK: 依存

    private let deps: Dependencies
    private let audio = AudioCapture()
    private let frontmost = FrontmostAppObserver()
    private let sounds = SoundPlayer()

    private var draft: SessionDraft?
    private var sessionTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var elapsedTask: Task<Void, Never>?
    private var lingerTask: Task<Void, Never>?
    private var unloadTask: Task<Void, Never>?
    private var targetApp: NSRunningApplication?
    private var stopRequestedAt: ContinuousClock.Instant?
    private var recordingStartedAt: ContinuousClock.Instant?
    private var watchdogTask: Task<Void, Never>?
    private var pressStartedSession = false
    private var cancelRequested = false
    /// 確定処理に入ったか。watchdog とセッションタスクの二重実行を防ぐ。
    private var finalizationHandled = false
    private var saveVoiceMemo: ((String) async -> Void)?
    private var voiceMemoFinished: (() -> Void)?
    private var pendingPersistenceCount = 0

    public init(dependencies: Dependencies) {
        self.deps = dependencies
        refreshResolvedMode()
    }

    /// 効果音の出力経路を温める。起動時に一度呼ぶ(押下時に 180ms 払わないため)。
    public func prewarmSounds() {
        sounds.prewarm()
    }

    // MARK: 入力

    public func handle(hotkey event: HotkeyPhysicalEvent) {
        let interpreter = HotkeyGestureInterpreter(holdThreshold: deps.settings.holdThreshold)
        let intent = interpreter.intent(
            for: event,
            isRecording: isRecording,
            pressStartedSession: pressStartedSession
        )
        logHotkey(event: event, intent: intent)

        switch intent {
        case .start:
            // 処理中で開始できなかった場合に押下状態を残すと、次の離上判定が狂う。
            pressStartedSession = start(trigger: .toggle)
        case .stopAndProcess:
            if case .released(let held) = event {
                // 実際にトグルだったか PTT だったかは、離した時点で初めて確定する。
                draft?.setTrigger(interpreter.trigger(forHeldFor: held))
            }
            pressStartedSession = false
            stop()
        case .ignore:
            if case .released = event { pressStartedSession = isRecording ? pressStartedSession : false }
        }
    }

    /// メニューやボタンからの開始・停止。
    public func toggleFromUI() {
        if isRecording {
            draft?.setTrigger(.manual)
            stop()
        } else {
            pressStartedSession = false
            start(trigger: .manual)
        }
    }

    /// - Returns: 実際に録音を開始したか。処理中は開始しない。
    @discardableResult
    public func start(trigger: DictationTrigger) -> Bool {
        guard !phase.isActive else {
            KoeLog.session.info("処理中のため録音を開始しませんでした")
            return false
        }
        captureDestination = .dictation
        activityLabel = nil
        saveVoiceMemo = nil
        voiceMemoFinished = nil
        lingerTask?.cancel()
        unloadTask?.cancel()
        cancelRequested = false
        statusDetail = nil
        liveTranscript = ""
        levelHistory = Array(repeating: 0, count: Self.levelHistoryLength)
        inputLevel = 0
        recordingElapsed = .zero
        // 前回のデバイス名を残さない。次の録音で実際に束ねたものだけを出す。
        inputDeviceName = nil

        let target = frontmost.target
        targetApp = frontmost.current

        let modes = deps.modes()
        let mode = ModeResolver.resolve(bundleID: target.bundleID, modes: modes, overrideID: pinnedModeID)
            ?? BuiltinModes.defaultMode
        let vocabulary = deps.vocabulary().filter(\.enabled)
        let systemPrompt = FormattingPolicy.systemPrompt(
            sharedRules: deps.sharedRules(),
            mode: mode,
            vocabulary: vocabulary
        )

        let sttEngine = deps.engines.stt
        let llmEngine = deps.engines.llm

        let context = SessionContext(
            appBundleID: target.bundleID,
            appName: target.name,
            mode: mode,
            systemPrompt: systemPrompt,
            vocabularyCount: vocabulary.count,
            sttEngine: sttEngine.identifier,
            sttModel: sttEngine.modelName,
            llmEngine: llmEngine.identifier,
            llmModel: llmEngine.modelName,
            trigger: trigger
        )

        var draft = SessionDraft(context: context)
        draft.setTrigger(trigger)
        self.draft = draft
        activeMode = mode
        phase = .recording
        recordingStartedAt = ContinuousClock.now
        stopRequestedAt = nil
        sounds.isEnabled = deps.settings.soundsEnabled
        sounds.volume = Float(deps.settings.soundVolume)
        sounds.play(.start)

        let hints = SttHints(
            contextualStrings: FormattingPolicy.contextualStrings(vocabulary),
            vocabularyPrompt: FormattingPolicy.vocabularyHint(vocabulary),
            languagePreference: mode.languagePreference
        )

        startElapsedTimer()
        finalizationHandled = false
        sessionTask = Task { [weak self] in
            await self?.runSession(engine: sttEngine, llm: llmEngine, hints: hints, vocabulary: vocabulary)
        }
        return true
    }

    /// 音声入力のcaptureとSTTだけを使い、確定textをlife-log memoへ渡す。
    /// SessionDraftを作らないため、履歴・LLM整形・前面app挿入へは到達しない。
    @discardableResult
    public func startVoiceMemo(
        onRecognized: @escaping (String) async -> Void,
        onFinished: @escaping () -> Void
    ) -> Bool {
        guard !phase.isActive else {
            KoeLog.session.info("処理中のためボイスメモを開始しませんでした")
            return false
        }
        lingerTask?.cancel()
        unloadTask?.cancel()
        cancelRequested = false
        statusDetail = nil
        liveTranscript = ""
        levelHistory = Array(repeating: 0, count: Self.levelHistoryLength)
        inputLevel = 0
        recordingElapsed = .zero
        inputDeviceName = nil
        draft = nil
        targetApp = nil
        activeMode = nil
        captureDestination = .voiceMemo
        activityLabel = "ボイスメモ"
        saveVoiceMemo = onRecognized
        voiceMemoFinished = onFinished
        phase = .recording
        recordingStartedAt = ContinuousClock.now
        stopRequestedAt = nil
        sounds.isEnabled = deps.settings.soundsEnabled
        sounds.volume = Float(deps.settings.soundVolume)
        sounds.play(.start)

        let vocabulary = deps.vocabulary().filter(\.enabled)
        let hints = SttHints(
            contextualStrings: FormattingPolicy.contextualStrings(vocabulary),
            vocabularyPrompt: FormattingPolicy.vocabularyHint(vocabulary),
            languagePreference: .auto
        )
        startElapsedTimer()
        finalizationHandled = false
        sessionTask = Task { [weak self] in
            guard let self else { return }
            await self.runSession(
                engine: self.deps.engines.stt,
                llm: self.deps.engines.llm,
                hints: hints,
                vocabulary: vocabulary
            )
        }
        return true
    }

    public var isVoiceMemoRecording: Bool {
        captureDestination == .voiceMemo && isRecording
    }

    public func stop() {
        guard isRecording else { return }
        stopRequestedAt = ContinuousClock.now
        phase = .recognizing
        draft?.beginRecognizing()
        elapsedTask?.cancel()
        sounds.play(.stop)
        // ストリームを閉じる = エンジンへの「録音停止」の合図。
        audio.stop()
        startFinalizationWatchdog()
    }

    /// 終了時は録音を止め、既に得られたraw/partial textを保存してLLM・挿入を打ち切る。
    public func interruptForTermination(timeout: Duration = .seconds(3)) async {
        if isRecording { stop() }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while isBusy, clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
        }
        if isBusy {
            cancelRequested = true
            sessionTask?.cancel()
            audio.stop()
            if captureDestination == .dictation, var draft {
                let partial = draft.partialTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !partial.isEmpty {
                    let record = draft.finalizeTranscript(
                        partial,
                        language: LanguageDetector.detect(partial),
                        sttLatencyMs: 0,
                        audioDurationMs: audio.capturedDurationMs
                    )
                    self.draft = draft
                    persist(record)
                }
            }
            finish(phase: .finished(.cancelled), detail: "終了のため処理を中断しました")
        }
        await flushPersistence(timeout: .seconds(2))
    }

    /// STT が確定を返さないまま止まった場合の保険。
    private func startFinalizationWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(for: Self.finalizationTimeout)
            guard let self, !Task.isCancelled, phase == .recognizing, !finalizationHandled else { return }
            KoeLog.session.error("STT が確定を返さないため打ち切ります")
            await salvageStalledRecognition()
        }
    }

    /// 認識が返ってこないので、暫定テキストで先へ進める(発話を失わない)。
    private func salvageStalledRecognition() async {
        guard !finalizationHandled else { return }
        finalizationHandled = true
        sessionTask?.cancel()
        levelTask?.cancel()

        let salvaged = (draft?.partialTranscript ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let voiceMemoSalvaged = liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if captureDestination == .voiceMemo, !voiceMemoSalvaged.isEmpty {
            statusDetail = "音声認識が応答しないため、途中までのテキストを使いました"
            await completeVoiceMemo(voiceMemoSalvaged, alreadyHandled: true)
            return
        }
        guard !salvaged.isEmpty else {
            sounds.play(.failure)
            finish(phase: .finished(.failed("音声認識が応答しませんでした")), detail: nil)
            return
        }

        statusDetail = "音声認識が応答しないため、途中までのテキストを使いました"
        do {
            try await complete(
                transcript: salvaged,
                language: LanguageDetector.detect(salvaged),
                llm: deps.engines.llm,
                alreadyHandled: true
            )
        } catch {
            await fail(error)
        }
    }

    /// 破棄キャンセル(FR-1.4)。挿入はしないが、認識済みテキストは履歴に残す。
    public func cancel() {
        guard phase.isActive else { return }
        cancelRequested = true
        finalizationHandled = true
        elapsedTask?.cancel()
        levelTask?.cancel()
        watchdogTask?.cancel()
        audio.stop()
        sessionTask?.cancel()
        sounds.play(.cancel)

        if var draft {
            let record = draft.markCancelled()
            self.draft = draft
            if let record { persist(record) }
        }
        finish(phase: .finished(.cancelled), detail: nil)
    }

    /// スリープに持ち越したマイク入力は復帰後に信頼できないため、現在の短い口述だけを閉じる。
    public func systemWillSleep() {
        if phase.isActive { cancel() }
    }

    // MARK: パイプライン

    private func runSession(
        engine: any SttEngine,
        llm: any LlmEngine,
        hints: SttHints,
        vocabulary: [VocabularyEntry]
    ) async {
        do {
            // 初回はここで OS のマイク許可ダイアログが出る。
            if !Permissions.isMicrophoneGranted, await !Permissions.requestMicrophone() {
                sounds.play(.failure)
                finish(phase: .finished(.failed(AudioCapture.Failure.microphoneDenied.localizedDescription)), detail: nil)
                return
            }
            let format = try await deps.engines.captureFormat(hints: hints)
            // 初回だけ prepare を待つため、その間に離してしまうケースを弾く。
            guard isRecording else {
                finish(phase: .finished(.failed("録音の準備が間に合いませんでした")), detail: nil)
                return
            }
            let streams = try audio.start(format: format)
            inputDeviceName = audio.inputDeviceName
            startLevelPump(streams.levels)

            var finalText: String?
            var language: RecognizedLanguage = .unknown

            for try await event in engine.transcribe(audio: streams.chunks, hints: hints) {
                switch event {
                case .partial(let text):
                    draft?.updatePartial(text)
                    liveTranscript = text
                case .segment:
                    break
                case .sessionFinished(let text, let detected):
                    finalText = text
                    language = detected
                }
            }

            guard !cancelRequested else { return }
            levelTask?.cancel()
            inputLevel = 0

            let transcript = (finalText ?? liveTranscript).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !transcript.isEmpty else {
                finish(phase: .finished(.failed("音声を認識できませんでした")), detail: nil)
                sounds.play(.failure)
                return
            }

            if captureDestination == .voiceMemo {
                await completeVoiceMemo(transcript)
                return
            }

            try await complete(transcript: transcript, language: language, llm: llm)
        } catch is CancellationError {
            return
        } catch {
            await fail(error)
        }
    }

    private func completeVoiceMemo(_ transcript: String, alreadyHandled: Bool = false) async {
        if !alreadyHandled {
            guard !finalizationHandled else { return }
            finalizationHandled = true
        }
        watchdogTask?.cancel()
        liveTranscript = transcript
        await saveVoiceMemo?(transcript)
        sounds.play(.complete)
        finish(phase: .finished(.completed), detail: statusDetail ?? "メモに追加しました")
    }

    /// ★ ここから先は「発話を失わない」経路。
    private func complete(
        transcript: String,
        language: RecognizedLanguage,
        llm: any LlmEngine,
        alreadyHandled: Bool = false
    ) async throws {
        if !alreadyHandled {
            guard !finalizationHandled else { return }
            finalizationHandled = true
        }
        watchdogTask?.cancel()
        guard var draft else { return }

        let stopAt = stopRequestedAt ?? ContinuousClock.now
        let sttLatency = elapsedMs(since: stopAt)
        logInputDiagnostics(transcriptLength: transcript.count)

        // 永続化を整形より先に行う。ここまで来れば、以降の失敗でテキストは失われない。
        var record = draft.finalizeTranscript(
            transcript,
            language: language,
            sttLatencyMs: sttLatency,
            audioDurationMs: audio.capturedDurationMs
        )
        self.draft = draft
        liveTranscript = transcript
        persist(record)

        phase = .formatting

        // 語彙は STT のバイアスと整形プロンプトの語彙表として効かせる。
        // Koe 自身は文字列を書き換えないので、整形できなかったときは生テキストがそのまま出る(C-43)。
        do {
            let started = ContinuousClock.now
            let prompt = FormattingPrompt(
                system: draft.context.systemPrompt,
                user: FormattingPolicy.userPrompt(transcript: transcript)
            )
            do {
                let output = try await llm.complete(prompt: prompt, timeout: deps.settings.formattingTimeout)
                let latency = elapsedMs(since: started)
                switch FormattingPolicy.validate(output: output, input: transcript) {
                case .success(let formatted):
                    record = draft.markFormatted(formatted, llmLatencyMs: latency) ?? record
                case .failure(let rejection):
                    record = draft.markFormattingSkipped(
                        reason: rejection.message,
                        llmLatencyMs: latency
                    ) ?? record
                    statusDetail = "整形をスキップしました(\(rejection.message))"
                }
            } catch {
                let latency = elapsedMs(since: started)
                let reason = error.localizedDescription
                record = draft.markFormattingSkipped(
                    reason: reason,
                    llmLatencyMs: latency
                ) ?? record
                statusDetail = "整形をスキップしました(\(reason))"
            }
        }
        self.draft = draft
        persist(record)

        guard !cancelRequested else { return }

        phase = .inserting
        let text = record.resultText
        do {
            try await TextInserter.insert(text, into: targetApp)
            record = draft.markInserted(insertLatencyMs: elapsedMs(since: stopAt)) ?? record
            self.draft = draft
            persist(record)
            sounds.play(.complete)
            finish(phase: draft.phase, detail: statusDetail)
        } catch {
            // 挿入できなくても結果は残す(FR-5.3)。
            TextInserter.copyToClipboard(text)
            record = draft.markClipboardOnly(reason: error.localizedDescription) ?? record
            self.draft = draft
            persist(record)
            sounds.play(.failure)
            statusDetail = "\(error.localizedDescription)。クリップボードにコピーしました"
            finish(phase: draft.phase, detail: statusDetail)
        }
    }

    private func fail(_ error: any Error) async {
        let message = error.localizedDescription
        KoeLog.session.error("セッションが失敗: \(message, privacy: .public)")
        if var draft {
            let record = draft.markFailed(message)
            self.draft = draft
            if let record { persist(record) }
        }
        sounds.play(.failure)
        finish(phase: .finished(.failed(message)), detail: message)

        // 次の録音も同じ理由で必ず失敗するので、待たずに畳む。
        if case EngineError.needsAppRestart = error { deps.onNeedsAppRestart() }
    }

    private func finish(phase newPhase: SessionPhase, detail: String?) {
        phase = newPhase
        statusDetail = detail ?? statusDetail
        inputLevel = 0
        levelTask?.cancel()
        elapsedTask?.cancel()
        watchdogTask?.cancel()
        audio.stop()
        pressStartedSession = false
        refreshResolvedMode()
        let didFinishVoiceMemo = captureDestination == .voiceMemo ? voiceMemoFinished : nil
        saveVoiceMemo = nil
        voiceMemoFinished = nil
        captureDestination = .dictation
        didFinishVoiceMemo?()
        scheduleLinger()
        scheduleIdleUnload()
    }

    private func persist(_ record: SessionRecord) {
        lastRecord = record
        deps.onRecordChanged(record)
        guard let history = deps.historyStore() else {
            KoeLog.persistence.error("履歴 DB が未初期化のため保存できませんでした")
            return
        }
        pendingPersistenceCount += 1
        Task(priority: .utility) {
            // 保存に失敗しても挿入は止めない。失敗自体はログで見えるようにする。
            do {
                try await history.save(record)
                // ライフログは保存済み履歴を投影するため、commit後にも更新を通知する。
                self.deps.onRecordChanged(record)
            } catch {
                KoeLog.persistence.error("履歴の保存に失敗: \(error.localizedDescription, privacy: .public)")
            }
            self.pendingPersistenceCount -= 1
        }
    }

    private func flushPersistence(timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while pendingPersistenceCount > 0, clock.now < deadline {
            do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
        }
    }

    // MARK: 付帯処理

    private func startLevelPump(_ levels: AsyncStream<Float>) {
        levelTask?.cancel()
        levelTask = Task { [weak self] in
            for await level in levels {
                guard let self else { return }
                inputLevel = level
                levelHistory.removeFirst()
                levelHistory.append(level)
            }
        }
    }

    private func startElapsedTimer() {
        elapsedTask?.cancel()
        elapsedTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let started = recordingStartedAt else { return }
                recordingElapsed = ContinuousClock.now - started
            }
        }
    }

    /// 終了表示を少し残してから消す(FR-8.3)。
    ///
    /// 残す長さは終わり方で決める。うまく挿入できたなら読むものは無いので即座に引く。
    private func scheduleLinger() {
        lingerTask?.cancel()
        let linger = Self.lingerDuration(for: phase, detail: statusDetail)
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: linger)
            guard let self, !Task.isCancelled else { return }
            if case .finished = phase {
                phase = .idle
                liveTranscript = ""
                activityLabel = nil
            }
        }
    }

    static func lingerDuration(for phase: SessionPhase, detail: String?) -> Duration {
        guard case .finished(let outcome) = phase else { return hudSuccessLingerDuration }
        switch outcome {
        case .completed, .cancelled:
            // 注記が残っているなら読む時間が要る(整形スキップなど)。
            return detail == nil ? hudSuccessLingerDuration : hudNoticeLingerDuration
        case .formattingSkipped, .clipboardOnly, .failed:
            return hudNoticeLingerDuration
        }
    }

    private func scheduleIdleUnload() {
        unloadTask?.cancel()
        let engines = deps.engines
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10 * 60))
            guard let self, !Task.isCancelled, !phase.isActive else { return }
            await engines.unloadAll()
        }
    }

    private func refreshResolvedMode() {
        let modes = deps.modes()
        previewMode = ModeResolver.resolve(
            bundleID: frontmost.target.bundleID,
            modes: modes,
            overrideID: pinnedModeID
        )
    }

    /// メニューから開いたときなど、表示前に最新の解決結果に更新する。
    public func refreshPreview() {
        refreshResolvedMode()
    }

    /// ホットキーの解釈を後から追えるようにする(トグル/長押しの判定ずれの切り分け用)。
    private func logHotkey(event: HotkeyPhysicalEvent, intent: HotkeyIntent) {
        let description: String
        switch event {
        case .pressed:
            description = "押下"
        case .released(let held):
            let ms = held.components.seconds * 1_000 + held.components.attoseconds / 1_000_000_000_000_000
            description = "離上 \(ms)ms (閾値 \(deps.settings.holdThresholdMs)ms)"
        }
        KoeLog.hotkey.info(
            "\(description, privacy: .public) → \(String(describing: intent), privacy: .public) recording=\(self.isRecording, privacy: .public)"
        )
    }

    /// 設定画面で「いま使っているアプリを対象に追加」するための情報。
    public var frontmostBundleID: String? { frontmost.target.bundleID }
    public var frontmostAppName: String? { frontmost.target.name }

    #if DEBUG
    /// SwiftUI プレビュー・レイアウト確認用の状態を直接流し込む。
    public func applyPreviewState(
        phase: SessionPhase,
        transcript: String = "",
        mode: Mode? = nil,
        levels: [Float]? = nil,
        elapsed: Duration = .zero,
        detail: String? = nil,
        inputDeviceName: String? = nil
    ) {
        self.phase = phase
        liveTranscript = transcript
        activeMode = mode
        recordingElapsed = elapsed
        statusDetail = detail
        self.inputDeviceName = inputDeviceName
        if let levels { levelHistory = levels }
        inputLevel = levels?.last ?? 0
    }
    #endif


    /// 入力が本当に来ていたかを後から追えるようにする(発話内容は残さない)。
    private func logInputDiagnostics(transcriptLength: Int) {
        let peak = String(format: "%.3f", audio.lastPeakLevel)
        KoeLog.session.info(
            "録音完了 chunks=\(self.audio.lastChunkCount, privacy: .public) peak=\(peak, privacy: .public) duration=\(self.audio.capturedDurationMs, privacy: .public)ms chars=\(transcriptLength, privacy: .public)"
        )
    }

    private func elapsedMs(since instant: ContinuousClock.Instant) -> Int {
        let duration = ContinuousClock.now - instant
        return Int(duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }
}
