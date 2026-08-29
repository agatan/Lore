#if DEBUG
import Foundation

/// LP・マニュアル用の実画面撮影だけに使う、利用者データと分離したインメモリデータ。
enum ScreenshotDemoData {
    static func seed(database: KoeDatabase, now: Date = Date(), calendar: Calendar = .current) async throws {
        let day = calendar.startOfDay(for: now)
        func time(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: dayOffset, to: day) ?? day
            return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: base) ?? base
        }

        let events = [
            CalendarEventSnapshot(id: "demo-event-1", title: "プロダクト朝会", startsAt: time(9, 30), endsAt: time(10), calendarTitle: "Work", participationStatus: .accepted),
            CalendarEventSnapshot(id: "demo-event-2", title: "デザインレビュー", startsAt: time(13), endsAt: time(14), calendarTitle: "Work", participationStatus: .accepted),
            CalendarEventSnapshot(id: "demo-event-3", title: "次のリリース計画", startsAt: time(16), endsAt: time(16, 45), calendarTitle: "Work", participationStatus: .accepted),
        ]
        try await database.lifeLog.save(calendarEvents: events)

        let utteranceSpecs: [(String, Date, String)] = [
            ("1", time(9, 34), "検索とエクスポートが揃ったので、今日は初回体験の流れを確認します。"),
            ("2", time(10, 18), "完了したタスクを後から戻せる場所があると、安心して整理できそうです。"),
            ("3", time(13, 8), "カレンダーは会話を区切るルールではなく、隣に置く参考情報として見せたいです。"),
            ("4", time(14, 42), "LP用の画像は説明文を増やさず、日々の流れが一目で伝わる構図にします。"),
            ("5", time(16, 12), "次のベータではショートカットから書き出して、好きなLLMへ渡せることも試します。"),
        ]
        for (id, startedAt, text) in utteranceSpecs {
            let endedAt = startedAt.addingTimeInterval(42)
            let chunk = LifeLogAudioChunk(id: "demo-audio-\(id)", captureStartedAt: startedAt, captureEndedAt: endedAt, localPath: "/tmp/koe-demo-\(id).m4a", transcriptionState: .transcribed, processingState: .extracted, peakLevel: 0.48)
            try await database.lifeLog.save(audioChunk: chunk)
            try await database.lifeLog.save(utterance: LifeLogUtterance(id: "demo-utterance-\(id)", startedAt: startedAt, endedAt: endedAt, text: text, audioChunkID: chunk.id))
        }

        try await database.history.save(SessionRecord(
            id: "demo-dictation-1",
            startedAt: time(12, 18),
            endedAt: time(12, 18).addingTimeInterval(9),
            status: .completed,
            appName: "Notes",
            modeSnapshot: ModeSnapshot(modeName: "標準", modePrompt: "", systemPrompt: "", vocabularyCount: 0, trigger: .manual),
            sttEngine: EngineIdentifier("speech-analyzer"),
            rawTranscript: "レビューで確認したい観点を三つに整理する",
            formattedText: "レビューで確認したい観点を3つに整理する。"
        ))

        try await database.lifeLog.save(memo: LifeLogMemo(id: "demo-memo-1", createdAt: time(11, 6), text: "オンボーディングは3つの価値が順番に伝わる構成にする"))
        try await database.lifeLog.save(memo: LifeLogMemo(id: "demo-memo-2", createdAt: time(15, 20), text: "マニュアルには日別エクスポートの選択画面も載せる"))

        try await database.lifeLog.save(todo: LifeLogTodo(id: "demo-todo-1", title: "外部ベータの確認項目をまとめる", createdAt: time(10, 25)))
        try await database.lifeLog.save(todo: LifeLogTodo(id: "demo-todo-2", title: "LP用スクリーンショットを選ぶ", createdAt: time(14, 48)))
        try await database.lifeLog.save(todo: LifeLogTodo(id: "demo-todo-3", title: "書き出し結果を別のLLMで試す", status: .draft, createdAt: time(16, 20)))
        try await database.lifeLog.save(todo: LifeLogTodo(id: "demo-todo-4", title: "初回体験の文言を確認する", status: .completed, createdAt: time(9, 5), completedAt: time(12, 10)))

        try await database.lifeLog.save(summary: DailySummary(
            day: LifeLogDateKey.string(for: day),
            summary: "初回体験とベータ公開に向けて、タスク管理・書き出し・画面表現を確認した一日。",
            commitments: ["外部ベータの確認項目をまとめる"],
            topics: ["Beta", "Export", "Design"],
            calendarEventCount: events.count,
            capturedDurationSeconds: 210,
            utteranceCount: utteranceSpecs.count,
            summarizedThrough: time(16, 13),
            isFinal: false
        ))

        // 月間カレンダーの密度が自然に見えるよう、過去数日に匿名の活動量だけを作る。
        for (index, offset) in [-2, -4, -7, -9, -13].enumerated() {
            let startedAt = time(10 + index, dayOffset: offset)
            let chunk = LifeLogAudioChunk(id: "demo-past-audio-\(index)", captureStartedAt: startedAt, captureEndedAt: startedAt.addingTimeInterval(30), localPath: "/tmp/koe-demo-past-\(index).m4a", transcriptionState: .transcribed, processingState: .extracted, peakLevel: 0.35)
            try await database.lifeLog.save(audioChunk: chunk)
            try await database.lifeLog.save(utterance: LifeLogUtterance(id: "demo-past-utterance-\(index)", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(30), text: "日々の記録", audioChunkID: chunk.id))
        }
    }
}
#endif
