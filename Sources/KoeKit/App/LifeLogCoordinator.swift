import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
public final class LifeLogCoordinator {
    public private(set) var isCapturing = false
    public private(set) var selectedDate = Date()
    public private(set) var day = LifeLogDay(utterances: [], conversations: [], calendarEvents: [], summary: nil)
    public private(set) var todos: [LifeLogTodo] = []
    public private(set) var errorMessage: String?
    public private(set) var availableCalendars: [String] = []
    public private(set) var highlightedTimelineItemID: String?
    public private(set) var sourceNavigationRevision = 0
    public private(set) var monthActivity: [String: LifeLogDayActivity] = [:]
    public private(set) var liveTranscript = ""
    public private(set) var isTranscribing = false
    public private(set) var isRecoveringCapture = false
    public private(set) var isSuspendedForVoiceMemo = false
    public private(set) var isRefreshingCalendar = false
    public private(set) var lastCalendarRefreshAt: Date?
    private var lastCalendarRefreshDay: String?

    private let capture = ContinuousAudioCapture()
    private let calendarProvider = CalendarProvider()
    private var database: KoeDatabase?
    private var engines: EngineRegistry?
    private var vocabulary: @MainActor () -> [VocabularyEntry] = { [] }
    private var todoPrompt: @MainActor () -> String = { BuiltinLifeLogPrompts.todo }
    private var summaryPrompt: @MainActor () -> String = { BuiltinLifeLogPrompts.summary }
    private var summaryIntervalMinutes: @MainActor () -> Int = { 60 }
    private var participatingEventsOnly: @MainActor () -> Bool = { true }
    private var audioProcessingCompleted: @MainActor () async -> Void = {}
    private var liveTranscriptionTask: Task<Void, Never>?
    private var liveSessionStartedAt: Date?
    private var liveSessionID: String?
    private var liveChunks: [LifeLogAudioChunk] = []
    private var pendingLiveSegments: [(text: String, start: TimeInterval, end: TimeInterval)] = []
    private var liveFinalTranscript = ""
    private var liveRecognitionFailed = false
    private var hasLiveSegments = false
    private var transcriptionFinished = false
    private var captureFinished = false
    public private(set) var isDeriving = false
    private var isFinalizingSession = false
    private var isStartingCapture = false
    private var vocabularyRevision = 0
    private var restartForVocabulary = false
    private var captureRequested = false
    private var captureRetryAttempt = 0
    private var captureRetryTask: Task<Void, Never>?
    private var dayRolloverTask: Task<Void, Never>?
    private var derivationScheduleTask: Task<Void, Never>?
    private var followsCurrentDay = true
    private var isSuspendedForSleep = false

    public init() {
        capture.onCommitted = { [weak self] chunk in await self?.commitLiveChunk(chunk) }
        capture.onFinished = { [weak self] in await self?.captureWriterFinished() }
        capture.onFailure = { [weak self] error in self?.handleCaptureFailure(error) }
        capture.onRunningChanged = { [weak self] running in self?.isCapturing = running }
    }

    public func configure(
        database: KoeDatabase,
        engines: EngineRegistry,
        vocabulary: @MainActor @escaping () -> [VocabularyEntry],
        todoPrompt: @MainActor @escaping () -> String,
        summaryPrompt: @MainActor @escaping () -> String,
        summaryIntervalMinutes: @MainActor @escaping () -> Int,
        participatingEventsOnly: @MainActor @escaping () -> Bool,
        audioProcessingCompleted: @MainActor @escaping () async -> Void
    ) async {
        self.database = database; self.engines = engines; self.vocabulary = vocabulary
        self.todoPrompt = todoPrompt
        self.summaryPrompt = summaryPrompt
        self.summaryIntervalMinutes = summaryIntervalMinutes
        self.participatingEventsOnly = participatingEventsOnly
        self.audioProcessingCompleted = audioProcessingCompleted
        await reload()
        // 保留音声の再処理は重要だが、履歴・ライフログウィンドウの初期表示を待たせない。
        Task { await resumePending() }
    }

    public func selectInputDevice(uid: String?) {
        guard capture.inputDeviceUID != uid else { return }
        capture.inputDeviceUID = uid
        guard captureRequested else { return }
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
            scheduleDerivedUpdates()
            guard !isCapturing, liveTranscriptionTask == nil else { return }
            Task { await startLiveCapture() }
            scheduleDayRollover()
        } else {
            restartForVocabulary = false
            captureRetryTask?.cancel()
            captureRetryTask = nil
            isRecoveringCapture = false
            dayRolloverTask?.cancel()
            dayRolloverTask = nil
            derivationScheduleTask?.cancel()
            derivationScheduleTask = nil
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

    /// Cmd-Qでは復旧可能なaudio/DB保存を優先し、終了を遅らせるsummary/TODO生成は行わない。
    public func stopForTermination(timeout: Duration = .seconds(3)) async -> Bool {
        return await stopAndWait(timeout: timeout)
    }

    private func scheduleDerivedUpdates() {
        guard derivationScheduleTask == nil else { return }
        derivationScheduleTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.captureRequested else { return }
                let interval = max(15, self.summaryIntervalMinutes())
                do { try await Task.sleep(for: .seconds(interval * 60)) } catch { return }
                guard self.captureRequested else { return }
                await self.refreshDerivedIfDue(for: Date(), respectingInterval: false)
            }
        }
    }

    public var captureStatusText: String {
        if isSuspendedForVoiceMemo { return "ボイスメモ中は一時停止" }
        if isRecoveringCapture { return "再接続中" }
        if isCapturing { return "記録中" }
        if captureRequested { return "開始準備中" }
        if isTranscribing { return "保存中" }
        return "停止中"
    }

    public var hasCaptureIntent: Bool { captureRequested }

    public func dismissError() {
        errorMessage = nil
    }

    /// 終了前に音声・文字起こし・派生処理の確定を待つ必要がある状態。
    /// 記録開始要求から実際のcapture開始までの隙間も含める。
    public var hasPendingTerminationWork: Bool {
        captureRequested || capture.isRunning || liveTranscriptionTask != nil || isFinalizingSession || isDeriving
    }

    /// STTの語彙contextは解析開始時に固定されるため、録音意図を保ったまま
    /// 現在の認識sessionを確定し、次のsessionから更新済み語彙へ切り替える。
    public func vocabularyDidChange() {
        vocabularyRevision += 1
        requestVocabularyRestartIfNeeded()
    }

    private func requestVocabularyRestartIfNeeded() {
        guard captureRequested else { return }
        guard capture.isRunning || liveTranscriptionTask != nil else { return }
        guard !restartForVocabulary else { return }
        restartForVocabulary = true
        isRecoveringCapture = true
        KoeLog.session.info("語彙変更を反映するためライフログ解析streamを切り替えます")
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
        guard captureRequested else {
            isRecoveringCapture = false
            return
        }
        captureRetryAttempt = 0
        scheduleCaptureRetry(unless: EngineError.failed("スリープから復帰しました"))
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
                fail(EngineError.failed("ライフログの一時停止を完了できませんでした"))
                return false
            }
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
        }
        return true
    }

    public func resumeAfterVoiceMemo() {
        guard isSuspendedForVoiceMemo else { return }
        isSuspendedForVoiceMemo = false
        guard captureRequested, !isSuspendedForSleep else { return }
        captureRetryAttempt = 0
        scheduleCaptureRetry(unless: EngineError.failed("ボイスメモが終了しました"))
    }

    private func startLiveCapture() async {
        guard captureRequested, !isSuspendedForSleep, !isSuspendedForVoiceMemo,
              !isStartingCapture, let engines else { return }
        isStartingCapture = true
        defer { isStartingCapture = false }
        do {
            let startingVocabularyRevision = vocabularyRevision
            let enabledVocabulary = vocabulary().filter(\.enabled)
            let hints = SttHints(
                contextualStrings: FormattingPolicy.contextualStrings(enabledVocabulary),
                vocabularyPrompt: FormattingPolicy.vocabularyHint(enabledVocabulary),
                languagePreference: .auto
            )
            let stt = engines.lifeLogStt
            let format = try await stt.prepare(hints: hints) ?? AudioFormats.canonical
            guard captureRequested, !isSuspendedForSleep, !isSuspendedForVoiceMemo else { return }
            let startedAt = Date()
            let stream = try capture.start(format: format)
            liveSessionStartedAt = startedAt
            liveSessionID = UUID().uuidString
            liveChunks = []
            pendingLiveSegments = []
            liveFinalTranscript = ""
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
                requestVocabularyRestartIfNeeded()
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
                let previousDay = newDay.addingTimeInterval(-1)
                await self.refreshDerivedIfDue(for: previousDay, respectingInterval: false)
                if self.followsCurrentDay {
                    self.selectedDate = newDay
                    await self.reload()
                    await self.loadActivity(containing: newDay)
                }
            }
        }
    }

    private func handleCaptureFailure(_ error: Error) {
        fail(error)
        scheduleCaptureRetry(unless: error)
    }

    private func scheduleCaptureRetry(unless error: Error) {
        guard captureRequested, !isSuspendedForSleep, !isSuspendedForVoiceMemo,
              Self.shouldRetryCapture(after: error) else { return }
        captureRetryTask?.cancel()
        isRecoveringCapture = true
        captureRetryAttempt += 1
        let delay = min(30, [1, 2, 5, 10, 20, 30][min(captureRetryAttempt - 1, 5)])
        captureRetryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.captureRequested else { return }
            if self.liveTranscriptionTask != nil {
                self.scheduleCaptureRetry(unless: EngineError.failed("前の音声ストリームを終了しています"))
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

        for await chunk in audio {
            if Task.isCancelled { break }
            let duration = Double(chunk.buffer.frameLength) / chunk.buffer.format.sampleRate
            let level = AudioCapture.level(of: chunk.buffer)
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
                if level >= AdaptiveSpeechSegmenter.speechLevelThreshold {
                    lastVoicedIndex = burst.endIndex
                }
            case .flush:
                burst.append(chunk)
                let recognitionBuffers = Self.trimmingTrailingSilence(
                    from: burst,
                    lastVoicedIndex: lastVoicedIndex,
                    retainedDuration: 0.5
                )
                await recognizeBurst(recognitionBuffers, hints: hints, stt: stt)
                burst = []
                lastVoicedIndex = 0
            }
        }
        if segmenter.finish(), !burst.isEmpty {
            let recognitionBuffers = Self.trimmingTrailingSilence(
                from: burst,
                lastVoicedIndex: lastVoicedIndex,
                retainedDuration: 0.5
            )
            await recognizeBurst(recognitionBuffers, hints: hints, stt: stt)
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

    /// 認識結果が必ず復旧可能な音声を参照するよう、対象範囲のfile commitを先に待つ。
    private func waitUntilAudioIsCommitted(through offset: TimeInterval) async throws {
        guard let sessionStart = liveSessionStartedAt else {
            throw EngineError.failed("ライフログ音声の開始時刻を確認できません")
        }
        let requiredDate = sessionStart.addingTimeInterval(offset)
        while (liveChunks.last?.captureEndedAt ?? .distantPast) < requiredDate.addingTimeInterval(-0.25) {
            if captureFinished {
                throw EngineError.failed("認識対象のライフログ音声を保存できませんでした")
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
            await segmentAndRefresh(for: date)
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
                await segmentAndRefresh(for: sessionStart)
            } catch { fail(error) }
        }
        do {
            for var chunk in liveChunks {
                if liveRecognitionFailed {
                    chunk.transcriptionState = .failed
                    chunk.processingState = .failed
                    chunk.failureReason = "後追い音声認識に失敗したため次回起動時に再処理します"
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
        liveSessionStartedAt = nil
        liveSessionID = nil
        liveChunks = []
        liveRecognitionFailed = false
        pendingLiveSegments = []
        transcriptionFinished = false
        captureFinished = false
        await reload()
        liveTranscriptionTask = nil
        if restartForVocabulary, captureRequested, !isSuspendedForSleep, !isSuspendedForVoiceMemo {
            restartForVocabulary = false
            await startLiveCapture()
        } else if captureRequested, isRecoveringCapture, !isSuspendedForSleep, !isSuspendedForVoiceMemo {
            scheduleCaptureRetry(unless: EngineError.failed("音声streamの終了後に再接続します"))
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
            if Calendar.current.isDate(selectedDate, inSameDayAs: date) { await reload() }
        } catch { fail(error) }
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
            try await database.lifeLog.save(calendarEvents: events)
            lastCalendarRefreshAt = Date()
            lastCalendarRefreshDay = LifeLogDateKey.string(for: selectedDate)
            await reload()
            await loadActivity(containing: selectedDate)
        } catch { fail(error) }
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

    public func update(todo: LifeLogTodo) async { guard let database else { return }; do { try await database.lifeLog.save(todo: todo); await reload() } catch { fail(error) } }
    public func delete(todoID: String) async { guard let database else { return }; do { try await database.lifeLog.deleteTodo(id: todoID); await reload() } catch { fail(error) } }
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
        case .todo:
            await select(date: date)
        case .summary:
            await select(date: date)
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

    private func navigateToSource(date: Date, timelineItemID: String) async {
        await select(date: date)
        highlightedTimelineItemID = timelineItemID
        sourceNavigationRevision += 1
    }

    public func reload() async {
        guard let database else { return }
        do {
            day = try await database.lifeLog.day(selectedDate, participatingOnly: participatingEventsOnly())
            todos = try await database.lifeLog.todos()
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
                isTranscribing = true
                liveTranscript = ""
                defer { isTranscribing = false }
                let enabledVocabulary = vocabulary().filter(\.enabled)
                let hints = SttHints(
                    contextualStrings: FormattingPolicy.contextualStrings(enabledVocabulary),
                    vocabularyPrompt: FormattingPolicy.vocabularyHint(enabledVocabulary),
                    languagePreference: .auto
                )
                let stt = engines.lifeLogStt
                let format = try await stt.prepare(hints: hints) ?? AudioFormats.canonical
                let audio = try audioStream(url: URL(fileURLWithPath: chunk.localPath), targetFormat: format)
                var transcript = ""
                var timedSegments: [(text: String, start: TimeInterval, end: TimeInterval)] = []
                for try await event in stt.transcribe(audio: audio, hints: hints) {
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
                chunk.transcriptionState = .transcribed
                try await database.lifeLog.save(audioChunk: chunk)
                let capturedDay = try await database.lifeLog.day(chunk.captureStartedAt, participatingOnly: participatingEventsOnly())
                if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    utterances = []
                } else if timedSegments.isEmpty {
                    let event = capturedDay.calendarEvents.filter { $0.contains(chunk.captureStartedAt, tolerance: 120) }.min { $0.endsAt.timeIntervalSince($0.startsAt) < $1.endsAt.timeIntervalSince($1.startsAt) }
                    utterances = [LifeLogUtterance(id: "utterance-\(chunk.id)-0", startedAt: chunk.captureStartedAt,
                                                   endedAt: chunk.captureEndedAt, text: transcript,
                                                   audioChunkID: chunk.id, calendarEventID: event?.id)]
                } else {
                    utterances = timedSegments.map { segment in
                        let startedAt = chunk.captureStartedAt.addingTimeInterval(max(0, segment.start))
                        let endedAt = min(chunk.captureEndedAt, chunk.captureStartedAt.addingTimeInterval(max(segment.start, segment.end)))
                        let event = capturedDay.calendarEvents.filter { $0.contains(startedAt, tolerance: 120) }.min { $0.endsAt.timeIntervalSince($0.startsAt) < $1.endsAt.timeIntervalSince($1.startsAt) }
                        return LifeLogUtterance(id: Self.transcriptionSegmentID(
                            scopeID: "utterance-\(chunk.id)",
                            startOffset: segment.start,
                            endOffset: segment.end
                        ), startedAt: startedAt,
                                                endedAt: endedAt, text: segment.text,
                                                audioChunkID: chunk.id, calendarEventID: event?.id)
                    }
                }
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
            for date in affectedDates.values { await segmentAndRefresh(for: date) }
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

    private func segmentAndRefresh(for date: Date) async {
        guard let database else { return }
        do {
            let value = try await database.lifeLog.day(date, participatingOnly: participatingEventsOnly())
            for (conversation, items) in ConversationSegmenter().segment(value.utterances) {
                try await database.lifeLog.save(conversation: conversation, utterances: items)
            }
            await refreshDerivedIfDue(for: date)
            await reload()
            await loadActivity(containing: date)
        } catch { fail(error) }
    }

    private func refreshDerivedIfDue(for date: Date, respectingInterval: Bool = true, force: Bool = false) async {
        if isDeriving {
            guard force else { return }
            while isDeriving {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        guard let database, let engines else { return }
        isDeriving = true
        defer { isDeriving = false }
        do {
            try await updateSummary(for: date, respectingInterval: respectingInterval, force: force, store: database.lifeLog,
                                    derivation: LifeLogDerivationService(llm: engines.lifeLogLlm))
            await reload()
        } catch { fail(error) }
    }

    /// 選択日の要約とdraft TODOを、差分や定期間隔にかかわらず再構築する。
    public func refreshSelectedDaySummary() async {
        await refreshDerivedIfDue(for: selectedDate, respectingInterval: false, force: true)
    }

    /// 定期実行は差分の有無を判定し、手動実行は対象日のsource of truth全体から必ず再構築する。
    func updateSummary(
        for date: Date,
        respectingInterval: Bool,
        force: Bool = false,
        now: Date = Date(),
        store: LifeLogStore,
        derivation: LifeLogDerivationService
    ) async throws {
        let value = try await store.day(date, participatingOnly: participatingEventsOnly())
        let previous = value.summary
        let calendar = Calendar.current
        guard let dayInterval = calendar.dateInterval(of: .day, for: date) else { return }
        let isPastDay = dayInterval.end <= now
        let shouldFinalize = isPastDay && previous?.isFinal != true
        let additions = value.utterances.filter { $0.endedAt > (previous?.summarizedThrough ?? .distantPast) }
        let memoAdditions = value.memos.filter { $0.createdAt > (previous?.summarizedThrough ?? .distantPast) }
        let latestAddition = (additions.map(\.endedAt) + memoAdditions.map(\.createdAt)).max()
        let latestSource = (value.utterances.map(\.endedAt) + value.memos.map(\.createdAt)).max()
        guard force || latestAddition != nil || shouldFinalize else { return }
        let latest = latestSource ?? previous?.summarizedThrough ?? dayInterval.start
        let baseline = previous?.summarizedThrough
            ?? (value.utterances.map(\.startedAt) + value.memos.map(\.createdAt)).min()
            ?? latest
        let interval = TimeInterval(max(15, summaryIntervalMinutes()) * 60)
        guard force || shouldFinalize || !respectingInterval || isPastDay
                || latest.timeIntervalSince(baseline) >= interval else { return }
        let asOf = isPastDay ? dayInterval.end : now
        let existingTodos = try await store.todos()
        let derived = try await derivation.summarize(
            day: value,
            prompt: summaryPrompt(),
            todoPrompt: todoPrompt(),
            existingTodoTitles: existingTodos.map(\.title),
            asOf: asOf
        )
        let commitments = existingTodos.filter { $0.status != .draft }.map(\.title)
        let duration = value.utterances.reduce(0) { $0 + max(0, Int($1.endedAt.timeIntervalSince($1.startedAt))) }
        let summary = DailySummary(day: LifeLogDateKey.string(for: date), summary: derived.text,
                                   commitments: Array(Set((previous?.commitments ?? []) + commitments)).sorted(), topics: derived.topics,
                                   calendarEventCount: value.calendarEvents.count, capturedDurationSeconds: duration,
                                   utteranceCount: value.utterances.count, summarizedThrough: latest,
                                   isFinal: isPastDay)
        let drafts = derived.todoTitles.map { title in
            LifeLogTodo(title: title, status: .draft)
        }
        try await store.save(summary: summary, replacingDrafts: drafts)
    }

    private func audioStream(url: URL, targetFormat: AVAudioFormat) throws -> AsyncStream<AudioChunk> {
        let file = try AVAudioFile(forReading: url)
        let resampler = Resampler(from: file.processingFormat, to: targetFormat)
        var chunks: [AudioChunk] = []
        var offset: AVAudioFramePosition = 0
        while file.framePosition < file.length {
            let count = AVAudioFrameCount(min(4_096, file.length - file.framePosition))
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: count) else { throw EngineError.failed("音声bufferを作成できません") }
            try file.read(into: buffer, frameCount: count)
            guard let converted = resampler?.convert(buffer) else { throw EngineError.failed("音声を認識形式へ変換できません") }
            chunks.append(AudioChunk(buffer: converted, frameOffset: offset))
            offset += AVAudioFramePosition(converted.frameLength)
        }
        let (stream, continuation) = AsyncStream<AudioChunk>.makeStream()
        for chunk in chunks { continuation.yield(chunk) }
        continuation.finish()
        return stream
    }

    private func fail(_ error: Error) { errorMessage = error.localizedDescription; KoeLog.session.error("ライフログ処理に失敗: \(error.localizedDescription, privacy: .public)") }

    static func shouldRetryCapture(after error: Error) -> Bool {
        if let failure = error as? ContinuousAudioCapture.Failure, case .microphoneDenied = failure {
            return false
        }
        return true
    }
}
