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

    @Test("録音停止時は差分がなくても一日の全データを再要約する")
    @MainActor
    func stoppedCaptureForcesWholeDaySummary() async throws {
        let database = try await KoeDatabase.inMemory()
        let llm = RecordingLifeLogLlm()
        let coordinator = LifeLogCoordinator()
        let startedAt = Date().addingTimeInterval(-120)
        let endedAt = startedAt.addingTimeInterval(60)
        try await database.lifeLog.save(audioChunk: LifeLogAudioChunk(
            id: "audio", captureStartedAt: startedAt, captureEndedAt: endedAt,
            localPath: "/tmp/already-summarized.m4a"
        ))
        let utterance = LifeLogUtterance(id: "already-summarized", startedAt: startedAt, endedAt: endedAt,
                                         text: "停止前に確定した発話", audioChunkID: "audio")
        try await database.lifeLog.save(utterance: utterance)
        try await database.lifeLog.save(summary: DailySummary(
            day: LifeLogDateKey.string(for: startedAt), summary: "前回", commitments: [], topics: [],
            calendarEventCount: 0, capturedDurationSeconds: 60, utteranceCount: 1,
            summarizedThrough: endedAt, isFinal: false
        ))

        let derivation = LifeLogDerivationService(llm: llm)
        try await coordinator.updateSummary(for: startedAt, respectingInterval: false, store: database.lifeLog,
                                            derivation: derivation)
        #expect(llm.recordedPrompts.isEmpty)

        try await coordinator.updateSummary(for: startedAt, respectingInterval: false, force: true,
                                            store: database.lifeLog, derivation: derivation)
        #expect(llm.recordedPrompts.map(\.user).joined().contains("停止前に確定した発話"))
        #expect(try await database.lifeLog.day(startedAt).summary?.summary == "全体")
        #expect(try await database.lifeLog.todos().first?.sourceUtteranceIDs == [utterance.id])
    }

    @Test("日付をまたぐ録音の停止時は両日を再要約対象にする")
    @MainActor
    func stopAcrossMidnightIncludesEveryDay() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let start = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 23, minute: 59)))
        let end = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 30, hour: 0, minute: 1)))
        #expect(LifeLogCoordinator.daysSpanned(from: start, through: end, calendar: calendar) == [
            calendar.startOfDay(for: start), calendar.startOfDay(for: end),
        ])
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
                                 localPath: "/tmp/quiet-speech.m4a", peakLevel: 0.2).isTranscriptionCandidate)
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

    @Test("TODOは選択日ではなくglobalに保存し出典へ戻れる")
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

    @Test("TODOのmemo出典は対象日を読み込んだ後にtimelineへ案内する")
    @MainActor
    func todoMemoSourceNavigation() async throws {
        let database = try await KoeDatabase.inMemory()
        let coordinator = LifeLogCoordinator()
        let sourceDate = Date(timeIntervalSince1970: 1_777_777_700)
        let memo = LifeLogMemo(id: "source-memo", createdAt: sourceDate, text: "出典メモ")
        try await database.lifeLog.save(memo: memo)
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

        let todo = LifeLogTodo(title: "確認する", sourceMemoIDs: [memo.id])
        await coordinator.jumpToSource(of: todo)

        #expect(Calendar.current.isDate(coordinator.selectedDate, inSameDayAs: sourceDate))
        #expect(coordinator.day.memos.map(\.id) == [memo.id])
        #expect(coordinator.highlightedTimelineItemID == "m-\(memo.id)")
        #expect(coordinator.sourceNavigationRevision == 1)

        await coordinator.jumpToSource(of: todo)
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

    @Test("LLM向けexportは予定・発話・メモを時系列で区別する")
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

        let calendarIndex = try #require(text.range(of: "[CALENDAR 09:00:00-09:01:00"))
        let speechIndex = try #require(text.range(of: "[SPEECH 09:02:00]"))
        let memoIndex = try #require(text.range(of: "[MEMO 09:03:00]"))
        #expect(calendarIndex.lowerBound < speechIndex.lowerBound)
        #expect(speechIndex.lowerBound < memoIndex.lowerBound)
        #expect(text.contains("[TODO status=open created=2026-08-29T09:04:00] RFCを書く"))
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
        #expect(export.contains("[VOICE_INPUT"))
        #expect(export.contains("明日の資料を送る"))
        #expect(!export.contains("取り消した入力"))
        #expect(LifeLogDerivationService.timelineItems(day: day).contains { $0.contains("[音声入力") })
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
            includesMemos: false,
            includesSummary: true,
            includesTodosForDay: true
        )

        let text = LifeLogTextExporter.render(date: date, day: day, todos: todos, options: options, calendar: calendar)

        #expect(text.contains("要約"))
        #expect(text.contains("[SPEECH"))
        #expect(text.contains("対象"))
        #expect(!text.contains("[CALENDAR"))
        #expect(!text.contains("[MEMO"))
        #expect(text.contains("[TODO status=completed"))
        #expect(text.contains("完了"))
        #expect(!text.contains("下書き"))
        #expect(!text.contains("別日"))
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
