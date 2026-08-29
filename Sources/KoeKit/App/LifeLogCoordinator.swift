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
    public private(set) var highlightedUtteranceID: String?
    public private(set) var monthActivity: [String: LifeLogDayActivity] = [:]
    public private(set) var extractionRules: [TodoExtractionRule] = []
    public private(set) var liveTranscript = ""
    public private(set) var isTranscribing = false
    public private(set) var isRecoveringCapture = false

    private let capture = ContinuousAudioCapture()
    private let calendarProvider = CalendarProvider()
    private var database: KoeDatabase?
    private var engines: EngineRegistry?
    private var vocabulary: @MainActor () -> [VocabularyEntry] = { [] }
    private var todoPrompt: @MainActor () -> String = { BuiltinLifeLogPrompts.todo }
    private var summaryPrompt: @MainActor () -> String = { BuiltinLifeLogPrompts.summary }
    private var summaryIntervalMinutes: @MainActor () -> Int = { 60 }
    private var participatingEventsOnly: @MainActor () -> Bool = { true }
    private var lastCapturedDate: Date?
    private var liveTranscriptionTask: Task<Void, Never>?
    private var liveSessionStartedAt: Date?
    private var liveSessionID: String?
    private var liveChunks: [LifeLogAudioChunk] = []
    private var pendingLiveSegments: [(text: String, start: TimeInterval, end: TimeInterval)] = []
    private var liveFinalTranscript = ""
    private var liveSegmentIndex = 0
    private var transcriptionFinished = false
    private var captureFinished = false
    private var isDeriving = false
    private var isFinalizingSession = false
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
    }

    public func configure(
        database: KoeDatabase,
        engines: EngineRegistry,
        vocabulary: @MainActor @escaping () -> [VocabularyEntry],
        todoPrompt: @MainActor @escaping () -> String,
        summaryPrompt: @MainActor @escaping () -> String,
        summaryIntervalMinutes: @MainActor @escaping () -> Int,
        participatingEventsOnly: @MainActor @escaping () -> Bool
    ) async {
        self.database = database; self.engines = engines; self.vocabulary = vocabulary
        self.todoPrompt = todoPrompt
        self.summaryPrompt = summaryPrompt
        self.summaryIntervalMinutes = summaryIntervalMinutes
        self.participatingEventsOnly = participatingEventsOnly
        await reload()
        // 保留音声の再処理は重要だが、履歴・ライフログウィンドウの初期表示を待たせない。
        Task { await resumePending() }
    }

    public func selectInputDevice(uid: String?) { capture.inputDeviceUID = uid }

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
            captureRetryTask?.cancel()
            captureRetryTask = nil
            isRecoveringCapture = false
            dayRolloverTask?.cancel()
            dayRolloverTask = nil
            derivationScheduleTask?.cancel()
            derivationScheduleTask = nil
            capture.stop()
            isCapturing = false
        }
    }

    /// アプリ終了時の境界。音声writer、文字起こし、DB保存、停止時の要約が終わるまで待つ。
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
        if isRecoveringCapture { return "再接続中" }
        if isCapturing, isTranscribing { return "記録・文字起こし中" }
        if isCapturing { return "記録中" }
        if isTranscribing { return "文字起こし中" }
        return "停止中"
    }

    /// スリープ前に音声ファイルとSpeechAnalyzer入力を閉じ、復帰後は同じ記録意図で再開する。
    public func systemWillSleep() {
        isSuspendedForSleep = true
        guard captureRequested else { return }
        captureRetryTask?.cancel()
        captureRetryTask = nil
        isRecoveringCapture = true
        capture.stop()
        isCapturing = false
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

    private func startLiveCapture() async {
        guard captureRequested, !isSuspendedForSleep, let engines else { return }
        do {
            let hints = SttHints(contextualStrings: vocabulary().filter(\.enabled).map(\.surface), languagePreference: .auto)
            let format = try await engines.stt.prepare(hints: hints) ?? AudioFormats.canonical
            let startedAt = Date()
            let stream = try capture.start(format: format)
            liveSessionStartedAt = startedAt
            liveSessionID = UUID().uuidString
            liveChunks = []
            pendingLiveSegments = []
            liveFinalTranscript = ""
            liveSegmentIndex = 0
            transcriptionFinished = false
            captureFinished = false
            isCapturing = true
            isRecoveringCapture = false
            isTranscribing = true
            liveTranscriptionTask = Task { [weak self] in
                await self?.consumeLiveAudio(stream, hints: hints)
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
        isCapturing = false
        scheduleCaptureRetry(unless: error)
    }

    private func scheduleCaptureRetry(unless error: Error) {
        guard captureRequested, !isSuspendedForSleep else { return }
        if let failure = error as? ContinuousAudioCapture.Failure, case .microphoneDenied = failure { return }
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

    private func consumeLiveAudio(_ audio: AsyncStream<AudioChunk>, hints: SttHints) async {
        guard let engines else { return }
        do {
            for try await event in engines.stt.transcribe(audio: audio, hints: hints) {
                switch event {
                case .partial(let text):
                    liveTranscript = text
                case .segment(let text, let start, let end):
                    pendingLiveSegments.append((text, start, end))
                    liveTranscript = text
                    await flushLiveSegments()
                case .sessionFinished(let text, _):
                    liveFinalTranscript = text
                    liveTranscript = text
                }
            }
            transcriptionFinished = true
            await finishLiveSessionIfReady()
        } catch {
            transcriptionFinished = true
            fail(error)
            if capture.isRunning {
                capture.stop()
                isCapturing = false
                scheduleCaptureRetry(unless: error)
            }
            await finishLiveSessionIfReady()
        }
    }

    private func commitLiveChunk(_ initial: LifeLogAudioChunk) async {
        guard let database else { return }
        var chunk = initial
        lastCapturedDate = chunk.captureStartedAt
        do {
            try await database.lifeLog.save(audioChunk: chunk)
            liveChunks.append(chunk)
            await flushLiveSegments()
            if transcriptionFinished {
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
                    id: "live-\(liveSessionID ?? chunk.id)-\(liveSegmentIndex)",
                    startedAt: startedAt,
                    endedAt: min(endedAt, chunk.captureEndedAt.addingTimeInterval(120)),
                    text: segment.text,
                    audioChunkID: chunk.id,
                    calendarEventID: event?.id
                )
                liveSegmentIndex += 1
                try await database.lifeLog.save(utterance: utterance)
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
        let startedAt = liveSessionStartedAt
        let completedAt = liveChunks.last?.captureEndedAt ?? liveSessionStartedAt
        await flushLiveSegments()
        if liveSegmentIndex == 0,
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
                chunk.transcriptionState = .transcribed
                chunk.processingState = .extracted
                try await database.lifeLog.save(audioChunk: chunk)
            }
        } catch { fail(error) }
        isTranscribing = false
        liveTranscript = ""
        liveSessionStartedAt = nil
        liveSessionID = nil
        liveChunks = []
        pendingLiveSegments = []
        transcriptionFinished = false
        captureFinished = false
        if !captureRequested, let startedAt, let completedAt {
            for date in Self.daysSpanned(from: startedAt, through: completedAt) {
                await refreshDerivedIfDue(for: date, respectingInterval: false, force: true)
            }
        }
        await reload()
        // 終了待ちは、停止時の最終要約と再読込まで含めて完了とみなす。
        liveTranscriptionTask = nil
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
        do {
            guard try await calendarProvider.requestAccess() else { return }
            let events = try await calendarProvider.events(start: interval.start, end: interval.end, selectedCalendars: selectedCalendars)
            try await database.lifeLog.save(calendarEvents: events)
            await reload()
            await loadActivity(containing: selectedDate)
        } catch { fail(error) }
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
    public func jumpToSource(of todo: LifeLogTodo) async {
        guard let database, let id = todo.sourceUtteranceIDs.first else { return }
        do { guard let utterance = try await database.lifeLog.utterance(id: id) else { return }; selectedDate = utterance.startedAt; highlightedUtteranceID = id; await reload() } catch { fail(error) }
    }
    public func addExtractionRule(_ instruction: String) async {
        guard let database else { return }
        let value = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do { try await database.lifeLog.save(rule: TodoExtractionRule(instruction: value)); await reload() }
        catch { fail(error) }
    }

    public func deleteExtractionRule(id: String) async {
        guard let database else { return }
        do { try await database.lifeLog.deleteRule(id: id); await reload() }
        catch { fail(error) }
    }

    public func reload() async {
        guard let database else { return }
        do {
            day = try await database.lifeLog.day(selectedDate, participatingOnly: participatingEventsOnly())
            todos = try await database.lifeLog.todos()
            extractionRules = try await database.lifeLog.rules()
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
                let hints = SttHints(contextualStrings: vocabulary().filter(\.enabled).map(\.surface), languagePreference: .auto)
                let format = try await engines.stt.prepare(hints: hints) ?? AudioFormats.canonical
                let audio = try audioStream(url: URL(fileURLWithPath: chunk.localPath), targetFormat: format)
                var transcript = ""
                var timedSegments: [(text: String, start: TimeInterval, end: TimeInterval)] = []
                for try await event in engines.stt.transcribe(audio: audio, hints: hints) {
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
                    utterances = timedSegments.enumerated().map { index, segment in
                        let startedAt = chunk.captureStartedAt.addingTimeInterval(max(0, segment.start))
                        let endedAt = min(chunk.captureEndedAt, chunk.captureStartedAt.addingTimeInterval(max(segment.start, segment.end)))
                        let event = capturedDay.calendarEvents.filter { $0.contains(startedAt, tolerance: 120) }.min { $0.endsAt.timeIntervalSince($0.startsAt) < $1.endsAt.timeIntervalSince($1.startsAt) }
                        return LifeLogUtterance(id: "utterance-\(chunk.id)-\(index)", startedAt: startedAt,
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
                await reload()
                return
            }
            chunk.processingState = .extracted
            try await database.lifeLog.save(audioChunk: chunk)
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
                                    derivation: LifeLogDerivationService(llm: engines.llm))
            await reload()
        } catch { fail(error) }
    }

    /// 定期実行は差分の有無を判定し、停止時は対象日のsource of truth全体から必ずsummaryを再構築する。
    func updateSummary(for date: Date, respectingInterval: Bool, force: Bool = false, store: LifeLogStore,
                       derivation: LifeLogDerivationService) async throws {
        let value = try await store.day(date, participatingOnly: participatingEventsOnly())
        let previous = value.summary
        let additions = value.utterances.filter { $0.endedAt > (previous?.summarizedThrough ?? .distantPast) }
        let memoAdditions = value.memos.filter { $0.createdAt > (previous?.summarizedThrough ?? .distantPast) }
        let latestAddition = (additions.map(\.endedAt) + memoAdditions.map(\.createdAt)).max()
        let latest = (value.utterances.map(\.endedAt) + value.memos.map(\.createdAt)).max()
        guard force || latestAddition != nil else {
            if var previous, !Calendar.current.isDateInToday(date), !previous.isFinal {
                previous.isFinal = true
                try await store.save(summary: previous)
            }
            return
        }
        guard let latest else { return }
        let baseline = previous?.summarizedThrough
            ?? (value.utterances.map(\.startedAt) + value.memos.map(\.createdAt)).min()
            ?? latest
        let interval = TimeInterval(max(15, summaryIntervalMinutes()) * 60)
        guard force || !respectingInterval || !Calendar.current.isDateInToday(date)
                || latest.timeIntervalSince(baseline) >= interval else { return }
        let rules = try await store.rules().map(\.instruction).joined(separator: "\n")
        let todoInstructions = [todoPrompt(), rules].filter { !$0.isEmpty }.joined(separator: "\n")
        let derived = try await derivation.summarize(day: value, prompt: summaryPrompt(), todoPrompt: todoInstructions)
        let commitments = try await store.todos().filter { $0.status != .draft }.map(\.title)
        let duration = value.utterances.reduce(0) { $0 + max(0, Int($1.endedAt.timeIntervalSince($1.startedAt))) }
        let summary = DailySummary(day: LifeLogDateKey.string(for: date), summary: derived.text,
                                   commitments: Array(Set((previous?.commitments ?? []) + commitments)).sorted(), topics: derived.topics,
                                   calendarEventCount: value.calendarEvents.count, capturedDurationSeconds: duration,
                                   utteranceCount: value.utterances.count, summarizedThrough: latest,
                                   isFinal: !Calendar.current.isDateInToday(date))
        let sourceIDs = value.utterances.map(\.id)
        let sourceMemoIDs = value.memos.map(\.id)
        let drafts = derived.todoTitles.enumerated().map { index, title in
            LifeLogTodo(id: "draft-\(summary.day)-\(index)", title: title, status: .draft,
                        sourceUtteranceIDs: sourceIDs, sourceMemoIDs: sourceMemoIDs)
        }
        try await store.save(summary: summary, replacingDrafts: drafts)
    }

    static func daysSpanned(from start: Date, through end: Date, calendar: Calendar = .current) -> [Date] {
        var dates: [Date] = []
        var date = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: max(start, end))
        while date <= last {
            dates.append(date)
            guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { break }
            date = next
        }
        return dates
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
}
