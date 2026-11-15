import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
public final class LifeLogCoordinator {
    public private(set) var isCapturing = false
    public private(set) var selectedDate = Date()
    public private(set) var day = LifeLogDay()
    /// Always the current day, whatever the main window selects. The mini window and the menu bar read it.
    public private(set) var today = LifeLogDay()
    public private(set) var errorMessage: String?
    public private(set) var availableCalendars: [String] = []
    public private(set) var highlightedTimelineItemID: String?
    public private(set) var sourceNavigationRevision = 0
    public private(set) var monthActivity: [String: LifeLogDayActivity] = [:]
    public private(set) var liveTranscript = ""
    public private(set) var isTranscribing = false
    public private(set) var isHearingSpeech = false
    public private(set) var liveSpeechStartedAt: Date?
    public private(set) var liveSpeechAudioDuration: TimeInterval = 0
    public private(set) var activeTranscriptionStartedAt: Date?
    public private(set) var activeTranscriptionAudioDuration: TimeInterval?
    public private(set) var isRecoveringCapture = false
    public private(set) var isSuspendedForVoiceMemo = false
    /// 記録意図を保ったままマイクを止めている理由。一時停止、または記録しない予定の進行中。
    public private(set) var hold: LifeLogCaptureHold?
    public private(set) var isRefreshingCalendar = false
    public private(set) var lastCalendarRefreshAt: Date?
    private var lastCalendarRefreshDay: String?

    private let capture: ContinuousAudioCapture
    private let calendarProvider = CalendarProvider()
    private var database: LoreDatabase?
    /// Called after an explicit calendar refresh of the selected day.
    @ObservationIgnored public var onCalendarRefreshed: (() -> Void)?
    private var engines: EngineRegistry?
    private var vocabulary: @MainActor () -> [VocabularyEntry] = { [] }
    private var transcriptionLanguage: @MainActor () -> LanguagePreference = { .auto }
    private var participatingEventsOnly: @MainActor () -> Bool = { true }
    private var audioProcessingCompleted: @MainActor () async -> Void = {}
    private var liveTranscriptionTask: Task<Void, Never>?
    private var livePreviewTask: Task<Void, Never>?
    private var livePreviewRevision = 0
    private var liveSessionStartedAt: Date?
    private var liveSessionID: String?
    private var liveChunks: [LifeLogAudioChunk] = []
    private var pendingLiveSegments: [(text: String, start: TimeInterval, end: TimeInterval)] = []
    private var liveFinalTranscript = ""
    private var liveRecognitionFailed = false
    private var hasLiveSegments = false
    private var transcriptionFinished = false
    private var captureFinished = false
    private var isFinalizingSession = false
    private var isStartingCapture = false
    private var vocabularyRevision = 0
    private var restartForTranscriptionConfiguration = false
    private var activeTranscriptionCount = 0
    private var captureRequested = false
    private var captureRetryAttempt = 0
    private var captureRetryTask: Task<Void, Never>?
    private var dayRolloverTask: Task<Void, Never>?
    private var followsCurrentDay = true
    private var isSuspendedForSleep = false

    nonisolated static let livePreviewInitialDelay: TimeInterval = 1.5
    nonisolated static let livePreviewRefreshInterval: TimeInterval = 1.5
    nonisolated static let livePreviewWindowDuration: TimeInterval = 5

    /// `audioRoot`はUI test bundleが利用者の音声folderへ書かないために渡す。
    public init(audioRoot: URL? = nil) {
        capture = audioRoot.map { ContinuousAudioCapture(root: $0) } ?? ContinuousAudioCapture()
        capture.onCommitted = { [weak self] chunk in await self?.commitLiveChunk(chunk) }
        capture.onFinished = { [weak self] in await self?.captureWriterFinished() }
        capture.onFailure = { [weak self] error in self?.handleCaptureFailure(error) }
        capture.onRunningChanged = { [weak self] running in self?.isCapturing = running }
    }

    public func configure(
        database: LoreDatabase,
        engines: EngineRegistry,
        vocabulary: @MainActor @escaping () -> [VocabularyEntry],
        transcriptionLanguage: @MainActor @escaping () -> LanguagePreference = { .auto },
        participatingEventsOnly: @MainActor @escaping () -> Bool,
        audioProcessingCompleted: @MainActor @escaping () async -> Void
    ) async {
        self.database = database; self.engines = engines; self.vocabulary = vocabulary
        self.transcriptionLanguage = transcriptionLanguage
        self.participatingEventsOnly = participatingEventsOnly
        self.audioProcessingCompleted = audioProcessingCompleted
        await reload()
        // 保留音声の再処理は重要だが、履歴・ライフログウィンドウの初期表示を待たせない。
        Task { await resumePending() }
    }

    public func selectInputDevice(uid: String?) {
        guard capture.inputDeviceUID != uid else { return }
        capture.inputDeviceUID = uid
        guard captureRequested, hold == nil else { return }
        isRecoveringCapture = true
        captureRetryTask?.cancel()
        captureRetryTask = nil
        if capture.isRunning {
            capture.stop()
        } else if liveTranscriptionTask == nil {
            scheduleCaptureRetry(unless: ContinuousAudioCapture.Failure.configurationChanged)
        }
    }

    public func setCaptureEnabled(_ enabled: Bool) {
        let wasRequested = captureRequested
        captureRequested = enabled
        if enabled {
            if !wasRequested { captureRetryAttempt = 0 }
            scheduleDayRollover()
            guard hold == nil, !isCapturing, liveTranscriptionTask == nil else { return }
            Task { await startLiveCapture() }
        } else {
            restartForTranscriptionConfiguration = false
            captureRetryTask?.cancel()
            captureRetryTask = nil
            isRecoveringCapture = false
            dayRolloverTask?.cancel()
            dayRolloverTask = nil
            capture.stop()
        }
    }

    /// アプリ終了時の境界。音声writer、文字起こし、DB保存が終わるまで待つ。
    /// OSや外部エンジンが応答しない場合だけ期限で打ち切り、保存済みチャンクは次回起動時に回収する。
    public func stopAndWait(timeout: Duration = .seconds(15)) async -> Bool {
        setCaptureEnabled(false)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while capture.isRunning || liveTranscriptionTask != nil {
            guard clock.now < deadline else { return false }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return true
    }

    /// Cmd-Qでは復旧可能なaudio/DB保存だけを短時間待つ。
    public func stopForTermination(timeout: Duration = .seconds(3)) async -> Bool {
        return await stopAndWait(timeout: timeout)
    }

    public var captureStatusText: String {
        if isSuspendedForVoiceMemo { return "ボイスメモ中は一時停止" }
        if isHeld { return "一時停止中" }
        if isRecoveringCapture { return "再接続中" }
        if isCapturing { return "記録中" }
        if captureRequested { return "開始準備中" }
        if isTranscribing { return "保存中" }
        return "停止中"
    }

    public var hasCaptureIntent: Bool { captureRequested }

    /// 記録意図はあるが、一時停止または予定のために録音していない。
    public var isHeld: Bool { captureRequested && hold != nil }

    /// 記録意図があり、どの中断(スリープ、ボイスメモ、hold)にも掛かっていない。
    private var mayRunCapture: Bool {
        captureRequested && !isSuspendedForSleep && !isSuspendedForVoiceMemo && hold == nil
    }

    /// 一時停止と「記録しない予定」の境界。スリープやボイスメモの中断と同じく記録意図は保ち、
    /// 現在のchunkを確定してマイクを止める。解除すると同じ意図で再開する。
    public func setHold(_ newHold: LifeLogCaptureHold?) {
        let wasHeld = hold != nil
        hold = newHold
        guard wasHeld != (newHold != nil) else { return }
        if newHold != nil {
            captureRetryTask?.cancel()
            captureRetryTask = nil
            isRecoveringCapture = false
            restartForTranscriptionConfiguration = false
            if capture.isRunning { capture.stop() }
        } else if mayRunCapture {
            captureRetryAttempt = 0
            if liveTranscriptionTask == nil {
                Task { await startLiveCapture() }
            } else {
                scheduleCaptureRetry(unless: EngineError.failed(String(lore: "前の音声ストリームを終了しています")))
            }
        }
    }

    public var liveActivityStartedAt: Date? {
        if isHearingSpeech { return liveSpeechStartedAt }
        return activeTranscriptionStartedAt ?? liveSpeechStartedAt
    }

    public var liveActivityAudioDuration: TimeInterval {
        liveSpeechStartedAt == nil
            ? (activeTranscriptionAudioDuration ?? 0)
            : liveSpeechAudioDuration
    }

    public func dismissError() {
        errorMessage = nil
    }

    /// 処理失敗ではないが利用者の操作が必要な案内を、同じdismiss可能なbannerへ出す。
    public func showNotice(_ message: String) {
        errorMessage = message
        LoreLog.session.notice("ライフログの案内: \(message, privacy: .public)")
    }

    /// 終了前に音声・文字起こし・DB保存の確定を待つ必要がある状態。
    /// 記録開始要求から実際のcapture開始までの隙間も含める。
    public var hasPendingTerminationWork: Bool {
        captureRequested || capture.isRunning || liveTranscriptionTask != nil || isFinalizingSession
    }

    /// STTの語彙contextは解析開始時に固定されるため、録音意図を保ったまま
    /// 現在の認識sessionを確定し、次のsessionから更新済み語彙へ切り替える。
    public func vocabularyDidChange() {
        vocabularyRevision += 1
        requestTranscriptionRestartIfNeeded(reason: "語彙変更")
    }

    public func transcriptionConfigurationDidChange() {
        requestTranscriptionRestartIfNeeded(reason: "音声認識設定変更")
    }

    private func requestTranscriptionRestartIfNeeded(reason: String) {
        guard captureRequested else { return }
        guard capture.isRunning || liveTranscriptionTask != nil else { return }
        guard !restartForTranscriptionConfiguration else { return }
        restartForTranscriptionConfiguration = true
        isRecoveringCapture = true
        LoreLog.session.info("\(reason, privacy: .public)を反映するためライフログ解析streamを切り替えます")
        if capture.isRunning {
            capture.stop()
        }
    }

    /// スリープ前に音声ファイルとSTT入力を閉じ、復帰後は同じ記録意図で再開する。
    public func systemWillSleep() {
        isSuspendedForSleep = true
        guard captureRequested else { return }
        captureRetryTask?.cancel()
        captureRetryTask = nil
        isRecoveringCapture = true
        capture.stop()
    }

    public func systemDidWake() {
        guard isSuspendedForSleep else { return }
        isSuspendedForSleep = false
        guard mayRunCapture else {
            isRecoveringCapture = false
            return
        }
        captureRetryAttempt = 0
        scheduleCaptureRetry(unless: EngineError.failed(String(lore: "スリープから復帰しました")))
    }

    /// ボイスメモの音声をlife-log utteranceへ取り込まないための排他境界。
    /// 記録開始意図は維持し、現在のchunkと認識sessionだけを確定する。
    public func suspendForVoiceMemo(timeout: Duration = .seconds(15)) async -> Bool {
        isSuspendedForVoiceMemo = true
        captureRetryTask?.cancel()
        captureRetryTask = nil
        isRecoveringCapture = false
        if capture.isRunning {
            capture.stop()
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while capture.isRunning || liveTranscriptionTask != nil || isFinalizingSession || isStartingCapture {
            guard clock.now < deadline else {
                fail(EngineError.failed(String(lore: "ライフログの一時停止を完了できませんでした")))
                return false
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return true
    }

    public func resumeAfterVoiceMemo() {
        guard isSuspendedForVoiceMemo else { return }
        isSuspendedForVoiceMemo = false
        guard mayRunCapture else { return }
        captureRetryAttempt = 0
        scheduleCaptureRetry(unless: EngineError.failed(String(lore: "ボイスメモが終了しました")))
    }

    private func startLiveCapture() async {
        guard mayRunCapture, !isStartingCapture, let engines else { return }
        isStartingCapture = true
        defer { isStartingCapture = false }
        do {
            let startingVocabularyRevision = vocabularyRevision
            let enabledVocabulary = vocabulary().filter(\.enabled)
            let hints = SttHints(
                contextualStrings: FormattingPolicy.contextualStrings(enabledVocabulary),
                vocabularyPrompt: FormattingPolicy.vocabularyHint(enabledVocabulary),
                languagePreference: transcriptionLanguage()
            )
            let stt = engines.lifeLogStt
            let format = try await stt.prepare(hints: hints) ?? AudioFormats.canonical
            guard mayRunCapture else { return }
            let startedAt = Date()
            let stream = try capture.start(format: format)
            liveSessionStartedAt = startedAt
            liveSessionID = UUID().uuidString
            liveChunks = []
            pendingLiveSegments = []
            liveFinalTranscript = ""
            liveTranscript = ""
            isHearingSpeech = false
            liveSpeechStartedAt = nil
            liveSpeechAudioDuration = 0
            liveRecognitionFailed = false
            hasLiveSegments = false
            transcriptionFinished = false
            captureFinished = false
            isRecoveringCapture = false
            isTranscribing = true
            liveTranscriptionTask = Task { [weak self] in
                await self?.consumeAdaptiveAudio(stream, hints: hints, stt: stt)
            }
            if vocabularyRevision != startingVocabularyRevision {
                requestTranscriptionRestartIfNeeded(reason: "語彙変更")
            }
        } catch {
            fail(error)
            scheduleCaptureRetry(unless: error)
        }
    }

    private func scheduleDayRollover() {
        guard dayRolloverTask == nil else { return }
        dayRolloverTask = Task { [weak self] in
            while !Task.isCancelled {
                let now = Date()
                guard let nextDay = Calendar.current.date(byAdding: .day, value: 1,
                                                          to: Calendar.current.startOfDay(for: now)) else { return }
                do { try await Task.sleep(for: .seconds(max(1, nextDay.timeIntervalSince(now)))) } catch { return }
                guard let self, self.captureRequested else { return }
                let newDay = Date()
                if self.followsCurrentDay { self.selectedDate = newDay }
                await self.reload()
                if self.followsCurrentDay { await self.loadActivity(containing: newDay) }
            }
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        fail(error)
        scheduleCaptureRetry(unless: error)
    }

    private func scheduleCaptureRetry(unless error: Error) {
        guard mayRunCapture, Self.shouldRetryCapture(after: error) else { return }
        captureRetryTask?.cancel()
        isRecoveringCapture = true
        captureRetryAttempt += 1
        let delay = min(30, [1, 2, 5, 10, 20, 30][min(captureRetryAttempt - 1, 5)])
        captureRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.captureRequested else { return }
            if self.liveTranscriptionTask != nil {
                self.scheduleCaptureRetry(unless: EngineError.failed(String(lore: "前の音声ストリームを終了しています")))
            } else {
                await self.startLiveCapture()
            }
        }
    }

    private func consumeAdaptiveAudio(
        _ audio: AsyncStream<AudioChunk>,
        hints: SttHints,
        stt: any SttEngine
    ) async {
        var segmenter = AdaptiveSpeechSegmenter()
        var preRoll: [AudioChunk] = []
        var burst: [AudioChunk] = []
        var lastVoicedIndex = 0
        var lastPreviewDuration: TimeInterval?
        var hasQualifiedBurst = false

        for await chunk in audio {
            if Task.isCancelled { break }
            let duration = Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            let level = AudioCapture.rootMeanSquare(of: chunk.buffer)
            let wasVoiced = segmenter.isActive && segmenter.considersSpeech(level: level)
            switch segmenter.consume(level: level, duration: duration) {
            case .ignore:
                preRoll.append(chunk)
                Self.trimPreRoll(&preRoll, maximumDuration: 1)
            case .started:
                burst = preRoll + [chunk]
                preRoll = []
                lastVoicedIndex = burst.endIndex
            case .buffer:
                burst.append(chunk)
                if wasVoiced {
                    lastVoicedIndex = burst.endIndex
                }
                if let evidence = segmenter.currentBurstEvidence,
                   evidence.isTranscriptionCandidate {
                    if !hasQualifiedBurst {
                        hasQualifiedBurst = true
                        beginLiveSpeechActivity()
                    }
                    updateLiveSpeechActivity(duration: evidence.burstDuration)
                    if Self.shouldScheduleLivePreview(
                        evidence: evidence,
                        lastPreviewDuration: lastPreviewDuration,
                        previewInProgress: livePreviewTask != nil,
                        engineIdentifier: stt.identifier
                    ) {
                        lastPreviewDuration = evidence.burstDuration
                        scheduleLivePreview(Self.trailingBuffers(
                            from: burst,
                            maximumDuration: Self.livePreviewWindowDuration
                        ), hints: hints, stt: stt)
                    }
                }
            case .flush:
                burst.append(chunk)
                isHearingSpeech = false
                await cancelLivePreview()
                if segmenter.completedBurstEvidence?.isTranscriptionCandidate == true {
                    let recognitionBuffers = Self.trimmingTrailingSilence(
                        from: burst,
                        lastVoicedIndex: lastVoicedIndex,
                        retainedDuration: 0.5
                    )
                    capture.checkpoint()
                    await recognizeBurst(recognitionBuffers, hints: hints, stt: stt)
                }
                finishLiveSpeechActivity()
                burst = []
                lastVoicedIndex = 0
                lastPreviewDuration = nil
                hasQualifiedBurst = false
            }
        }
        if segmenter.finish(), !burst.isEmpty {
            isHearingSpeech = false
            await cancelLivePreview()
            if segmenter.completedBurstEvidence?.isTranscriptionCandidate == true {
                let recognitionBuffers = Self.trimmingTrailingSilence(
                    from: burst,
                    lastVoicedIndex: lastVoicedIndex,
                    retainedDuration: 0.5
                )
                capture.checkpoint()
                await recognizeBurst(recognitionBuffers, hints: hints, stt: stt)
            }
            finishLiveSpeechActivity()
        } else {
            await cancelLivePreview()
            finishLiveSpeechActivity()
        }
        transcriptionFinished = true
        await finishLiveSessionIfReady()
    }

    private func recognizeBurst(_ buffers: [AudioChunk], hints: SttHints, stt: any SttEngine) async {
        guard let first = buffers.first, let last = buffers.last else { return }
        let sampleRate = first.buffer.format.sampleRate
        let burstStartOffset = Double(first.frameOffset) / sampleRate
        let burstEndOffset = Double(last.frameOffset + AVAudioFramePosition(last.buffer.frameLength)) / sampleRate
        do {
            try await waitUntilAudioIsCommitted(through: burstEndOffset)
        } catch {
            liveRecognitionFailed = true
            fail(error)
            return
        }
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        for buffer in buffers { continuation.yield(buffer) }
        continuation.finish()
        var burstHasSegments = false
        beginActiveTranscription(audioDuration: burstEndOffset - burstStartOffset)
        defer { endActiveTranscription() }
        do {
            for try await event in stt.transcribe(audio: stream, hints: hints) {
                switch event {
                case .partial(let text):
                    liveTranscript = text
                case .segment(let text, let start, let end):
                    burstHasSegments = true
                    pendingLiveSegments.append((text, burstStartOffset + start, burstStartOffset + end))
                    liveTranscript = text
                    await flushLiveSegments()
                case .sessionFinished(let text, _):
                    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !value.isEmpty {
                        liveFinalTranscript += (liveFinalTranscript.isEmpty ? "" : " ") + value
                        liveTranscript = value
                        if !burstHasSegments {
                            pendingLiveSegments.append((value, burstStartOffset, burstEndOffset))
                            await flushLiveSegments()
                        }
                    }
                }
            }
        } catch {
            liveRecognitionFailed = true
            fail(error)
        }
    }

    private func beginLiveSpeechActivity() {
        isHearingSpeech = true
        liveSpeechStartedAt = Date()
        liveSpeechAudioDuration = 0
        liveTranscript = ""
    }

    private func updateLiveSpeechActivity(duration: TimeInterval) {
        liveSpeechAudioDuration = max(0, duration)
    }

    private func finishLiveSpeechActivity() {
        isHearingSpeech = false
        liveSpeechStartedAt = nil
        liveSpeechAudioDuration = 0
        liveTranscript = ""
    }

    private func scheduleLivePreview(
        _ buffers: [AudioChunk],
        hints: SttHints,
        stt: any SttEngine
    ) {
        guard livePreviewTask == nil else { return }
        livePreviewRevision += 1
        let revision = livePreviewRevision
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        for buffer in buffers { continuation.yield(buffer) }
        continuation.finish()
        livePreviewTask = Task { [weak self] in
            defer {
                if self?.livePreviewRevision == revision {
                    self?.livePreviewTask = nil
                }
            }
            do {
                var preview = ""
                for try await event in stt.transcribe(audio: stream, hints: hints) {
                    switch event {
                    case .partial(let text), .sessionFinished(let text, _):
                        preview = text
                    case .segment:
                        break
                    }
                }
                guard !Task.isCancelled else { return }
                self?.applyLivePreview(preview, revision: revision)
            } catch EngineError.cancelled {
                // A newer rolling window or the authoritative final pass superseded this preview.
            } catch is CancellationError {
                // A newer rolling window or the authoritative final pass superseded this preview.
            } catch {
                LoreLog.engine.error("ライフログ暫定文字起こしに失敗: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyLivePreview(_ text: String, revision: Int) {
        guard revision == livePreviewRevision, isHearingSpeech else { return }
        liveTranscript = text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cancelLivePreview() async {
        livePreviewRevision += 1
        let task = livePreviewTask
        livePreviewTask = nil
        task?.cancel()
        await task?.value
    }

    nonisolated static func shouldScheduleLivePreview(
        evidence: SpeechBurstEvidence,
        lastPreviewDuration: TimeInterval?,
        previewInProgress: Bool,
        engineIdentifier: EngineIdentifier
    ) -> Bool {
        guard engineIdentifier == .whisperCpp,
              !previewInProgress,
              evidence.isTranscriptionCandidate,
              evidence.burstDuration >= livePreviewInitialDelay else { return false }
        guard let lastPreviewDuration else { return true }
        return evidence.burstDuration - lastPreviewDuration >= livePreviewRefreshInterval
    }

    private nonisolated static func trailingBuffers(
        from buffers: [AudioChunk],
        maximumDuration: TimeInterval
    ) -> [AudioChunk] {
        var start = buffers.endIndex
        var duration: TimeInterval = 0
        while start > buffers.startIndex, duration < maximumDuration {
            start = buffers.index(before: start)
            let buffer = buffers[start].buffer
            duration += Double(buffer.frameLength) / buffer.format.sampleRate
        }
        return Array(buffers[start...])
    }

    /// 認識結果が必ず復旧可能な音声を参照するよう、対象範囲のfile commitを先に待つ。
    private func waitUntilAudioIsCommitted(through offset: TimeInterval) async throws {
        guard let sessionStart = liveSessionStartedAt else {
            throw EngineError.failed(String(lore: "ライフログ音声の開始時刻を確認できません"))
        }
        let requiredDate = sessionStart.addingTimeInterval(offset)
        while (liveChunks.last?.captureEndedAt ?? .distantPast) < requiredDate.addingTimeInterval(-0.25) {
            if captureFinished {
                throw EngineError.failed(String(lore: "認識対象のライフログ音声を保存できませんでした"))
            }
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private nonisolated static func trimPreRoll(_ buffers: inout [AudioChunk], maximumDuration: TimeInterval) {
        var duration = buffers.reduce(0) { $0 + Double($1.buffer.frameLength) / $1.buffer.format.sampleRate }
        while duration > maximumDuration, buffers.count > 1 {
            let removed = buffers.removeFirst()
            duration -= Double(removed.buffer.frameLength) / removed.buffer.format.sampleRate
        }
    }

    private nonisolated static func trimmingTrailingSilence(
        from buffers: [AudioChunk],
        lastVoicedIndex: Int,
        retainedDuration: TimeInterval
    ) -> [AudioChunk] {
        guard lastVoicedIndex < buffers.count else { return buffers }
        var end = max(0, lastVoicedIndex)
        var retained: TimeInterval = 0
        while end < buffers.count, retained < retainedDuration {
            retained += Double(buffers[end].buffer.frameLength) / buffers[end].buffer.format.sampleRate
            end += 1
        }
        return Array(buffers[..<end])
    }

    private func commitLiveChunk(_ initial: LifeLogAudioChunk) async {
        guard let database else { return }
        var chunk = initial
        do {
            try await database.lifeLog.save(audioChunk: chunk)
            liveChunks.append(chunk)
            await flushLiveSegments()
            if transcriptionFinished, !liveRecognitionFailed {
                chunk.transcriptionState = .transcribed
                chunk.processingState = .extracted
                try await database.lifeLog.save(audioChunk: chunk)
            }
            await reload()
            await loadActivity(containing: chunk.captureStartedAt)
            await finishLiveSessionIfReady()
        } catch { fail(error) }
    }

    private func captureWriterFinished() async {
        captureFinished = true
        await finishLiveSessionIfReady()
    }

    private func flushLiveSegments() async {
        guard let database, let sessionStart = liveSessionStartedAt else { return }
        var remaining: [(text: String, start: TimeInterval, end: TimeInterval)] = []
        var affectedDates: [String: Date] = [:]
        for segment in pendingLiveSegments {
            let startedAt = sessionStart.addingTimeInterval(max(0, segment.start))
            let endedAt = sessionStart.addingTimeInterval(max(segment.start, segment.end))
            guard let chunk = liveChunks.first(where: {
                $0.captureStartedAt.addingTimeInterval(-0.25) <= startedAt && startedAt < $0.captureEndedAt.addingTimeInterval(0.25)
            }) else {
                remaining.append(segment)
                continue
            }
            do {
                let capturedDay = try await database.lifeLog.day(startedAt, participatingOnly: participatingEventsOnly())
                let event = capturedDay.calendarEvents.filter { $0.contains(startedAt, tolerance: 120) }
                    .min { $0.endsAt.timeIntervalSince($0.startsAt) < $1.endsAt.timeIntervalSince($1.startsAt) }
                let utterance = LifeLogUtterance(
                    id: Self.transcriptionSegmentID(
                        scopeID: "live-\(liveSessionID ?? chunk.id)",
                        startOffset: segment.start,
                        endOffset: segment.end
                    ),
                    startedAt: startedAt,
                    endedAt: min(endedAt, chunk.captureEndedAt.addingTimeInterval(120)),
                    text: segment.text,
                    audioChunkID: chunk.id,
                    calendarEventID: event?.id
                )
                try await database.lifeLog.save(utterance: utterance)
                hasLiveSegments = true
                affectedDates[LifeLogDateKey.string(for: startedAt)] = startedAt
            } catch { fail(error); remaining.append(segment) }
        }
        pendingLiveSegments = remaining
        for date in affectedDates.values {
            await refreshTimeline(for: date)
        }
    }

    private func finishLiveSessionIfReady() async {
        guard transcriptionFinished, captureFinished, !isFinalizingSession, let database else { return }
        isFinalizingSession = true
        defer { isFinalizingSession = false }
        await flushLiveSegments()
        if !hasLiveSegments,
           !liveFinalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let chunk = liveChunks.first,
           let sessionStart = liveSessionStartedAt {
            do {
                try await database.lifeLog.save(utterance: LifeLogUtterance(
                    id: "live-\(liveSessionID ?? chunk.id)-0",
                    startedAt: sessionStart,
                    endedAt: liveChunks.last?.captureEndedAt ?? chunk.captureEndedAt,
                    text: liveFinalTranscript,
                    audioChunkID: chunk.id
                ))
                await refreshTimeline(for: sessionStart)
            } catch { fail(error) }
        }
        do {
            for var chunk in liveChunks {
                if liveRecognitionFailed {
                    chunk.transcriptionState = .failed
                    chunk.processingState = .failed
                    chunk.failureReason = String(lore: "後追い音声認識に失敗したため次回起動時に再処理します")
                } else {
                    chunk.transcriptionState = .transcribed
                    chunk.processingState = .extracted
                    chunk.failureReason = nil
                }
                try await database.lifeLog.save(audioChunk: chunk)
            }
            if !liveRecognitionFailed { await audioProcessingCompleted() }
        } catch { fail(error) }
        isTranscribing = false
        liveTranscript = ""
        await cancelLivePreview()
        finishLiveSpeechActivity()
        liveSessionStartedAt = nil
        liveSessionID = nil
        liveChunks = []
        liveRecognitionFailed = false
        pendingLiveSegments = []
        transcriptionFinished = false
        captureFinished = false
        await reload()
        liveTranscriptionTask = nil
        if restartForTranscriptionConfiguration, mayRunCapture {
            restartForTranscriptionConfiguration = false
            await startLiveCapture()
        } else if isRecoveringCapture, mayRunCapture {
            scheduleCaptureRetry(unless: EngineError.failed(String(lore: "音声streamの終了後に再接続します")))
        }
    }

    public func select(date: Date) async {
        selectedDate = date
        followsCurrentDay = Calendar.current.isDateInToday(date)
        await reload()
    }

    public func followCurrentDay() async {
        followsCurrentDay = true
        selectedDate = Date()
        await reload()
    }

    public func addMemo(_ text: String, at date: Date = Date()) async {
        guard let database else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try await database.lifeLog.save(memo: LifeLogMemo(createdAt: date, text: value))
            await reload()
        } catch { fail(error) }
    }

    /// 空の本文は削除と区別するため保存しない。呼び出し側はfalseなら編集を続ける。
    @discardableResult
    public func updateMemo(id: String, text: String) async -> Bool {
        guard let database else { return false }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return false }
        do {
            try await database.lifeLog.updateMemo(id: id, text: value)
            await reload()
            return true
        } catch {
            fail(error)
            return false
        }
    }

    public func deleteMemo(id: String) async {
        guard let database else { return }
        do { try await database.lifeLog.deleteMemo(id: id); await reload() }
        catch { fail(error) }
    }

    public func loadActivity(containing date: Date) async {
        guard let database,
              let month = Calendar.current.dateInterval(of: .month, for: date) else { return }
        do {
            monthActivity = try await database.lifeLog.activity(start: month.start, end: month.end, participatingOnly: participatingEventsOnly())
        } catch { fail(error) }
    }

    public func refreshCalendar(selectedCalendars: Set<String>) async {
        guard let database, let interval = Calendar.current.dateInterval(of: .day, for: selectedDate) else { return }
        guard !isRefreshingCalendar else { return }
        isRefreshingCalendar = true
        defer { isRefreshingCalendar = false }
        do {
            guard try await calendarProvider.requestAccess() else { return }
            let events = try await calendarProvider.events(start: interval.start, end: interval.end, selectedCalendars: selectedCalendars)
            try await database.lifeLog.replaceCalendarEvents(events, in: interval)
            lastCalendarRefreshAt = Date()
            lastCalendarRefreshDay = LifeLogDateKey.string(for: selectedDate)
            await reload()
            await loadActivity(containing: selectedDate)
            onCalendarRefreshed?()
        } catch { fail(error) }
    }

    /// 「記録しない」予定の判断に使う、現在の前後の予定。表示するcalendarの選択に関係なく全calendarから読む。
    /// アクセスを尋ねないため、呼び出し側が許可済みの時だけ呼ぶ。失敗時は表示してnilを返す。
    public func eventsAroundNow(_ now: Date) async -> [CalendarEventSnapshot]? {
        do {
            return try await calendarProvider.events(
                start: now.addingTimeInterval(-12 * 3600), end: now.addingTimeInterval(24 * 3600), selectedCalendars: []
            )
        } catch {
            fail(error)
            return nil
        }
    }

    /// Windowの再表示ごとにEventKitとDBを読み直さず、同じ日の新しいsnapshotを再利用する。
    public func refreshCalendarIfNeeded(
        selectedCalendars: Set<String>,
        maxAge: TimeInterval = 5 * 60,
        now: Date = Date()
    ) async {
        let selectedDay = LifeLogDateKey.string(for: selectedDate)
        if lastCalendarRefreshDay == selectedDay,
           let lastCalendarRefreshAt,
           now.timeIntervalSince(lastCalendarRefreshAt) < maxAge {
            return
        }
        await refreshCalendar(selectedCalendars: selectedCalendars)
    }

    public func loadCalendars() async {
        do {
            guard try await calendarProvider.requestAccess() else { return }
            availableCalendars = await calendarProvider.calendars()
        } catch { fail(error) }
    }

    public func calendarFilterChanged() async {
        await reload()
        await loadActivity(containing: selectedDate)
    }

    public func jumpToSearchResult(_ result: LifeLogSearchResult) async {
        let date = LifeLogDateKey.date(from: result.day) ?? result.occurredAt
        let prefix = "\(result.kind.rawValue)-"
        let recordID = result.id.hasPrefix(prefix) ? String(result.id.dropFirst(prefix.count)) : result.id
        switch result.kind {
        case .utterance:
            await navigateToSource(date: date, timelineItemID: "u-\(recordID)")
        case .dictation:
            await navigateToSource(date: date, timelineItemID: "d-\(recordID)")
        case .memo:
            await navigateToSource(date: date, timelineItemID: "m-\(recordID)")
        }
    }

    public func jumpToTime(_ date: Date) async {
        await select(date: date)
        let candidates = day.utterances.map { ($0.startedAt, "u-\($0.id)") }
            + day.calendarEvents.map { ($0.startsAt, "e-\($0.id)") }
            + day.dictations.map { ($0.startedAt, "d-\($0.id)") }
            + day.memos.map { ($0.createdAt, "m-\($0.id)") }
        guard let nearest = candidates.min(by: {
            abs($0.0.timeIntervalSince(date)) < abs($1.0.timeIntervalSince(date))
        }) else { return }
        highlightedTimelineItemID = nearest.1
        sourceNavigationRevision += 1
    }

    /// Moves to an item of the selected day, such as the source of an AI note item.
    public func jumpToTimelineItem(_ timelineItemID: String) {
        highlightedTimelineItemID = timelineItemID
        sourceNavigationRevision += 1
    }

    public func showEvent(id eventID: String, day: String) async {
        await navigateToSource(date: LifeLogDateKey.date(from: day) ?? Date(), timelineItemID: "e-\(eventID)")
    }

    public func showUtterance(id utteranceID: String, day: String) async {
        await navigateToSource(date: LifeLogDateKey.date(from: day) ?? Date(), timelineItemID: "u-\(utteranceID)")
    }

    /// Saves today's calendar snapshot for the AI trigger without moving the selected day.
    /// The caller checks calendar access first, so this never shows the permission prompt.
    public func saveTodayCalendarSnapshot(selectedCalendars: Set<String>, now: Date = Date()) async throws {
        guard let database, let interval = Calendar.current.dateInterval(of: .day, for: now) else { return }
        let events = try await calendarProvider.events(start: interval.start, end: interval.end, selectedCalendars: selectedCalendars)
        try await database.lifeLog.replaceCalendarEvents(events, in: interval)
        await reload()
    }

    /// Events of the given calendars, read from EventKit without saving a snapshot.
    public func calendarEvents(in interval: DateInterval, calendars: Set<String>) async throws -> [CalendarEventSnapshot] {
        guard !calendars.isEmpty else { return [] }
        return try await calendarProvider.events(start: interval.start, end: interval.end, selectedCalendars: calendars)
    }

    /// The wall-clock start of the oldest captured audio whose utterances are not saved yet.
    /// Failed chunks do not count: they wait for the next launch and must not block AI notes forever.
    public func oldestUntranscribedAudioStart() async throws -> Date? {
        guard let database else { return nil }
        let liveIDs = Set(liveChunks.map(\.id))
        let stored = try await database.lifeLog.pendingAudioChunks()
            .filter { !liveIDs.contains($0.id) && $0.transcriptionState != .failed && $0.processingState != .failed }
            .map(\.captureStartedAt)
        // The burst in progress began up to about a second of pre-roll and the 250 ms onset earlier.
        let live = liveSpeechStartedAt?.addingTimeInterval(-2)
        return (stored + [live].compactMap { $0 }).min()
    }

    private func navigateToSource(date: Date, timelineItemID: String) async {
        await select(date: date)
        highlightedTimelineItemID = timelineItemID
        sourceNavigationRevision += 1
    }

    #if DEBUG
    /// LP用の収録だけで使う。実際のcaptureを動かさず、記録中と聞き取り中の見た目を再現する。
    public func applyPreviewCapture(capturing: Bool, hearingSince: Date? = nil, audioDuration: TimeInterval = 0, transcript: String = "") {
        captureRequested = capturing
        isCapturing = capturing
        isHearingSpeech = hearingSince != nil
        liveSpeechStartedAt = hearingSince
        liveSpeechAudioDuration = audioDuration
        liveTranscript = transcript
    }

    /// LP用の収録だけで使う。話し終えた一文をdemo databaseへ保存し、timelineへ並べる。
    public func savePreviewUtterance(text: String, startedAt: Date, endedAt: Date) async throws {
        guard let database else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "databaseがまだ開いていません"])
        }
        let id = UUID().uuidString
        let chunk = LifeLogAudioChunk(id: "preview-audio-\(id)", captureStartedAt: startedAt, captureEndedAt: endedAt, localPath: "/tmp/lore-preview-\(id).m4a", transcriptionState: .transcribed, processingState: .extracted, peakLevel: 0.5)
        try await database.lifeLog.save(audioChunk: chunk)
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "preview-utterance-\(id)", startedAt: startedAt, endedAt: endedAt, text: text, audioChunkID: chunk.id))
        await reload()
    }
    #endif

    public func reload() async {
        guard let database else { return }
        do {
            let participatingOnly = participatingEventsOnly()
            day = try await database.lifeLog.day(selectedDate, participatingOnly: participatingOnly)
            today = Calendar.current.isDateInToday(selectedDate)
                ? day
                : try await database.lifeLog.day(Date(), participatingOnly: participatingOnly)
        } catch { fail(error) }
    }

    private func process(_ initial: LifeLogAudioChunk) async {
        guard let database, let engines else { return }
        var chunk = initial
        do {
            // 音声ファイルの原子的commitが完了した後にだけDB/STTへ進む。
            try await database.lifeLog.save(audioChunk: chunk)
            // SpeechAnalyzerは極端に短い入力でOS内部trapを起こすことがある。
            // 会話として成立しない断片は、元音声を残したまま発話なしで確定する。
            if !chunk.isTranscriptionCandidate {
                chunk.transcriptionState = .transcribed
                chunk.processingState = .extracted
                try await database.lifeLog.save(audioChunk: chunk)
                await audioProcessingCompleted()
                await reload()
                return
            }
            let utterances: [LifeLogUtterance]
            if chunk.transcriptionState == .transcribed {
                utterances = try await database.lifeLog.utterances(audioChunkID: chunk.id)
            } else {
                // 異常終了前に保存できた暫定発話を、同じ音声からの再認識結果で置き換える。
                try await database.lifeLog.deleteUtterances(audioChunkID: chunk.id)
                let enabledVocabulary = vocabulary().filter(\.enabled)
                let hints = SttHints(
                    contextualStrings: FormattingPolicy.contextualStrings(enabledVocabulary),
                    vocabularyPrompt: FormattingPolicy.vocabularyHint(enabledVocabulary),
                    languagePreference: transcriptionLanguage()
                )
                let stt = engines.lifeLogStt
                let gateAudio = try audioChunks(
                    url: URL(fileURLWithPath: chunk.localPath),
                    targetFormat: AudioFormats.canonical
                )
                let gateBursts = Self.recognizableSpeechBursts(from: gateAudio)
                var recognized: [LifeLogUtterance] = []
                if !gateBursts.isEmpty {
                    // 無音chunkではmodelやSpeechAnalyzerの準備にも到達しない。
                    let format = try await stt.prepare(hints: hints) ?? AudioFormats.canonical
                    let audio = try audioChunks(
                        url: URL(fileURLWithPath: chunk.localPath),
                        targetFormat: format
                    )
                    let bursts = Self.recognizableSpeechBursts(from: audio)
                    isTranscribing = true
                    liveTranscript = ""
                    beginActiveTranscription(audioDuration: bursts.reduce(0) { $0 + $1.duration })
                    defer {
                        endActiveTranscription()
                        isTranscribing = false
                    }
                    let capturedDay = try await database.lifeLog.day(
                        chunk.captureStartedAt,
                        participatingOnly: participatingEventsOnly()
                    )
                    for burst in bursts {
                        var transcript = ""
                        var timedSegments: [(text: String, start: TimeInterval, end: TimeInterval)] = []
                        for try await event in stt.transcribe(
                            audio: Self.audioStream(from: burst.buffers),
                            hints: hints
                        ) {
                            switch event {
                            case .segment(let text, let start, let end):
                                timedSegments.append((text, start, end))
                            case .sessionFinished(let text, _):
                                transcript = text
                                liveTranscript = text
                            case .partial(let text):
                                liveTranscript = text
                            }
                        }
                        if timedSegments.isEmpty {
                            let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !value.isEmpty else { continue }
                            let startedAt = chunk.captureStartedAt.addingTimeInterval(burst.startOffset)
                            let event = capturedDay.calendarEvents
                                .filter { $0.contains(startedAt, tolerance: 120) }
                                .min { $0.endsAt.timeIntervalSince($0.startsAt) < $1.endsAt.timeIntervalSince($1.startsAt) }
                            recognized.append(LifeLogUtterance(
                                id: Self.transcriptionSegmentID(
                                    scopeID: "utterance-\(chunk.id)",
                                    startOffset: burst.startOffset,
                                    endOffset: burst.endOffset
                                ),
                                startedAt: startedAt,
                                endedAt: min(chunk.captureEndedAt, chunk.captureStartedAt.addingTimeInterval(burst.endOffset)),
                                text: value,
                                audioChunkID: chunk.id,
                                calendarEventID: event?.id
                            ))
                        } else {
                            recognized.append(contentsOf: timedSegments.map { segment in
                                let startOffset = burst.startOffset + max(0, segment.start)
                                let endOffset = burst.startOffset + max(segment.start, segment.end)
                                let startedAt = chunk.captureStartedAt.addingTimeInterval(startOffset)
                                let endedAt = min(
                                    chunk.captureEndedAt,
                                    chunk.captureStartedAt.addingTimeInterval(endOffset)
                                )
                                let event = capturedDay.calendarEvents
                                    .filter { $0.contains(startedAt, tolerance: 120) }
                                    .min { $0.endsAt.timeIntervalSince($0.startsAt) < $1.endsAt.timeIntervalSince($1.startsAt) }
                                return LifeLogUtterance(
                                    id: Self.transcriptionSegmentID(
                                        scopeID: "utterance-\(chunk.id)",
                                        startOffset: startOffset,
                                        endOffset: endOffset
                                    ),
                                    startedAt: startedAt,
                                    endedAt: endedAt,
                                    text: segment.text,
                                    audioChunkID: chunk.id,
                                    calendarEventID: event?.id
                                )
                            })
                        }
                    }
                }
                chunk.transcriptionState = .transcribed
                try await database.lifeLog.save(audioChunk: chunk)
                utterances = recognized
                for utterance in utterances { try await database.lifeLog.save(utterance: utterance) }
                await reload()
                liveTranscript = ""
            }
            guard !utterances.isEmpty else {
                chunk.processingState = .extracted
                try await database.lifeLog.save(audioChunk: chunk)
                await audioProcessingCompleted()
                await reload()
                return
            }
            chunk.processingState = .extracted
            try await database.lifeLog.save(audioChunk: chunk)
            await audioProcessingCompleted()
            let affectedDates = Dictionary(grouping: utterances, by: { LifeLogDateKey.string(for: $0.startedAt) })
                .compactMapValues(\.first?.startedAt)
            for date in affectedDates.values { await refreshTimeline(for: date) }
        } catch {
            chunk.failureReason = error.localizedDescription
            if chunk.transcriptionState != .transcribed { chunk.transcriptionState = .failed }
            chunk.processingState = .failed
            do { try await database.lifeLog.save(audioChunk: chunk) } catch { fail(error); return }
            fail(error)
        }
    }

    private func resumePending() async {
        guard let database else { return }
        do { for chunk in try await database.lifeLog.pendingAudioChunks() { await process(chunk) } } catch { fail(error) }
    }

    /// SpeechAnalyzerは同じ確定範囲を複数回通知することがある。
    /// 認識範囲をidentityにし、再通知は別発話の追加ではなく既存発話の更新にする。
    nonisolated static func transcriptionSegmentID(
        scopeID: String,
        startOffset: TimeInterval,
        endOffset: TimeInterval
    ) -> String {
        let startMilliseconds = Int64((max(0, startOffset) * 1_000).rounded())
        let endMilliseconds = Int64((max(0, max(startOffset, endOffset)) * 1_000).rounded())
        return "\(scopeID)-\(startMilliseconds)-\(endMilliseconds)"
    }

    private func refreshTimeline(for date: Date) async {
        await reload()
        await loadActivity(containing: date)
    }

    struct RecognizableSpeechBurst: Sendable {
        let buffers: [AudioChunk]
        let startOffset: TimeInterval
        let endOffset: TimeInterval

        var duration: TimeInterval { max(0, endOffset - startOffset) }
    }

    /// 保存audioの復旧時もlive captureと同じ発話境界を使い、30秒chunk全体をSTTへ渡さない。
    nonisolated static func recognizableSpeechBursts(from audio: [AudioChunk]) -> [RecognizableSpeechBurst] {
        var segmenter = AdaptiveSpeechSegmenter()
        var preRoll: [AudioChunk] = []
        var burst: [AudioChunk] = []
        var lastVoicedIndex = 0
        var result: [RecognizableSpeechBurst] = []

        func candidate(from buffers: [AudioChunk], lastVoicedIndex: Int) -> RecognizableSpeechBurst? {
            let trimmed = Self.trimmingTrailingSilence(
                from: buffers,
                lastVoicedIndex: lastVoicedIndex,
                retainedDuration: 0.5
            )
            guard let first = trimmed.first, let last = trimmed.last else { return nil }
            let sampleRate = first.buffer.format.sampleRate
            return RecognizableSpeechBurst(
                buffers: trimmed,
                startOffset: Double(first.frameOffset) / sampleRate,
                endOffset: Double(last.frameOffset + AVAudioFramePosition(last.buffer.frameLength)) / sampleRate
            )
        }

        for chunk in audio {
            let duration = Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            let level = AudioCapture.rootMeanSquare(of: chunk.buffer)
            let wasVoiced = segmenter.isActive && segmenter.considersSpeech(level: level)
            switch segmenter.consume(level: level, duration: duration) {
            case .ignore:
                preRoll.append(chunk)
                Self.trimPreRoll(&preRoll, maximumDuration: 1)
            case .started:
                burst = preRoll + [chunk]
                preRoll = []
                lastVoicedIndex = burst.endIndex
            case .buffer:
                burst.append(chunk)
                if wasVoiced { lastVoicedIndex = burst.endIndex }
            case .flush:
                burst.append(chunk)
                if segmenter.completedBurstEvidence?.isTranscriptionCandidate == true,
                   let value = candidate(from: burst, lastVoicedIndex: lastVoicedIndex) {
                    result.append(value)
                }
                burst = []
                lastVoicedIndex = 0
            }
        }
        if segmenter.finish(),
           segmenter.completedBurstEvidence?.isTranscriptionCandidate == true,
           let value = candidate(from: burst, lastVoicedIndex: lastVoicedIndex) {
            result.append(value)
        }
        return result
    }

    private func audioChunks(url: URL, targetFormat: AVAudioFormat) throws -> [AudioChunk] {
        let file = try AVAudioFile(forReading: url)
        let resampler = Resampler(from: file.processingFormat, to: targetFormat)
        var chunks: [AudioChunk] = []
        var offset: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            let count = AVAudioFrameCount(min(4_096, file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw EngineError.failed(String(lore: "音声bufferを作成できません")) }
            try file.read(into: buffer, frameCount: count)
            guard let converted = resampler?.convert(buffer) else { throw EngineError.failed(String(lore: "音声を認識形式へ変換できません")) }
            chunks.append(AudioChunk(buffer: converted, frameOffset: offset))
            offset += AVAudioFramePosition(converted.frameLength)
        }
        return chunks
    }

    private nonisolated static func audioStream(from chunks: [AudioChunk]) -> AsyncStream<AudioChunk> {
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
        return stream
    }

    private func beginActiveTranscription(audioDuration: TimeInterval) {
        activeTranscriptionCount += 1
        if activeTranscriptionCount == 1 {
            activeTranscriptionStartedAt = Date()
            activeTranscriptionAudioDuration = max(0, audioDuration)
        } else {
            activeTranscriptionAudioDuration = (activeTranscriptionAudioDuration ?? 0) + max(0, audioDuration)
        }
    }

    private func endActiveTranscription() {
        activeTranscriptionCount = max(0, activeTranscriptionCount - 1)
        if activeTranscriptionCount == 0 {
            activeTranscriptionStartedAt = nil
            activeTranscriptionAudioDuration = nil
        }
    }

    private func fail(_ error: Error) { errorMessage = error.localizedDescription; LoreLog.session.error("ライフログ処理に失敗: \(error.localizedDescription, privacy: .public)") }

    static func shouldRetryCapture(after error: Error) -> Bool {
        if let failure = error as? ContinuousAudioCapture.Failure, case .microphoneDenied = failure {
            return false
        }
        return true
    }
}
