import AppKit
import Foundation
import Observation

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
        public var vocabulary: @MainActor () -> [VocabularyEntry]
        public var onRecordChanged: @MainActor (SessionRecord) -> Void

        public init(
            settings: AppSettings,
            engines: EngineRegistry,
            historyStore: @MainActor @escaping () -> HistoryStore?,
            modes: @MainActor @escaping () -> [Mode],
            vocabulary: @MainActor @escaping () -> [VocabularyEntry],
            onRecordChanged: @MainActor @escaping (SessionRecord) -> Void
        ) {
            self.settings = settings
            self.engines = engines
            self.historyStore = historyStore
            self.modes = modes
            self.vocabulary = vocabulary
            self.onRecordChanged = onRecordChanged
        }
    }

    /// HUD 用の波形バッファ長。
    static let levelHistoryLength = 64
    static let hudLingerDuration: Duration = .seconds(2)
    /// 停止後、STT の確定をここまで待つ。超えたら打ち切って途中のテキストを使う。
    /// エンジンが応答しないときに「認識中」から永遠に戻らないための保険。
    static let finalizationTimeout: Duration = .seconds(60)

    // MARK: 観測される状態

    public private(set) var phase: SessionPhase = .idle
    public private(set) var liveTranscript = ""
    public private(set) var inputLevel: Float = 0
    public private(set) var levelHistory: [Float] = Array(repeating: 0, count: levelHistoryLength)
    public private(set) var activeMode: Mode?
    public private(set) var recordingElapsed: Duration = .zero
    public private(set) var lastRecord: SessionRecord?
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

    public init(dependencies: Dependencies) {
        self.deps = dependencies
        refreshResolvedMode()
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
        lingerTask?.cancel()
        unloadTask?.cancel()
        cancelRequested = false
        statusDetail = nil
        liveTranscript = ""
        levelHistory = Array(repeating: 0, count: Self.levelHistoryLength)
        inputLevel = 0
        recordingElapsed = .zero

        let target = frontmost.target
        targetApp = frontmost.current

        let modes = deps.modes()
        let mode = ModeResolver.resolve(bundleID: target.bundleID, modes: modes, overrideID: pinnedModeID)
            ?? BuiltinModes.defaultMode
        let vocabulary = deps.vocabulary().filter(\.enabled)
        let systemPrompt = FormattingPolicy.systemPrompt(mode: mode, vocabulary: vocabulary)

        let sttID = deps.settings.sttEngineID
        let sttEngine = deps.engines.sttEngine(sttID)
        let llmEngine = deps.engines.llmEngine(deps.settings.llmEngineID)

        let context = SessionContext(
            appBundleID: target.bundleID,
            appName: target.name,
            mode: mode,
            systemPrompt: systemPrompt,
            vocabularyCount: vocabulary.count,
            sttEngine: sttEngine.identifier,
            sttModel: sttEngine.modelName,
            llmEngine: llmEngine?.identifier,
            llmModel: llmEngine?.modelName,
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
                llm: deps.engines.llmEngine(deps.settings.llmEngineID),
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

    // MARK: パイプライン

    private func runSession(
        engine: any SttEngine,
        llm: (any LlmEngine)?,
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
            let format = try await deps.engines.captureFormat(for: engine.identifier, hints: hints)
            // 初回だけ prepare を待つため、その間に離してしまうケースを弾く。
            guard isRecording else {
                finish(phase: .finished(.failed("録音の準備が間に合いませんでした")), detail: nil)
                return
            }
            let streams = try audio.start(format: format)
            startLevelPump(streams.levels)

            var finalText: String?
            var language: RecognizedLanguage = .unknown

            for try await event in engine.transcribe(audio: streams.chunks, hints: hints) {
                switch event {
                case .partial(let text):
                    draft?.updatePartial(text)
                    liveTranscript = text
                case .final(let text, let detected):
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

            try await complete(transcript: transcript, language: language, llm: llm)
        } catch is CancellationError {
            return
        } catch {
            await fail(error)
        }
    }

    /// ★ ここから先は「発話を失わない」経路。
    private func complete(
        transcript: String,
        language: RecognizedLanguage,
        llm: (any LlmEngine)?,
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

        // 語彙の誤認識は LLM より先に、決定的に直す。整形が失敗してもこの矯正だけは残る。
        let corrected = FormattingPolicy.applyVocabularyCorrections(
            to: transcript,
            vocabulary: deps.vocabulary()
        )
        let fallbackText = corrected.text

        if let llm {
            let started = ContinuousClock.now
            let prompt = FormattingPrompt(
                system: draft.context.systemPrompt,
                user: FormattingPolicy.userPrompt(transcript: corrected.text)
            )
            do {
                let output = try await llm.complete(prompt: prompt, timeout: deps.settings.formattingTimeout)
                let latency = elapsedMs(since: started)
                switch FormattingPolicy.validate(output: output, input: corrected.text) {
                case .success(let formatted):
                    record = draft.markFormatted(formatted, llmLatencyMs: latency) ?? record
                case .failure(let rejection):
                    record = draft.markFormattingSkipped(
                        reason: rejection.message,
                        fallbackText: fallbackText,
                        llmLatencyMs: latency
                    ) ?? record
                    statusDetail = "整形をスキップしました(\(rejection.message))"
                }
            } catch {
                let latency = elapsedMs(since: started)
                let reason = error.localizedDescription
                record = draft.markFormattingSkipped(
                    reason: reason,
                    fallbackText: fallbackText,
                    llmLatencyMs: latency
                ) ?? record
                statusDetail = "整形をスキップしました(\(reason))"
            }
        } else {
            record = draft.markFormattingSkipped(
                reason: "整形エンジンが利用できません",
                fallbackText: fallbackText,
                llmLatencyMs: nil
            ) ?? record
            statusDetail = "整形をスキップしました"
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
        if var draft {
            let record = draft.markFailed(message)
            self.draft = draft
            if let record { persist(record) }
        }
        sounds.play(.failure)
        finish(phase: .finished(.failed(message)), detail: message)
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
        Task.detached(priority: .utility) {
            // 保存に失敗しても挿入は止めない。失敗自体はログで見えるようにする。
            do {
                try await history.save(record)
            } catch {
                KoeLog.persistence.error("履歴の保存に失敗: \(error.localizedDescription, privacy: .public)")
            }
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

    /// 完了表示を少し残してから消す(FR-8.3)。
    private func scheduleLinger() {
        lingerTask?.cancel()
        lingerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hudLingerDuration)
            guard let self, !Task.isCancelled else { return }
            if case .finished = phase {
                phase = .idle
                liveTranscript = ""
            }
        }
    }

    private func scheduleIdleUnload() {
        unloadTask?.cancel()
        let minutes = deps.settings.modelIdleUnloadMinutes
        guard minutes > 0 else { return }
        let engines = deps.engines
        unloadTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
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
        detail: String? = nil
    ) {
        self.phase = phase
        liveTranscript = transcript
        activeMode = mode
        recordingElapsed = elapsed
        statusDetail = detail
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
