import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import LoreKit

@Suite("Daily Life Logのsource of truth")
struct LifeLogTests {
    @Test("同じ認識範囲の再通知は一つの発話を更新する")
    func repeatedFinalSegmentIsIdempotent() async throws {
        let database = try await LoreDatabase.inMemory()
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
            .appending(path: "lore-audio-checkpoint-\(UUID().uuidString)", directoryHint: .isDirectory)
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
            .appending(path: "lore-audio-checkpoint-file-\(UUID().uuidString)")
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

    @Test("録音終了の通知は直前のchunk確定処理が終わってから届く")
    @MainActor
    func writerFinishWaitsForCommitHandling() async throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "lore-audio-order-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let capture = ContinuousAudioCapture(root: root)
        let log = Mutex<[String]>([])
        let (done, finish) = AsyncStream<Void>.makeStream()
        capture.onCommitted = { _ in
            log.withLock { $0.append("commit started") }
            // The coordinator suspends here on its database write.
            try? await Task.sleep(for: .milliseconds(100))
            log.withLock { $0.append("commit handled") }
        }
        capture.onFinished = {
            log.withLock { $0.append("finished") }
            finish.finish()
        }
        let format = AudioFormats.lifeLogStorage
        let writer = try #require(capture.makeWriter(inputFormat: format))
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try writer.start(at: startedAt)
        writer.append(try Self.audioBuffer(format: format, duration: 0.2))
        writer.finish(at: startedAt.addingTimeInterval(0.2))
        for await _ in done {}

        #expect(log.withLock { $0 } == ["commit started", "commit handled", "finished"])
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
        let database = try await LoreDatabase.inMemory()
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
        let database = try await LoreDatabase.inMemory()
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
                                 localPath: "/tmp/quiet-speech.m4a", peakLevel: 0.17).isTranscriptionCandidate)
    }

    @Test("予定時刻は最も近いtimeline項目へ、検索結果は該当項目へ移動する")
    @MainActor
    func timelineNavigationTargetsExpectedItem() async throws {
        let database = try await LoreDatabase.inMemory()
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
            day: LifeLogDateKey.string(for: before.createdAt),
            timelineItemID: "m-before"
        ))
        #expect(coordinator.highlightedTimelineItemID == "m-before")
        #expect(coordinator.sourceNavigationRevision == 2)
    }

    @Test("メモは発話と分離して保存され、日付境界で正しい日に入る")
    func memosAreTypedAndPartitionedByDay() async throws {
        let database = try await LoreDatabase.inMemory()
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
        let database = try await LoreDatabase.inMemory()
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

    @Test("月間activityは予定と発話の密度を日別に保つ")
    func monthlyActivity() async throws {
        let database = try await LoreDatabase.inMemory()
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
        let database = try await LoreDatabase.inMemory()
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
        let month = try await database.lifeLog.activity(start: start, end: start.addingTimeInterval(86_400), participatingOnly: true)
        #expect(month.values.reduce(0) { $0 + $1.calendarEventCount } == 3)
        #expect(statuses.filter(\.isShownWhenAttendingOnly) == [.none, .accepted, .pending])
        #expect(day.calendarEvents.map(\.participationStatus) == [.none, .accepted, .pending])
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
            calendarEvents: [CalendarEventSnapshot(
                title: "朝会", startsAt: date, endsAt: date.addingTimeInterval(60),
                calendarTitle: "Work", participationStatus: .accepted
            )]
        )
        let text = LifeLogTextExporter.render(date: date, day: day, calendar: calendar)

        let calendarIndex = try #require(text.range(of: "**09:00–09:01 予定**"))
        let speechIndex = try #require(text.range(of: "**09:02–09:02 発話**"))
        let memoIndex = try #require(text.range(of: "**09:03 メモ**"))
        #expect(calendarIndex.lowerBound < speechIndex.lowerBound)
        #expect(speechIndex.lowerBound < memoIndex.lowerBound)
        #expect(!text.contains("SPEECH"))
        #expect(!text.contains("status=open"))
    }

    @Test("成功した音声入力履歴だけを注釈付きでライフログへ投影する")
    func dictationHistoryAppearsInLifeLogWithoutCopyingIt() async throws {
        let database = try await LoreDatabase.inMemory()
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
        let export = LifeLogTextExporter.render(date: startedAt, day: day)
        #expect(export.contains("音声入力**"))
        #expect(export.contains("明日の資料を送る"))
        #expect(!export.contains("取り消した入力"))
    }

    @Test("成功した音声入力の実録音区間はライフログ発話より優先される")
    func successfulDictationSuppressesOverlappingLifeLogUtterance() async throws {
        let database = try await LoreDatabase.inMemory()
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
        let database = try await LoreDatabase.inMemory()
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

    @Test("日別exportは項目ごとの選択を尊重する")
    func textExportHonorsSelection() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let date = try #require(calendar.date(from: DateComponents(year: 2026, month: 8, day: 29, hour: 9)))
        let day = LifeLogDay(
            utterances: [.init(startedAt: date, endedAt: date, text: "発話", audioChunkID: "audio")],
            dictations: [.init(id: "dictation", startedAt: date, endedAt: date, text: "除外する音声入力")],
            memos: [.init(createdAt: date, text: "メモ")],
            calendarEvents: [.init(title: "予定", startsAt: date, endsAt: date, calendarTitle: "Work")]
        )
        let options = LifeLogTextExporter.Options(
            includesCalendarEvents: false,
            includesUtterances: true,
            includesDictations: false,
            includesMemos: false
        )

        let text = LifeLogTextExporter.render(date: date, day: day, options: options, calendar: calendar)

        #expect(text.contains("発話** 発話"))
        #expect(!text.contains("予定**"))
        #expect(!text.contains("メモ**"))
        #expect(!text.contains("除外する音声入力"))
        #expect(!LifeLogTextExporter.Options(
            includesCalendarEvents: false, includesUtterances: false, includesDictations: false, includesMemos: false
        ).hasSelection)
    }

    @Test("exportは連続発話をまとめ、90秒の無発話とメモで区切る")
    func exportGroupsSpeech() {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let speech = [(0.0, 10.0, "一"), (20, 30, "二"), (120, 130, "三"), (140, 150, "四")]
            .map { start, end, text in
                LifeLogUtterance(startedAt: date.addingTimeInterval(start), endedAt: date.addingTimeInterval(end), text: text, audioChunkID: "audio")
            }
        let day = LifeLogDay(utterances: speech, memos: [.init(createdAt: date.addingTimeInterval(135), text: "区切り")])
        let text = LifeLogTextExporter.render(date: date, day: day)
        #expect(text.contains("発話** 一 二"))
        #expect(text.components(separatedBy: "発話**").count == 4)
        #expect(text.contains("発話** 三"))
        #expect(text.contains("発話** 四"))
    }

    @Test("日本語trigram検索は発話・メモを横断し短い語にも対応する")
    func japaneseLifeLogSearch() async throws {
        let database = try await LoreDatabase.inMemory()
        let date = Date(timeIntervalSince1970: 1_725_158_400)
        try await database.lifeLog.save(audioChunk: .init(
            id: "audio", captureStartedAt: date, captureEndedAt: date, localPath: "/tmp/search.m4a"
        ))
        try await database.lifeLog.save(utterance: .init(
            id: "utterance", startedAt: date, endedAt: date, text: "レセコンの移行を相談した", audioChunkID: "audio"
        ))
        try await database.lifeLog.save(memo: .init(id: "memo", createdAt: date, text: "診療報酬の確認"))

        #expect(try await database.lifeLog.search("レセコン").map(\.kind) == [.utterance])
        #expect(try await database.lifeLog.search("診療").map(\.kind) == [.memo])
        #expect(try await database.lifeLog.search("移行").map(\.kind) == [.utterance])
    }

    @Test("ライフログ削除は発話・メモ・予定・音声chunkを同時に消す")
    func deleteAllLifeLogData() async throws {
        let database = try await LoreDatabase.inMemory()
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

        try await database.lifeLog.deleteAll()

        let day = try await database.lifeLog.day(start)
        #expect(day.utterances.isEmpty)
        #expect(day.memos.isEmpty)
        #expect(day.calendarEvents.isEmpty)
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
        var segmenter = calibrated(noiseLevel: 0.004)
        #expect(segmenter.consume(level: 0.012, duration: 0.15) == .ignore)
        #expect(segmenter.consume(level: 0.018, duration: 0.1) == .started)
    }

    @Test("一瞬のlevel上昇だけでは発話を開始しない")
    func transientNoiseDoesNotStartBurst() {
        var segmenter = calibrated()
        #expect(segmenter.consume(level: 0.08, duration: 0.1) == .ignore)
        #expect(segmenter.consume(level: 0.01, duration: 0.1) == .ignore)
        let didFinish = segmenter.finish()
        #expect(!didFinish)
    }

    @Test("約-50dBFS未満の揺れるnoiseは発話にしない")
    func subThresholdNoiseDoesNotStartBurst() {
        var segmenter = calibrated(noiseLevel: 0.000_8)
        for level: Float in [0.001, 0.002_8, 0.001_2, 0.002_5, 0.000_9] {
            #expect(segmenter.consume(level: level, duration: 0.1) == .ignore)
        }
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
            previewInProgress: false,
            engineIdentifier: .whisperCpp
        ))
        #expect(LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 1.5),
            lastPreviewDuration: nil,
            previewInProgress: false,
            engineIdentifier: .whisperCpp
        ))
        #expect(!LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 2.9),
            lastPreviewDuration: 1.5,
            previewInProgress: false,
            engineIdentifier: .whisperCpp
        ))
        #expect(LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 3),
            lastPreviewDuration: 1.5,
            previewInProgress: false,
            engineIdentifier: .whisperCpp
        ))
    }

    @Test("発話量が足りない候補ではpreviewを起動しない")
    func rejectedEvidenceDoesNotPreview() {
        #expect(!LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(voiced: 0.25, duration: 1.5),
            lastPreviewDuration: nil,
            previewInProgress: false,
            engineIdentifier: .whisperCpp
        ))
    }

    @Test("SpeechAnalyzerでは二重sessionを作らない")
    func speechAnalyzerDoesNotUseRollingPreview() {
        #expect(!LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 10),
            lastPreviewDuration: nil,
            previewInProgress: false,
            engineIdentifier: .speechAnalyzer
        ))
    }

    @Test("前のpreviewが実行中なら次を重ねない")
    func activePreviewIsNotReplaced() {
        #expect(!LifeLogCoordinator.shouldScheduleLivePreview(
            evidence: evidence(duration: 3),
            lastPreviewDuration: 1.5,
            previewInProgress: true,
            engineIdentifier: .whisperCpp
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
            .appending(path: "lore-whisper-delete-\(UUID().uuidString)", directoryHint: .isDirectory)
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
            SttBackend.self,
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
