import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import KoeKit

@Suite("Daily Life Logのsource of truthと派生処理")
struct LifeLogTests {
    @Test("同じ認識範囲の再通知は一つの発話を更新する")
    func repeatedFinalSegmentIsIdempotent() async throws {
        let database = try await KoeDatabase.inMemory()
        let startedAt = Date(timeIntervalSince1970: 1_000)
        let chunk = LifeLogAudioChunk(
            id: "audio",
            captureStartedAt: startedAt,
            captureEndedAt: startedAt.addingTimeInterval(30),
            localPath: "/tmp/audio.m4a"
        )
        try await database.lifeLog.save(audioChunk: chunk)
        let id = LifeLogCoordinator.transcriptionSegmentID(
            scopeID: "live-session",
            startOffset: 4.387,
            endOffset: 6.520
        )

        try await database.lifeLog.save(utterance: LifeLogUtterance(
            id: id,
            startedAt: startedAt.addingTimeInterval(4.387),
            endedAt: startedAt.addingTimeInterval(6.520),
            text: "狙い方としては早くしたい",
            audioChunkID: chunk.id
        ))
        try await database.lifeLog.save(utterance: LifeLogUtterance(
            id: id,
            startedAt: startedAt.addingTimeInterval(4.387),
            endedAt: startedAt.addingTimeInterval(6.520),
            text: "狙い方としては早くしたい",
            audioChunkID: chunk.id
        ))

        let utterances = try await database.lifeLog.day(startedAt).utterances
        #expect(utterances.count == 1)
        #expect(utterances.first?.id == id)
    }

    @Test("手動更新は差分がなくても選択日の全データを再要約する")
    @MainActor
    func manualRefreshForcesWholeDaySummary() async throws {
        let database = try await KoeDatabase.inMemory()
        let llm = RecordingLifeLogLlm()
        let coordinator = LifeLogCoordinator()
        let startedAt = Date().addingTimeInterval(-120)
        let endedAt = startedAt.addingTimeInterval(60)
        try await database.lifeLog.save(audioChunk: LifeLogAudioChunk(
            id: "audio", captureStartedAt: startedAt, captureEndedAt: endedAt,
            localPath: "/tmp/already-summarized.m4a",
            transcriptionState: .transcribed, processingState: .extracted
        ))
        let utterance = LifeLogUtterance(
            id: "already-summarized", startedAt: startedAt, endedAt: endedAt,
            text: "前回の要約後に変更されていない発話", audioChunkID: "audio"
        )
        try await database.lifeLog.save(utterance: utterance)
        try await database.lifeLog.save(summary: DailySummary(
            day: LifeLogDateKey.string(for: startedAt), summary: "前回", commitments: [], topics: [],
            calendarEventCount: 0, capturedDurationSeconds: 60, utteranceCount: 1,
            summarizedThrough: endedAt, isFinal: false
        ))

        await coordinator.configure(
            database: database,
            engines: EngineRegistry(llm: llm),
            vocabulary: { [] },
            todoPrompt: { BuiltinLifeLogPrompts.todo },
            summaryPrompt: { BuiltinLifeLogPrompts.summary },
            summaryIntervalMinutes: { 60 },
            participatingEventsOnly: { true },
            audioProcessingCompleted: {}
        )
        await coordinator.select(date: startedAt)

        await coordinator.refreshSelectedDaySummary()

        #expect(llm.recordedPrompts.map(\.user).joined().contains(utterance.text))
        #expect(try await database.lifeLog.day(startedAt).summary?.summary == "全体")
    }

    @Test("再要約の新しいDraft IDは確定済みの旧Draft IDと衝突しない")
    @MainActor
    func regeneratedDraftUsesUniqueID() async throws {
        let database = try await KoeDatabase.inMemory()
        let date = Date().addingTimeInterval(-120)
        let day = LifeLogDateKey.string(for: date)
        let confirmedID = "draft-\(day)-0"
        try await database.lifeLog.save(todo: LifeLogTodo(
            id: confirmedID, title: "既存の確定TODO", status: .open
        ))
        let chunk = LifeLogAudioChunk(
            id: "draft-collision-audio", captureStartedAt: date,
            captureEndedAt: date.addingTimeInterval(60), localPath: "/tmp/draft-collision.m4a"
        )
        try await database.lifeLog.save(audioChunk: chunk)
        try await database.lifeLog.save(utterance: LifeLogUtterance(
            id: "draft-collision-utterance", startedAt: date,
            endedAt: date.addingTimeInterval(60), text: "新しい作業", audioChunkID: chunk.id
        ))

        let coordinator = LifeLogCoordinator()
        try await coordinator.updateSummary(
            for: date, respectingInterval: false, force: true,
            store: database.lifeLog,
            derivation: LifeLogDerivationService(llm: RecordingLifeLogLlm())
        )

        let todos = try await database.lifeLog.todos()
        #expect(todos.contains { $0.id == confirmedID && $0.status == .open })
        let draft = try #require(todos.first { $0.title == "TODO" })
        #expect(draft.status == .draft)
        #expect(draft.id != confirmedID)
        #expect(draft.sourceUtteranceIDs.isEmpty)
        #expect(draft.sourceMemoIDs.isEmpty)
    }

    @Test("スリープ中は再接続せず、復帰後に記録意図を保って再接続する")
    @MainActor
    func sleepWakeKeepsCaptureIntent() async {
        let coordinator = LifeLogCoordinator()
        coordinator.setCaptureEnabled(true)
        coordinator.systemWillSleep()
        #expect(coordinator.isRecoveringCapture)
        #expect(!coordinator.isCapturing)

        coordinator.systemDidWake()
        #expect(coordinator.isRecoveringCapture)
        coordinator.setCaptureEnabled(false)
        #expect(!coordinator.isRecoveringCapture)
    }

    @Test("ボイスメモ中だけcaptureを止め、終了後に記録意図から再接続する")
    @MainActor
    func voiceMemoSuspensionKeepsCaptureIntent() async {
        let coordinator = LifeLogCoordinator()
        coordinator.setCaptureEnabled(true)

        #expect(await coordinator.suspendForVoiceMemo(timeout: .seconds(1)))
        #expect(coordinator.isSuspendedForVoiceMemo)
        #expect(coordinator.captureStatusText == "ボイスメモ中は一時停止")
        #expect(coordinator.hasPendingTerminationWork)

        coordinator.resumeAfterVoiceMemo()
        #expect(!coordinator.isSuspendedForVoiceMemo)
        #expect(coordinator.isRecoveringCapture)
        coordinator.setCaptureEnabled(false)
    }

    @Test("音声構成変更は再試行し、マイク権限拒否だけは再試行しない")
    @MainActor
    func captureRetryPolicy() {
        #expect(LifeLogCoordinator.shouldRetryCapture(after: ContinuousAudioCapture.Failure.configurationChanged))
        #expect(!LifeLogCoordinator.shouldRetryCapture(after: ContinuousAudioCapture.Failure.microphoneDenied))
        #expect(LifeLogCoordinator.shouldRetryCapture(after: ContinuousAudioCapture.Failure.noInputDevice))
    }

    @Test("発話checkpointは現在のaudioを確定して次のchunkを継続する")
    func audioCheckpointCommitsAndContinues() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "koe-audio-checkpoint-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let (chunks, continuation) = AsyncStream<LifeLogAudioChunk>.makeStream()
        let failure = Mutex<String?>(nil)
        let format = AudioFormats.lifeLogStorage
        guard let writer = DurableAudioChunkWriter(
            root: root,
            inputFormat: format,
            committed: { continuation.yield($0) },
            finished: { continuation.finish() },
            failed: { error in
                failure.withLock { $0 = error.localizedDescription }
                continuation.finish()
            }
        ) else {
            Issue.record("audio writerを作成できません")
            return
        }
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try writer.start(at: startedAt)
        writer.append(try Self.audioBuffer(format: format, duration: 0.2))
        writer.rotate(at: startedAt.addingTimeInterval(0.2))
        writer.append(try Self.audioBuffer(format: format, duration: 0.2))
        writer.finish(at: startedAt.addingTimeInterval(0.4))

        var committed: [LifeLogAudioChunk] = []
        for await chunk in chunks { committed.append(chunk) }

        #expect(failure.withLock { $0 } == nil)
        #expect(committed.count == 2)
        #expect(committed.allSatisfy { FileManager.default.fileExists(atPath: $0.localPath) })
        let partials = try FileManager.default.contentsOfDirectory(
            at: root.appending(path: LifeLogDateKey.string(for: startedAt)).appending(path: "audio"),
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.contains(".partial.m4a") }
        #expect(partials.isEmpty)
    }

    @Test("audio checkpointの保存先失敗を呼び出し元へ返す")
    func audioCheckpointSurfacesStartFailure() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "koe-audio-checkpoint-file-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(FileManager.default.createFile(atPath: root.path, contents: Data()))
        guard let writer = DurableAudioChunkWriter(
            root: root,
            inputFormat: AudioFormats.lifeLogStorage,
            committed: { _ in },
            finished: {},
            failed: { _ in }
        ) else {
            Issue.record("audio writerを作成できません")
            return
        }
        #expect(throws: (any Error).self) {
            try writer.start(at: Date(timeIntervalSince1970: 1_800_000_000))
        }
    }

    private static func audioBuffer(format: AVAudioFormat, duration: TimeInterval) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(format.sampleRate * duration)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        guard let channel = buffer.floatChannelData?[0] else {
            throw EngineError.failed("test audio bufferを作成できません")
        }
        channel.initialize(repeating: 0.1, count: Int(frames))
        return buffer
    }

    @Test("終了待ちは記録開始要求の隙間も含み、停止後に解除される")
    @MainActor
    func terminationWorkTracksCaptureIntent() {
        let coordinator = LifeLogCoordinator()
        #expect(!coordinator.hasPendingTerminationWork)

        coordinator.setCaptureEnabled(true)
        #expect(coordinator.hasPendingTerminationWork)

        coordinator.setCaptureEnabled(false)
        #expect(!coordinator.hasPendingTerminationWork)
    }

    @Test("未処理音声は再起動後のqueueに残る")
    func pendingAudioSurvives() async throws {
        let database = try await KoeDatabase.inMemory()
        var chunk = LifeLogAudioChunk(captureStartedAt: Date(timeIntervalSince1970: 100),
                                      captureEndedAt: Date(timeIntervalSince1970: 160), localPath: "/tmp/chunk.m4a")
        try await database.lifeLog.save(audioChunk: chunk)
        #expect(try await database.lifeLog.pendingAudioChunks().map(\.id) == [chunk.id])

        chunk.transcriptionState = .transcribed
        try await database.lifeLog.save(audioChunk: chunk)
        #expect(try await database.lifeLog.pendingAudioChunks().map(\.id) == [chunk.id])

        chunk.processingState = .extracted
        try await database.lifeLog.save(audioChunk: chunk)
        #expect(try await database.lifeLog.pendingAudioChunks().isEmpty)
    }

    @Test("処理済み音声だけが保持policyの削除対象になる")
    func onlyProcessedAudioIsDeletable() async throws {
        let database = try await KoeDatabase.inMemory()
        let oldStart = Date(timeIntervalSince1970: 100)
        let recentStart = Date(timeIntervalSince1970: 300)
        let processedOld = LifeLogAudioChunk(
            id: "processed-old", captureStartedAt: oldStart, captureEndedAt: oldStart.addingTimeInterval(30),
            localPath: "/tmp/processed-old.m4a", transcriptionState: .transcribed, processingState: .extracted
        )
        let processedRecent = LifeLogAudioChunk(
            id: "processed-recent", captureStartedAt: recentStart, captureEndedAt: recentStart.addingTimeInterval(30),
            localPath: "/tmp/processed-recent.m4a", transcriptionState: .transcribed, processingState: .extracted
        )
        let pending = LifeLogAudioChunk(
            id: "pending", captureStartedAt: oldStart, captureEndedAt: oldStart.addingTimeInterval(30),
            localPath: "/tmp/pending.m4a"
        )
        let failed = LifeLogAudioChunk(
            id: "failed", captureStartedAt: oldStart, captureEndedAt: oldStart.addingTimeInterval(30),
            localPath: "/tmp/failed.m4a", transcriptionState: .failed, processingState: .failed,
            failureReason: "test"
        )
        for chunk in [processedOld, processedRecent, pending, failed] {
            try await database.lifeLog.save(audioChunk: chunk)
        }

        let processedOnly = try await database.lifeLog.deletableAudioFileURLs(endedBefore: nil)
        #expect(Set(processedOnly.map(\.path)) == [processedOld.localPath, processedRecent.localPath])

        let retainedForDays = try await database.lifeLog.deletableAudioFileURLs(
            endedBefore: Date(timeIntervalSince1970: 250)
        )
        #expect(retainedForDays.map(\.path) == [processedOld.localPath])
    }

    @Test("1秒未満の音声はSpeechAnalyzerへ渡さない境界である")
    func subsecondCaptureBoundary() {
        let start = Date(timeIntervalSince1970: 100)
        let short = LifeLogAudioChunk(
            captureStartedAt: start,
            captureEndedAt: start.addingTimeInterval(0.99),
            localPath: "/tmp/short.m4a"
        )
        let long = LifeLogAudioChunk(
            captureStartedAt: start,
            captureEndedAt: start.addingTimeInterval(1),
            localPath: "/tmp/long.m4a"
        )
        #expect(!short.isTranscriptionCandidate)
        #expect(long.isTranscriptionCandidate)
        #expect(!LifeLogAudioChunk(captureStartedAt: start, captureEndedAt: start.addingTimeInterval(30),
                                  localPath: "/tmp/silent.m4a", peakLevel: 0.01).isTranscriptionCandidate)
        #expect(LifeLogAudioChunk(captureStartedAt: start, captureEndedAt: start.addingTimeInterval(30),
                                 localPath: "/tmp/quiet-speech.m4a", peakLevel: 0.03).isTranscriptionCandidate)
    }

    @Test("calendarは参考値として扱い、時間gapだけがconversationを分ける")
    func segmentsAtOperationalBoundaries() {
        let base = Date(timeIntervalSince1970: 1_000)
        let values = [
            LifeLogUtterance(startedAt: base, endedAt: base.addingTimeInterval(5), text: "a", audioChunkID: "c", calendarEventID: "event-a"),
            LifeLogUtterance(startedAt: base.addingTimeInterval(20), endedAt: base.addingTimeInterval(25), text: "b", audioChunkID: "c", calendarEventID: "event-a"),
            LifeLogUtterance(startedAt: base.addingTimeInterval(30), endedAt: base.addingTimeInterval(35), text: "c", audioChunkID: "c", calendarEventID: "event-b"),
            LifeLogUtterance(startedAt: base.addingTimeInterval(200), endedAt: base.addingTimeInterval(205), text: "d", audioChunkID: "c", calendarEventID: "event-b"),
        ]
        let groups = ConversationSegmenter(maximumGap: 90).segment(values)
        #expect(groups.map { $0.1.count } == [3, 1])
        #expect(groups.allSatisfy { group in group.1.allSatisfy { $0.conversationID == group.0.id } })
    }

    @Test("TODOはglobalに保存し、既存の出典情報を損なわない")
    func todoKeepsProvenance() async throws {
        let database = try await KoeDatabase.inMemory()
        let todo = LifeLogTodo(title: "RFCを書く", sourceConversationID: "conversation",
                              sourceUtteranceIDs: ["utterance"], sourceMemoIDs: ["memo"], confidence: 0.8)
        try await database.lifeLog.save(todo: todo)
        let stored = try #require(await database.lifeLog.todos().first)
        #expect(stored.sourceUtteranceIDs == ["utterance"])
        #expect(stored.sourceConversationID == "conversation")
        #expect(stored.sourceMemoIDs == ["memo"])
    }

    @Test("予定時刻は最も近いtimeline項目へ、検索結果は該当項目へ移動する")
    @MainActor
    func timelineNavigationTargetsExpectedItem() async throws {
        let database = try await KoeDatabase.inMemory()
        let coordinator = LifeLogCoordinator()
        let base = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 60 * 60)
        let before = LifeLogMemo(id: "before", createdAt: base.addingTimeInterval(-300), text: "前")
        let after = LifeLogMemo(id: "after", createdAt: base.addingTimeInterval(60), text: "後")
        try await database.lifeLog.save(memo: before)
        try await database.lifeLog.save(memo: after)
        await coordinator.configure(
            database: database,
            engines: EngineRegistry(),
            vocabulary: { [] },
            todoPrompt: { "" },
            summaryPrompt: { "" },
            summaryIntervalMinutes: { 60 },
            participatingEventsOnly: { true },
            audioProcessingCompleted: {}
        )

        await coordinator.jumpToTime(base)
        #expect(coordinator.highlightedTimelineItemID == "m-after")

        await coordinator.jumpToSearchResult(LifeLogSearchResult(
            id: "memo-before",
            kind: .memo,
            text: before.text,
            occurredAt: before.createdAt,
            day: LifeLogDateKey.string(for: before.createdAt)
        ))
        #expect(coordinator.highlightedTimelineItemID == "m-before")
        #expect(coordinator.sourceNavigationRevision == 2)
    }

    @Test("メモは発話と分離して保存され、日付境界で正しい日に入る")
    func memosAreTypedAndPartitionedByDay() async throws {
        let database = try await KoeDatabase.inMemory()
        let firstDay = Calendar.current.startOfDay(for: Date())
        let nextDay = try #require(Calendar.current.date(byAdding: .day, value: 1, to: firstDay))
        try await database.lifeLog.save(memo: LifeLogMemo(id: "before", createdAt: nextDay.addingTimeInterval(-1), text: "日付前"))
        try await database.lifeLog.save(memo: LifeLogMemo(id: "after", createdAt: nextDay.addingTimeInterval(1), text: "日付後"))

        let before = try await database.lifeLog.day(firstDay)
        let after = try await database.lifeLog.day(nextDay)
        #expect(before.memos.map(\.id) == ["before"])
        #expect(after.memos.map(\.id) == ["after"])
        #expect(before.utterances.isEmpty && after.utterances.isEmpty)
    }

    @Test("一つの連続録音が日付をまたいでも発話は実時刻の日に分かれる")
    func continuousCapturePartitionsUtterancesAcrossMidnight() async throws {
        let database = try await KoeDatabase.inMemory()
        let firstDay = Calendar.current.startOfDay(for: Date())
        let midnight = try #require(Calendar.current.date(byAdding: .day, value: 1, to: firstDay))
        let chunk = LifeLogAudioChunk(captureStartedAt: midnight.addingTimeInterval(-20),
                                      captureEndedAt: midnight.addingTimeInterval(20),
                                      localPath: "/tmp/cross-midnight.m4a", peakLevel: 0.4)
        try await database.lifeLog.save(audioChunk: chunk)
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "before-midnight",
            startedAt: midnight.addingTimeInterval(-10), endedAt: midnight.addingTimeInterval(-2),
            text: "前日", audioChunkID: chunk.id))
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "after-midnight",
            startedAt: midnight.addingTimeInterval(2), endedAt: midnight.addingTimeInterval(10),
            text: "翌日", audioChunkID: chunk.id))

        #expect(try await database.lifeLog.day(firstDay).utterances.map(\.id) == ["before-midnight"])
        #expect(try await database.lifeLog.day(midnight).utterances.map(\.id) == ["after-midnight"])
    }

    @Test("再要約はDraftだけを置き換え、確定TODOを保つ")
    func summaryReplacesOnlyDraftTodos() async throws {
        let database = try await KoeDatabase.inMemory()
        let date = Date(timeIntervalSince1970: 1_725_158_400)
        try await database.lifeLog.save(todo: LifeLogTodo(id: "confirmed", title: "確定", status: .open))
        try await database.lifeLog.save(todo: LifeLogTodo(id: "old-draft", title: "古い案", status: .draft))
        let summary = DailySummary(day: LifeLogDateKey.string(for: date), summary: "更新", commitments: [], topics: [],
                                   calendarEventCount: 0, capturedDurationSeconds: 0, utteranceCount: 0,
                                   summarizedThrough: date, isFinal: false)
        try await database.lifeLog.save(summary: summary, replacingDrafts: [
            LifeLogTodo(id: "new-draft", title: "新しい案", status: .draft)
        ])

        let todos = try await database.lifeLog.todos()
        #expect(todos.contains { $0.id == "confirmed" && $0.status == .open })
        #expect(todos.contains { $0.id == "new-draft" && $0.status == .draft })
        #expect(!todos.contains { $0.id == "old-draft" })
    }

    @Test("SummaryとTODOはLLMのJSON出力から型付き派生データになる")
    func llmDerivation() async throws {
        let llm = RecordingLifeLogLlm()
        let service = LifeLogDerivationService(llm: llm)
        let utterance = LifeLogUtterance(startedAt: Date(), endedAt: Date(), text: "RFCを書きます", audioChunkID: "audio")
        #expect(try await service.extractTodoTitles(from: [utterance], prompt: "抽出") == ["TODO"])
        #expect(llm.recordedPrompts.last?.output == .json(.init(name: "life_log_todos", fields: [
            .init("todos", .stringArray),
        ])))
        let summary = try await service.summarize(
            day: LifeLogDay(utterances: [utterance], conversations: [], calendarEvents: [], summary: nil),
            prompt: "要約"
        )
        #expect(summary == LifeLogDerivedSummary(text: "全体", topics: ["話題"], todoTitles: ["TODO"]))
        #expect(llm.recordedPrompts.last?.output == .json(.init(name: "life_log_summary", fields: [
            .init("summary", .string),
            .init("topics", .stringArray),
            .init("todos", .stringArray),
        ])))
    }

    @Test("既存TODOはpromptへ渡し、同じ文言を新しいTODO案から除外する")
    func existingTodosAreNotProposedAgain() async throws {
        let llm = RecordingLifeLogLlm()
        let service = LifeLogDerivationService(llm: llm)
        let utterance = LifeLogUtterance(startedAt: Date(), endedAt: Date(), text: "TODOについて話す", audioChunkID: "audio")

        let summary = try await service.summarize(
            day: LifeLogDay(utterances: [utterance], conversations: [], calendarEvents: [], summary: nil),
            prompt: "要約",
            existingTodoTitles: ["ＴＯＤＯ"]
        )

        #expect(summary.todoTitles.isEmpty)
        #expect(llm.recordedPrompts.last?.system.contains("<existing_todos>\n- ＴＯＤＯ\n</existing_todos>") == true)
    }

    @Test("再要約では当日の全データを時系列でLLMへ渡す")
    func summaryUsesWholeDayTimeline() async throws {
        let llm = RecordingLifeLogLlm()
        let service = LifeLogDerivationService(llm: llm)
        let start = Date(timeIntervalSince1970: 1_725_158_400)
        let oldMarker = "午前の決定-" + String(repeating: "A", count: 180)
        let newMarker = "午後の決定-" + String(repeating: "B", count: 180)
        let day = LifeLogDay(
            utterances: [
                LifeLogUtterance(startedAt: start, endedAt: start.addingTimeInterval(10), text: oldMarker, audioChunkID: "a"),
                LifeLogUtterance(startedAt: start.addingTimeInterval(3_600), endedAt: start.addingTimeInterval(3_610), text: newMarker, audioChunkID: "b"),
            ],
            memos: [LifeLogMemo(createdAt: start.addingTimeInterval(1_800), text: "中間メモ")],
            conversations: [],
            calendarEvents: [CalendarEventSnapshot(title: "朝会", startsAt: start.addingTimeInterval(-600),
                                                   endsAt: start, calendarTitle: "Work")],
            summary: nil
        )

        _ = try await service.summarize(day: day, prompt: "要約")
        let sent = llm.recordedPrompts.map(\.user).joined(separator: "\n")
        #expect(sent.contains(oldMarker))
        #expect(sent.contains(newMarker))
        #expect(sent.contains("中間メモ"))
        #expect(sent.contains("朝会"))
        #expect(!sent.contains("前回の要約"))
    }

    @Test("ライブ要約は予定を基準時点との関係で分類する")
    func liveSummaryLabelsCalendarEventsRelativeToAsOf() async throws {
        let llm = RecordingLifeLogLlm()
        let service = LifeLogDerivationService(llm: llm)
        let asOf = Date(timeIntervalSince1970: 1_800_000_000)
        let day = LifeLogDay(
            utterances: [],
            conversations: [],
            calendarEvents: [
                CalendarEventSnapshot(title: "終了した予定", startsAt: asOf.addingTimeInterval(-7_200), endsAt: asOf.addingTimeInterval(-3_600), calendarTitle: "Work"),
                CalendarEventSnapshot(title: "進行中の予定", startsAt: asOf.addingTimeInterval(-600), endsAt: asOf.addingTimeInterval(600), calendarTitle: "Work"),
                CalendarEventSnapshot(title: "これからの予定", startsAt: asOf.addingTimeInterval(3_600), endsAt: asOf.addingTimeInterval(7_200), calendarTitle: "Work"),
            ],
            summary: nil
        )

        _ = try await service.summarize(day: day, prompt: "要約", asOf: asOf)
        let user = llm.recordedPrompts.map(\.user).joined(separator: "\n")
        let system = llm.recordedPrompts.map(\.system).joined(separator: "\n")
        #expect(user.contains("[予定・終了済み"))
        #expect(user.contains("[予定・進行中"))
        #expect(user.contains("[予定・これから"))
        #expect(system.contains("未実施の予定として未来形"))
    }

    @Test("日付変更後は差分がなくても全予定から最終要約を作り直す")
    @MainActor
    func pastDayFinalizationIncludesAllCalendarEvents() async throws {
        let database = try await KoeDatabase.inMemory()
        let llm = RecordingLifeLogLlm()
        let coordinator = LifeLogCoordinator()
        let calendar = Calendar.current
        let now = Date()
        let date = try #require(calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)))
        let eventStart = date.addingTimeInterval(18 * 3_600)
        try await database.lifeLog.save(calendarEvents: [CalendarEventSnapshot(
            title: "夕方の予定", startsAt: eventStart, endsAt: eventStart.addingTimeInterval(3_600), calendarTitle: "Work"
        )])
        try await database.lifeLog.save(summary: DailySummary(
            day: LifeLogDateKey.string(for: date), summary: "途中", commitments: [], topics: [],
            calendarEventCount: 1, capturedDurationSeconds: 0, utteranceCount: 0,
            summarizedThrough: date, isFinal: false
        ))

        try await coordinator.updateSummary(
            for: date, respectingInterval: true, now: now,
            store: database.lifeLog, derivation: LifeLogDerivationService(llm: llm)
        )

        #expect(llm.recordedPrompts.map(\.user).joined().contains("夕方の予定"))
        #expect(try await database.lifeLog.day(date).summary?.isFinal == true)
    }

    @Test("月間activityは予定と発話の密度を日別に保つ")
    func monthlyActivity() async throws {
        let database = try await KoeDatabase.inMemory()
        let calendar = Calendar(identifier: .gregorian)
        let start = Date(timeIntervalSince1970: 1_725_158_400)
        let chunk = LifeLogAudioChunk(captureStartedAt: start, captureEndedAt: start.addingTimeInterval(120), localPath: "/tmp/activity.m4a")
        try await database.lifeLog.save(audioChunk: chunk)
        try await database.lifeLog.save(utterance: LifeLogUtterance(startedAt: start, endedAt: start.addingTimeInterval(120), text: "test", audioChunkID: chunk.id))
        try await database.lifeLog.save(calendarEvents: [CalendarEventSnapshot(title: "Event", startsAt: start, endsAt: start.addingTimeInterval(3_600), calendarTitle: "Work")])

        let activity = try await database.lifeLog.activity(start: start.addingTimeInterval(-1), end: start.addingTimeInterval(86_400), calendar: calendar)
        let value = try #require(activity[LifeLogDateKey.string(for: start, calendar: calendar)])
        #expect(value.calendarEventCount == 1)
        #expect(value.capturedDuration == 120)
    }

    @Test("参加予定だけの表示では辞退と未回答を除外する")
    func participatingCalendarEventsOnly() async throws {
        let database = try await KoeDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_725_158_400)
        let statuses: [CalendarParticipationStatus] = [.none, .accepted, .pending, .tentative, .declined]
        try await database.lifeLog.save(calendarEvents: statuses.enumerated().map { index, status in
            CalendarEventSnapshot(
                id: "event-\(index)", title: status.rawValue,
                startsAt: start.addingTimeInterval(Double(index)),
                endsAt: start.addingTimeInterval(3_600), calendarTitle: "Work",
                participationStatus: status
            )
        })

        let day = try await database.lifeLog.day(start, participatingOnly: true)
        #expect(day.calendarEvents.map(\.participationStatus) == [.none, .accepted])
    }

    @Test("人向けMarkdown exportは予定・発話・メモを時系列で区別する")
    func textExportPreservesTimelineKinds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 9)))
        let utterance = LifeLogUtterance(
            id: "speech", startedAt: date.addingTimeInterval(120), endedAt: date.addingTimeInterval(150),
            text: "RFCを今日書きます", audioChunkID: "audio"
        )
        let memo = LifeLogMemo(id: "memo", createdAt: date.addingTimeInterval(180), text: "構成を先に決める")
        let day = LifeLogDay(
            utterances: [utterance],
            memos: [memo],
            conversations: [],
            calendarEvents: [CalendarEventSnapshot(
                title: "朝会", startsAt: date, endsAt: date.addingTimeInterval(60),
                calendarTitle: "Work", participationStatus: .accepted
            )],
            summary: nil
        )
        let todo = LifeLogTodo(title: "RFCを書く", createdAt: date.addingTimeInterval(240), sourceUtteranceIDs: [utterance.id])

        let text = LifeLogTextExporter.render(date: date, day: day, todos: [todo], calendar: calendar)

        let calendarIndex = try #require(text.range(of: "**09:00–09:01 予定**"))
        let speechIndex = try #require(text.range(of: "**09:02 発話**"))
        let memoIndex = try #require(text.range(of: "**09:03 メモ**"))
        #expect(calendarIndex.lowerBound < speechIndex.lowerBound)
        #expect(speechIndex.lowerBound < memoIndex.lowerBound)
        #expect(text.contains("- [ ] RFCを書く（09:04に追加）"))
        #expect(!text.contains("SPEECH"))
        #expect(!text.contains("status=open"))
    }

    @Test("成功した音声入力履歴だけを注釈付きでライフログへ投影する")
    func dictationHistoryAppearsInLifeLogWithoutCopyingIt() async throws {
        let database = try await KoeDatabase.inMemory()
        let startedAt = Date(timeIntervalSince1970: 1_777_777_700)
        let snapshot = ModeSnapshot(modeName: "標準", modePrompt: "", systemPrompt: "", vocabularyCount: 0, trigger: .manual)
        try await database.history.save(SessionRecord(
            id: "voice-input", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(8), status: .completed,
            modeSnapshot: snapshot, sttEngine: EngineIdentifier("speech-analyzer"),
            rawTranscript: "明日の資料を送る", formattedText: "明日の資料を送ります。"
        ))
        try await database.history.save(SessionRecord(
            id: "cancelled", startedAt: startedAt.addingTimeInterval(10), status: .cancelled,
            modeSnapshot: snapshot, sttEngine: EngineIdentifier("speech-analyzer"), rawTranscript: "取り消した入力"
        ))

        let day = try await database.lifeLog.day(startedAt)
        #expect(day.dictations.map(\.id) == ["voice-input"])
        #expect(day.dictations.first?.text == "明日の資料を送る")
        let export = LifeLogTextExporter.render(date: startedAt, day: day, todos: [])
        #expect(export.contains("音声入力**"))
        #expect(export.contains("明日の資料を送る"))
        #expect(!export.contains("取り消した入力"))
        #expect(!LifeLogDerivationService.timelineItems(day: day).contains { $0.contains("明日の資料を送る") })
    }

    @Test("成功した音声入力の実録音区間はライフログ発話より優先される")
    func successfulDictationSuppressesOverlappingLifeLogUtterance() async throws {
        let database = try await KoeDatabase.inMemory()
        let startedAt = Date(timeIntervalSince1970: 1_777_777_700)
        let chunk = LifeLogAudioChunk(
            id: "audio", captureStartedAt: startedAt, captureEndedAt: startedAt.addingTimeInterval(30),
            localPath: "/tmp/audio.m4a"
        )
        try await database.lifeLog.save(audioChunk: chunk)
        try await database.lifeLog.save(utterance: LifeLogUtterance(
            id: "life-log", startedAt: startedAt.addingTimeInterval(1), endedAt: startedAt.addingTimeInterval(7),
            text: "重複する内容", audioChunkID: chunk.id
        ))
        let snapshot = ModeSnapshot(modeName: "標準", modePrompt: "", systemPrompt: "", vocabularyCount: 0, trigger: .manual)
        try await database.history.save(SessionRecord(
            id: "dictation", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(20), status: .completed,
            modeSnapshot: snapshot, sttEngine: EngineIdentifier("speech-analyzer"),
            rawTranscript: "重複する内容", formattedText: "重複する内容", audioDurationMs: 8_000
        ))

        let day = try await database.lifeLog.day(startedAt)
        #expect(day.utterances.isEmpty)
        #expect(day.dictations.map(\.id) == ["dictation"])
        let results = try await database.lifeLog.search("重複する内容")
        #expect(results.map(\.kind) == [.dictation])
    }

    @Test("cancelした音声入力はライフログ発話を隠さない")
    func cancelledDictationKeepsLifeLogUtterance() async throws {
        let database = try await KoeDatabase.inMemory()
        let startedAt = Date(timeIntervalSince1970: 1_777_777_700)
        let chunk = LifeLogAudioChunk(
            id: "audio", captureStartedAt: startedAt, captureEndedAt: startedAt.addingTimeInterval(30),
            localPath: "/tmp/audio.m4a"
        )
        try await database.lifeLog.save(audioChunk: chunk)
        try await database.lifeLog.save(utterance: LifeLogUtterance(
            id: "life-log", startedAt: startedAt.addingTimeInterval(1), endedAt: startedAt.addingTimeInterval(7),
            text: "残す内容", audioChunkID: chunk.id
        ))
        let snapshot = ModeSnapshot(modeName: "標準", modePrompt: "", systemPrompt: "", vocabularyCount: 0, trigger: .manual)
        try await database.history.save(SessionRecord(
            id: "cancelled", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(8), status: .cancelled,
            modeSnapshot: snapshot, sttEngine: EngineIdentifier("speech-analyzer"),
            rawTranscript: "残す内容", audioDurationMs: 8_000
        ))

        #expect(try await database.lifeLog.day(startedAt).utterances.map(\.id) == ["life-log"])
    }

    @Test("日別exportは項目ごとの選択と当日作成・完了TODOを尊重する")
    func textExportHonorsSelectionAndTodoBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 9)))
        let day = LifeLogDay(
            utterances: [.init(startedAt: date, endedAt: date, text: "発話", audioChunkID: "audio")],
            dictations: [.init(id: "dictation", startedAt: date, endedAt: date, text: "除外する音声入力")],
            memos: [.init(createdAt: date, text: "メモ")],
            conversations: [],
            calendarEvents: [.init(title: "予定", startsAt: date, endsAt: date, calendarTitle: "Work")],
            summary: .init(day: "2026-08-29", summary: "要約", commitments: [], topics: [], calendarEventCount: 1, capturedDurationSeconds: 1, utteranceCount: 1, summarizedThrough: date, isFinal: true)
        )
        let todos = [
            LifeLogTodo(title: "対象", createdAt: date),
            LifeLogTodo(title: "完了", status: .completed, createdAt: date),
            LifeLogTodo(title: "下書き", status: .draft, createdAt: date),
            LifeLogTodo(title: "別日", createdAt: date.addingTimeInterval(-86_400)),
        ]
        let options = LifeLogTextExporter.Options(
            includesCalendarEvents: false,
            includesUtterances: true,
            includesDictations: false,
            includesMemos: false,
            includesSummary: true,
            includesTodosForDay: true
        )

        let text = LifeLogTextExporter.render(date: date, day: day, todos: todos, options: options, calendar: calendar)

        #expect(text.contains("要約"))
        #expect(text.contains("発話** 発話"))
        #expect(text.contains("対象"))
        #expect(!text.contains("予定**"))
        #expect(!text.contains("メモ**"))
        #expect(!text.contains("除外する音声入力"))
        #expect(text.contains("- [x] 完了"))
        #expect(text.contains("完了"))
        #expect(!text.contains("下書き"))
        #expect(!text.contains("別日"))
    }

    @Test("音声入力だけではsummaryとTODOを生成しない")
    @MainActor
    func dictationDoesNotTriggerDerivation() async throws {
        let database = try await KoeDatabase.inMemory()
        let date = Date()
        let snapshot = ModeSnapshot(modeName: "標準", modePrompt: "", systemPrompt: "", vocabularyCount: 0, trigger: .manual)
        try await database.history.save(SessionRecord(
            id: "dictation-only", startedAt: date, endedAt: date.addingTimeInterval(5), status: .completed,
            modeSnapshot: snapshot, sttEngine: EngineIdentifier("speech-analyzer"),
            rawTranscript: "明日の資料を送ってください", formattedText: "明日の資料を送ってください"
        ))
        let llm = RecordingLifeLogLlm()
        try await LifeLogCoordinator().updateSummary(
            for: date,
            respectingInterval: false,
            store: database.lifeLog,
            derivation: LifeLogDerivationService(llm: llm)
        )

        #expect(llm.recordedPrompts.isEmpty)
        #expect(try await database.lifeLog.day(date).summary == nil)
        #expect(try await database.lifeLog.todos().isEmpty)
    }

    @Test("全TODO exportは確定済み未実施だけを含む")
    func openTodoExport() {
        let text = LifeLogTextExporter.renderOpenTodos([
            LifeLogTodo(title: "未実施"),
            LifeLogTodo(title: "完了", status: .completed),
            LifeLogTodo(title: "下書き", status: .draft),
        ])
        #expect(text.contains("未実施"))
        #expect(!text.contains("完了"))
        #expect(!text.contains("下書き"))
    }

    @Test("日別書き出しのファイル名は対象日を展開する")
    func lifeLogExportFilenameExpandsDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30)))

        #expect(try LifeLogExportFilename.resolve(
            template: "lifelog-{{date}}.md",
            date: date,
            calendar: calendar
        ) == "lifelog-20260830.md")
    }

    @Test("日別書き出しのファイル名からフォルダ外へ出られない")
    func lifeLogExportFilenameRejectsPathAndUnknownPlaceholder() throws {
        let date = Date(timeIntervalSince1970: 1_777_777_700)
        #expect(throws: LifeLogExportFilenameError.pathComponent) {
            try LifeLogExportFilename.resolve(template: "../lifelog-{{date}}.md", date: date)
        }
        #expect(throws: LifeLogExportFilenameError.unknownPlaceholder) {
            try LifeLogExportFilename.resolve(template: "lifelog-{{day}}.md", date: date)
        }
    }

    @Test("日本語trigram検索は発話・メモ・TODO・要約を横断し短い語にも対応する")
    func japaneseLifeLogSearch() async throws {
        let database = try await KoeDatabase.inMemory()
        let date = Date(timeIntervalSince1970: 1_725_158_400)
        try await database.lifeLog.save(audioChunk: .init(
            id: "audio", captureStartedAt: date, captureEndedAt: date, localPath: "/tmp/search.m4a"
        ))
        try await database.lifeLog.save(utterance: .init(
            id: "utterance", startedAt: date, endedAt: date, text: "レセコンの移行を相談した", audioChunkID: "audio"
        ))
        try await database.lifeLog.save(memo: .init(id: "memo", createdAt: date, text: "診療報酬の確認"))
        try await database.lifeLog.save(todo: .init(id: "todo", title: "請求データを確認", createdAt: date))
        try await database.lifeLog.save(summary: .init(
            day: LifeLogDateKey.string(for: date), summary: "移行計画を整理した", commitments: ["来週共有"], topics: ["レセプト"],
            calendarEventCount: 0, capturedDurationSeconds: 1, utteranceCount: 1, summarizedThrough: date, isFinal: false
        ))

        #expect(try await database.lifeLog.search("レセコン").map(\.kind) == [.utterance])
        #expect(try await database.lifeLog.search("診療").map(\.kind) == [.memo])
        #expect(try await database.lifeLog.search("請求").map(\.kind) == [.todo])
        #expect(try await database.lifeLog.search("移行計画").map(\.kind).contains(.summary))
        #expect(try await database.lifeLog.search("共有").map(\.kind) == [.summary])
    }

    @MainActor
    @Test("自動化サービスはTODO操作とプロンプト変更を共通境界で扱う")
    func automationServiceMutations() async throws {
        let database = try await KoeDatabase.inMemory()
        let suite = #function
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = AppSettings(defaults: defaults)
        let service = KoeAutomationService(database: database, settings: settings)

        let added = try await service.addTodo(title: "自動化を確認")
        #expect(try await service.todos(status: .open).map(\.id) == [added.id])
        let completed = try await service.updateTodo(id: added.id, status: .completed)
        #expect(completed.status == .completed)
        #expect(completed.completedAt != nil)
        #expect(try await database.lifeLog.todo(id: added.id)?.completedAt != nil)
        let reopened = try await service.updateTodo(id: added.id, status: .open)
        #expect(reopened.status == .open)
        #expect(reopened.completedAt == nil)
        try await service.deleteTodo(id: added.id)
        #expect(try await service.todos().isEmpty)

        try service.setPrompt("新しい要約プロンプト", kind: .summary)
        #expect(service.prompt(.summary) == "新しい要約プロンプト")
    }

    @MainActor
    @Test("旧標準要約プロンプトだけを新標準へ更新し、カスタム値は保つ")
    func migratesOnlyLegacySummaryPrompt() throws {
        let legacySuite = #function + ".legacy"
        let legacyDefaults = try #require(UserDefaults(suiteName: legacySuite))
        legacyDefaults.removePersistentDomain(forName: legacySuite)
        var legacyStorage = AppSettings.Storage()
        legacyStorage.lifeLogSummaryPrompt = BuiltinLifeLogPrompts.legacySummary
        legacyDefaults.set(try JSONEncoder().encode(legacyStorage), forKey: AppSettings.defaultsKey)

        let migrated = AppSettings(defaults: legacyDefaults)
        #expect(migrated.lifeLogSummaryPrompt == BuiltinLifeLogPrompts.summary)
        #expect(migrated.lifeLogSummaryPrompt != BuiltinLifeLogPrompts.legacySummary)

        let customSuite = #function + ".custom"
        let customDefaults = try #require(UserDefaults(suiteName: customSuite))
        customDefaults.removePersistentDomain(forName: customSuite)
        var customStorage = AppSettings.Storage()
        customStorage.lifeLogSummaryPrompt = "自分用の日報プロンプト"
        customDefaults.set(try JSONEncoder().encode(customStorage), forKey: AppSettings.defaultsKey)

        let preserved = AppSettings(defaults: customDefaults)
        #expect(preserved.lifeLogSummaryPrompt == "自分用の日報プロンプト")
    }

    @Test("ライフログ削除はすべての派生データとsource of truthを同時に消す")
    func deleteAllLifeLogData() async throws {
        let database = try await KoeDatabase.inMemory()
        let start = Date(timeIntervalSince1970: 1_725_158_400)
        let chunk = LifeLogAudioChunk(
            id: "audio", captureStartedAt: start, captureEndedAt: start.addingTimeInterval(30),
            localPath: "/tmp/delete-all-life-log.m4a"
        )
        try await database.lifeLog.save(audioChunk: chunk)
        try await database.lifeLog.save(utterance: LifeLogUtterance(
            startedAt: start, endedAt: start.addingTimeInterval(10), text: "発話", audioChunkID: chunk.id
        ))
        try await database.lifeLog.save(memo: LifeLogMemo(createdAt: start, text: "メモ"))
        try await database.lifeLog.save(calendarEvents: [CalendarEventSnapshot(
            title: "予定", startsAt: start, endsAt: start.addingTimeInterval(60), calendarTitle: "Work"
        )])
        try await database.lifeLog.save(todo: LifeLogTodo(title: "TODO"))

        try await database.lifeLog.deleteAll()

        let day = try await database.lifeLog.day(start)
        #expect(day.utterances.isEmpty)
        #expect(day.memos.isEmpty)
        #expect(day.calendarEvents.isEmpty)
        #expect(day.summary == nil)
        #expect(try await database.lifeLog.todos().isEmpty)
        #expect(try await database.lifeLog.pendingAudioChunks().isEmpty)
    }
}

@Suite("発話burstの適応的な確定")
struct AdaptiveSpeechSegmenterTests {
    private func calibrated(noiseLevel: Float = 0.01) -> AdaptiveSpeechSegmenter {
        var segmenter = AdaptiveSpeechSegmenter()
        for _ in 0..<10 {
            #expect(segmenter.consume(level: noiseLevel, duration: 0.1) == .ignore)
        }
        return segmenter
    }

    @Test("長い発話だけ確定無音を短くする")
    func silenceThresholdTiers() {
        #expect(AdaptiveSpeechSegmenter.requiredSilence(afterVoicedDuration: 2.9) == 1.5)
        #expect(AdaptiveSpeechSegmenter.requiredSilence(afterVoicedDuration: 10) == 1.5)
        #expect(AdaptiveSpeechSegmenter.requiredSilence(afterVoicedDuration: 30) == 1)
    }

    @Test("無音だけでは認識を開始しない")
    func silenceDoesNotStartBurst() {
        var segmenter = calibrated()
        #expect(segmenter.consume(level: 0.01, duration: 60) == .ignore)
        let didFinish = segmenter.finish()
        #expect(!didFinish)
    }

    @Test("小さい声も発話として開始し、短い発話は1.5秒の無音で確定する")
    func quietShortSpeechFlushesAfterOneAndHalfSeconds() {
        var segmenter = calibrated(noiseLevel: 0.005)
        #expect(segmenter.consume(level: 0.025, duration: 0.15) == .ignore)
        #expect(segmenter.consume(level: 0.04, duration: 0.1) == .started)
        #expect(segmenter.consume(level: 0.01, duration: 1) == .buffer)
        #expect(segmenter.consume(level: 0.01, duration: 0.5) == .flush)
        #expect(!segmenter.isActive)
        #expect(segmenter.completedBurstEvidence?.isTranscriptionCandidate == false)
    }

    @Test("0.5秒以上かつ20%以上の有声区間だけSTT候補にする")
    func transcriptionEvidenceRequiresEnoughSpeech() {
        #expect(!SpeechBurstEvidence(
            voicedDuration: 0.49,
            burstDuration: 1,
            peakSpeechLevel: 0.2
        ).isTranscriptionCandidate)
        #expect(!SpeechBurstEvidence(
            voicedDuration: 0.5,
            burstDuration: 2.51,
            peakSpeechLevel: 0.2
        ).isTranscriptionCandidate)
        #expect(SpeechBurstEvidence(
            voicedDuration: 0.5,
            burstDuration: 2.5,
            peakSpeechLevel: 0.2
        ).isTranscriptionCandidate)
    }

    @Test("30秒以上の発話は1秒の無音で確定する")
    func longSpeechFlushesAfterOneSecond() {
        var segmenter = calibrated()
        #expect(segmenter.consume(level: 0.05, duration: 0.15) == .ignore)
        #expect(segmenter.consume(level: 0.2, duration: 0.1) == .started)
        #expect(segmenter.consume(level: 0.2, duration: 30.75) == .buffer)
        #expect(segmenter.consume(level: 0.01, duration: 0.5) == .buffer)
        #expect(segmenter.consume(level: 0.01, duration: 0.5) == .flush)
        #expect(!segmenter.isActive)
    }

    @Test("連続入力は5分で安全に確定する")
    func maximumBurstDurationFlushes() {
        var segmenter = calibrated()
        #expect(segmenter.consume(level: 0.05, duration: 0.15) == .ignore)
        #expect(segmenter.consume(level: 0.2, duration: 0.1) == .started)
        #expect(segmenter.consume(level: 0.2, duration: 299.75) == .flush)
    }

    @Test("停止時は発話を含む未確定burstだけを処理する")
    func finishOnlyFlushesSpeech() {
        var segmenter = calibrated()
        _ = segmenter.consume(level: 0.05, duration: 0.15)
        _ = segmenter.consume(level: 0.2, duration: 0.1)
        let firstFinish = segmenter.finish()
        let secondFinish = segmenter.finish()
        #expect(firstFinish)
        #expect(!secondFinish)
    }

    @Test("一定のbackground noiseは閾値を超えても発話にしない")
    func stableBackgroundNoiseDoesNotStartBurst() {
        var segmenter = calibrated(noiseLevel: 0.01)
        for _ in 0..<10 {
            #expect(segmenter.consume(level: 0.04, duration: 0.1) == .ignore)
        }
        #expect(segmenter.noiseFloor > 0.03)
        let didFinish = segmenter.finish()
        #expect(!didFinish)
    }

    @Test("background noiseとの差がある入力が250ms続くと発話を開始する")
    func speechAboveBackgroundStartsBurst() {
        var segmenter = calibrated(noiseLevel: 0.04)
        #expect(segmenter.consume(level: 0.07, duration: 0.15) == .ignore)
        #expect(segmenter.consume(level: 0.1, duration: 0.1) == .started)
    }

    @Test("一瞬のlevel上昇だけでは発話を開始しない")
    func transientNoiseDoesNotStartBurst() {
        var segmenter = calibrated()
        #expect(segmenter.consume(level: 0.08, duration: 0.1) == .ignore)
        #expect(segmenter.consume(level: 0.01, duration: 0.1) == .ignore)
        let didFinish = segmenter.finish()
        #expect(!didFinish)
    }
}

@Suite("Life Log rolling preview")
struct LifeLogRollingPreviewTests {
    private func evidence(voiced: TimeInterval = 1, duration: TimeInterval) -> SpeechBurstEvidence {
        SpeechBurstEvidence(voicedDuration: voiced, burstDuration: duration, peakSpeechLevel: 0.2)
    }

    @Test("whisper.cppは1.5秒後から1.5秒間隔でpreviewする")
    func previewCadence() {
        #expect(!LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 1.49),
            lastPreviewDuration: nil,
            engineIdentifier: .whisperCpp
        ))
        #expect(LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 1.5),
            lastPreviewDuration: nil,
            engineIdentifier: .whisperCpp
        ))
        #expect(!LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 2.9),
            lastPreviewDuration: 1.5,
            engineIdentifier: .whisperCpp
        ))
        #expect(LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 3),
            lastPreviewDuration: 1.5,
            engineIdentifier: .whisperCpp
        ))
    }

    @Test("発話量が足りない候補ではpreviewを起動しない")
    func rejectedEvidenceDoesNotPreview() {
        #expect(!LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(voiced: 0.25, duration: 1.5),
            lastPreviewDuration: nil,
            engineIdentifier: .whisperCpp
        ))
    }

    @Test("SpeechAnalyzerでは二重sessionを作らない")
    func speechAnalyzerDoesNotUseRollingPreview() {
        #expect(!LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 10),
            lastPreviewDuration: nil,
            engineIdentifier: .speechAnalyzer
        ))
    }
}

@Suite("Life Log保存音声の発話回収")
struct LifeLogSavedAudioSpeechGateTests {
    @Test("完全な無音は保存audioでもSTTへ渡さない")
    func silenceIsRejected() throws {
        let chunks = try makeChunks(amplitudes: Array(repeating: 0, count: 30))
        #expect(LifeLogCoordinator.recognizableSpeechBursts(from: chunks).isEmpty)
    }

    @Test("一瞬の生活音だけなら保存audioをSTTへ渡さない")
    func transientNoiseIsRejected() throws {
        let chunks = try makeChunks(
            amplitudes: Array(repeating: 0, count: 10)
                + [0.03, 0.1]
                + Array(repeating: 0, count: 15)
        )
        #expect(LifeLogCoordinator.recognizableSpeechBursts(from: chunks).isEmpty)
    }

    @Test("十分な発話だけを30秒chunkから切り出す")
    func speechIsExtractedWithoutSurroundingSilence() throws {
        let chunks = try makeChunks(
            amplitudes: Array(repeating: 0, count: 10)
                + [0.03, 0.1, 0.1, 0.1, 0.1]
                + Array(repeating: 0, count: 15)
        )
        let bursts = LifeLogCoordinator.recognizableSpeechBursts(from: chunks)
        #expect(bursts.count == 1)
        #expect((bursts.first?.duration ?? 0) < 2.5)
    }

    private func makeChunks(amplitudes: [Float]) throws -> [AudioChunk] {
        let format = AudioFormats.canonical
        let frames = AVAudioFrameCount(format.sampleRate / 10)
        return try amplitudes.enumerated().map { index, amplitude in
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let channel = try #require(buffer.floatChannelData?[0])
            channel.initialize(repeating: amplitude, count: Int(frames))
            return AudioChunk(buffer: buffer, frameOffset: AVAudioFramePosition(index) * AVAudioFramePosition(frames))
        }
    }
}

@Suite("Life Log timeline追従")
struct LifeLogTimelineScrollPolicyTests {
    @Test("末尾付近だけ自動追従対象にする")
    func bottomTolerance() {
        #expect(LifeLogTimelineScrollPolicy.isAtBottom(
            contentOffsetY: 668,
            contentHeight: 1_000,
            containerHeight: 300
        ))
        #expect(!LifeLogTimelineScrollPolicy.isAtBottom(
            contentOffsetY: 600,
            contentHeight: 1_000,
            containerHeight: 300
        ))
        #expect(LifeLogTimelineScrollPolicy.isAtBottom(
            contentOffsetY: 0,
            contentHeight: 200,
            containerHeight: 300
        ))
    }
}

@Suite("Life Log Whisper設定")
struct LifeLogWhisperSettingsTests {
    @Test("取得済みwhisper.cpp modelを設定から削除できる")
    func installedModelCanBeDeleted() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "koe-whisper-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let modelURL = root.appending(path: WhisperModel.largeV3Turbo.fileName)
        #expect(FileManager.default.createFile(atPath: modelURL.path, contents: Data()))
        let handle = try FileHandle(forWritingTo: modelURL)
        try handle.truncate(atOffset: UInt64(WhisperModel.largeV3Turbo.byteCount))
        try handle.close()

        let engine = WhisperCppStt(model: .largeV3Turbo, modelRoot: root)
        #expect(await engine.availability(languagePreference: .ja) == .ready)
        try await engine.deleteInstalledModel()
        #expect(!FileManager.default.fileExists(atPath: modelURL.path))
    }

    @Test("既存設定のWhisperKit選択はwhisper.cppへ引き継ぐ")
    func legacyBackendSelectionUsesWhisperCpp() throws {
        let backend = try JSONDecoder().decode(
            LifeLogSttBackend.self,
            from: Data(#""whisperKit""#.utf8)
        )
        #expect(backend == .whisperCpp)
    }

    @Test("既定modelはLarge v3 Turbo Q5_0 574 MB")
    func turboIsDefault() {
        #expect(AppSettings.Storage().lifeLogWhisperModel == .largeV3Turbo)
        #expect(WhisperModel.largeV3Turbo.fileName == "ggml-large-v3-turbo-q5_0.bin")
        #expect(WhisperModel.largeV3Turbo.byteCount == 574_041_195)
    }

    @Test("whisper.cpp modelは固定hashで検証する")
    func whisperCppModelHasPinnedDigest() {
        #expect(WhisperModel.largeV3Turbo.sha256 == "394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2")
    }
}

private struct StubLifeLogLlm: LlmEngine {
    let identifier = EngineIdentifier.foundationModels
    var modelName: String? { "stub" }
    var inputCharacterBudget: Int { 2_200 }
    func availability() async -> EngineAvailability { .ready }
    func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        if prompt.system.contains("\"summary\"") { return #"{"summary":"RFCの作成を約束した。","topics":["RFC"],"todos":["RFCを書く"]}"# }
        if prompt.system.contains("\"todos\"") { return #"{"todos":["RFCを書く"]}"# }
        return #"{"summary":"RFCの作成を約束した。","topics":["RFC"],"todos":[]}"#
    }
    func unload() async {}
}

private final class RecordingLifeLogLlm: LlmEngine, @unchecked Sendable {
    let identifier = EngineIdentifier.foundationModels
    var modelName: String? { "recording" }
    var inputCharacterBudget: Int { 700 }
    private let prompts = Mutex<[FormattingPrompt]>([])
    var recordedPrompts: [FormattingPrompt] { prompts.withLock { $0 } }

    func availability() async -> EngineAvailability { .ready }
    func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String {
        prompts.withLock { $0.append(prompt) }
        return #"{"summary":"全体","topics":["話題"],"todos":["TODO"]}"#
    }
    func unload() async {}
}
