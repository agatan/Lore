#if DEBUG
import Foundation

/// LP・マニュアル用の実画面撮影だけに使う、利用者データと分離したインメモリデータ。
enum ScreenshotDemoData {
    static func seed(database: LoreDatabase, now: Date = Date(), calendar: Calendar = .current) async throws {
        let day = calendar.startOfDay(for: now)
        let copy = DemoCopy.current
        func time(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
            let base = calendar.date(byAdding: .day, value: dayOffset, to: day) ?? day
            return calendar.date(byAdding: .minute, value: hour * 60 + minute, to: base) ?? base
        }

        let events = [
            CalendarEventSnapshot(id: "demo-event-1", title: copy.events[0], startsAt: time(9, 30), endsAt: time(10), calendarTitle: copy.calendar, participationStatus: .accepted),
            CalendarEventSnapshot(id: "demo-event-2", title: copy.events[1], startsAt: time(13), endsAt: time(14), calendarTitle: copy.calendar, participationStatus: .accepted),
            CalendarEventSnapshot(id: "demo-event-3", title: copy.events[2], startsAt: time(16), endsAt: time(16, 45), calendarTitle: copy.calendar, participationStatus: .accepted),
        ]
        try await database.lifeLog.save(calendarEvents: events)

        let times = [time(9, 34), time(10, 18), time(13, 8), time(14, 42), time(16, 12)]
        let utteranceSpecs: [(String, Date, String)] = zip(times, copy.utterances).enumerated().map { index, pair in
            (String(index + 1), pair.0, pair.1)
        }
        for (id, startedAt, text) in utteranceSpecs {
            let endedAt = startedAt.addingTimeInterval(42)
            let chunk = LifeLogAudioChunk(id: "demo-audio-\(id)", captureStartedAt: startedAt, captureEndedAt: endedAt, localPath: "/tmp/lore-demo-\(id).m4a", transcriptionState: .transcribed, processingState: .extracted, peakLevel: 0.48)
            try await database.lifeLog.save(audioChunk: chunk)
            try await database.lifeLog.save(utterance: LifeLogUtterance(id: "demo-utterance-\(id)", startedAt: startedAt, endedAt: endedAt, text: text, audioChunkID: chunk.id))
        }

        try await database.history.save(SessionRecord(
            id: "demo-dictation-1",
            startedAt: time(12, 18),
            endedAt: time(12, 18).addingTimeInterval(9),
            status: .completed,
            appName: "Notes",
            modeSnapshot: ModeSnapshot(modeName: "Default", modePrompt: "", systemPrompt: "", vocabularyCount: 0, trigger: .manual),
            sttEngine: .speechAnalyzer,
            rawTranscript: copy.dictationRaw,
            formattedText: copy.dictationFormatted,
            audioDurationMs: 4_200,
            sttLatencyMs: 380,
            llmLatencyMs: 640,
            insertLatencyMs: 1_140
        ))

        // One stored AI note, so the timeline and the export show notes without any request.
        try await database.lifeLog.save(generatedNote: GeneratedNote(
            id: "demo-note-1",
            kind: .eventNotes,
            scope: .event(EventOccurrence(events[0], calendar: calendar)),
            rangeStart: events[0].startsAt,
            rangeEnd: events[0].endsAt,
            backend: .onDevice,
            model: FormattingBackend.onDevice.defaultModel,
            createdAt: events[0].endsAt.addingTimeInterval(20),
            sourceUtteranceIDs: ["demo-utterance-1"],
            sourceMemoIDs: [],
            sections: [
                GeneratedNoteSection(kind: .decisions, items: [GeneratedNoteItem(text: copy.eventNote[0], sources: ["u-demo-utterance-1"])]),
                GeneratedNoteSection(kind: .actionItems, items: [GeneratedNoteItem(text: copy.eventNote[1], owner: copy.me, sources: ["u-demo-utterance-1"])]),
                GeneratedNoteSection(kind: .openQuestions, items: [GeneratedNoteItem(text: copy.eventNote[2], sources: ["u-demo-utterance-1"])]),
            ]
        ))

        try await database.lifeLog.save(memo: LifeLogMemo(id: "demo-memo-1", createdAt: time(11, 6), text: copy.memos[0]))
        try await database.lifeLog.save(memo: LifeLogMemo(id: "demo-memo-2", createdAt: time(15, 20), text: copy.memos[1]))

        if ProcessInfo.processInfo.arguments.contains("--lore-demo-recurring-now") {
            try await seedRecurringEventInProgress(database: database, now: now, calendar: calendar, copy: copy)
        }

        // 月間カレンダーの密度が自然に見えるよう、過去数日に匿名の活動量だけを作る。
        for (index, offset) in [-2, -4, -7, -9, -13].enumerated() {
            let startedAt = time(10 + index, dayOffset: offset)
            let chunk = LifeLogAudioChunk(id: "demo-past-audio-\(index)", captureStartedAt: startedAt, captureEndedAt: startedAt.addingTimeInterval(30), localPath: "/tmp/lore-demo-past-\(index).m4a", transcriptionState: .transcribed, processingState: .extracted, peakLevel: 0.35)
            try await database.lifeLog.save(audioChunk: chunk)
            try await database.lifeLog.save(utterance: LifeLogUtterance(id: "demo-past-utterance-\(index)", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(30), text: copy.pastUtterance, audioChunkID: chunk.id))
        }
    }

    /// A weekly 1:1 in progress now, with last week's occurrence recorded and noted, for the "Last time" row.
    /// Behind its own flag so LP media, which do not control the clock, keep their layout.
    private static func seedRecurringEventInProgress(database: LoreDatabase, now: Date, calendar: Calendar, copy: DemoCopy) async throws {
        let (title, said, firstAction, secondAction, question) = (copy.recurring[0], copy.recurring[1], copy.recurring[2], copy.recurring[3], copy.recurring[4])
        let start = now.addingTimeInterval(-10 * 60)
        let event = CalendarEventSnapshot(id: "demo-event-weekly", title: title, startsAt: start, endsAt: now.addingTimeInterval(20 * 60), calendarTitle: copy.calendar, participationStatus: .accepted)
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: start) ?? start
        var lastWeekEvent = event
        lastWeekEvent.startsAt = lastWeek
        lastWeekEvent.endsAt = lastWeek.addingTimeInterval(30 * 60)
        try await database.lifeLog.save(calendarEvents: [lastWeekEvent])
        try await database.lifeLog.save(calendarEvents: [event])
        let spokenAt = lastWeek.addingTimeInterval(3 * 60)
        try await database.lifeLog.save(utterance: LifeLogUtterance(id: "demo-weekly-last-week", startedAt: spokenAt, endedAt: spokenAt.addingTimeInterval(40), text: said, audioChunkID: nil, calendarEventID: event.id))
        try await database.lifeLog.save(generatedNote: GeneratedNote(
            id: "demo-note-weekly",
            kind: .eventNotes,
            scope: .event(EventOccurrence(eventID: event.id, day: LifeLogDateKey.string(for: spokenAt, calendar: calendar))),
            rangeStart: lastWeek,
            rangeEnd: lastWeek.addingTimeInterval(30 * 60),
            backend: .onDevice,
            model: FormattingBackend.onDevice.defaultModel,
            createdAt: lastWeek.addingTimeInterval(31 * 60),
            sourceUtteranceIDs: ["demo-weekly-last-week"],
            sourceMemoIDs: [],
            sections: [
                GeneratedNoteSection(kind: .actionItems, items: [
                    GeneratedNoteItem(text: firstAction, owner: copy.me, sources: ["u-demo-weekly-last-week"]),
                    GeneratedNoteItem(text: secondAction, sources: ["u-demo-weekly-last-week"]),
                ]),
                GeneratedNoteSection(kind: .openQuestions, items: [GeneratedNoteItem(text: question, sources: ["u-demo-weekly-last-week"])]),
            ]
        ))
    }
}
/// 撮影用の文面。`--lore-demo-language en|ja|zh-Hans`で、表示言語とあわせて切り替える。
/// LPや説明書に載るため、各言語で自然に話す内容にする（直訳しない）。
struct DemoCopy {
    var language: ApplicationLanguage
    var events: [String]
    var calendar: String
    var utterances: [String]
    var memos: [String]
    var pastUtterance: String
    var dictationRaw: String
    var dictationFormatted: String
    var searchQuery: String
    var spoken: String
    var formatted: String
    var inputDevice: String
    var skippedDetail: String
    var liveSentences: [String]
    var messageTitle: String
    var messageFrom: String
    var messageText: String
    var me: String
    /// Decision, action item, and open question of the stored demo note.
    var eventNote: [String]
    /// Weekly 1:1 title, last week's utterance, two action items, and an open question.
    var recurring: [String]

    static var current: DemoCopy {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--lore-demo-language"), arguments.indices.contains(index + 1) else {
            return japanese
        }
        switch arguments[index + 1] {
        case "en": return english
        case "zh-Hans": return chinese
        default: return japanese
        }
    }

    static let japanese = DemoCopy(
        language: .japanese,
        events: ["プロダクト朝会", "デザインレビュー", "次のリリース計画"],
        calendar: "仕事",
        utterances: [
            "検索とエクスポートが揃ったので、今日は初回体験の流れを確認します。",
            "完了したタスクを後から戻せる場所があると、安心して整理できそうです。",
            "カレンダーは会話を区切るルールではなく、隣に置く参考情報として見せたいです。",
            "問い合わせの多い設定画面は、次のスプリントで文言から見直します。",
            "次のベータではショートカットから書き出して、好きなLLMへ渡せることも試します。",
        ],
        memos: ["オンボーディングは3つの機能を順番に紹介する", "マニュアルに日別の書き出し画面も載せる"],
        pastUtterance: "日々の記録",
        dictationRaw: "レビューで確認したい観点を三つに整理する",
        dictationFormatted: "レビューで確認したい観点を3つに整理する。",
        searchQuery: "整理",
        spoken: "えーと、明日の1on1なんですけど、30分後ろにずらしてもらえると助かります",
        formatted: "明日の1on1ですが、30分後ろにずらしてもらえると助かります。",
        inputDevice: "MacBook Proのマイク",
        skippedDetail: "整形をスキップしました（処理がタイムアウトしました）",
        liveSentences: [
            "午後のレビューで出た指摘は、来週の計画にそのまま反映します。",
            "次のベータは金曜に配って、週明けに感想を集めましょう。",
        ],
        messageTitle: "メッセージ — #design",
        messageFrom: "Mika",
        messageText: "明日の1on1、時間大丈夫そうですか？",
        me: "自分",
        eventNote: ["今日は初回体験の流れを確認する", "初回体験の流れを通しで確認する", "検索とエクスポートの次に何を見せるか"],
        recurring: ["週次1on1", "評価面談の資料は金曜までに共有します。", "評価面談の資料を金曜までに共有する", "オンボーディング改善の進捗を確認する", "次の四半期の目標をどこまで広げるか"]
    )

    static let english = DemoCopy(
        language: .english,
        events: ["Product Standup", "Design Review", "Next Release Planning"],
        calendar: "Work",
        utterances: [
            "Search and export are in, so today I'm walking through the first-run experience.",
            "A place to bring back finished tasks would make cleaning up a lot less stressful.",
            "The calendar shouldn't split the conversation. It should sit beside it as context.",
            "The settings screen gets the most questions, so let's rework its wording next sprint.",
            "For the next beta, let's try exporting from a shortcut and handing it to any LLM.",
        ],
        memos: ["Onboarding should introduce the three core features in order", "Add the daily export dialog to the manual"],
        pastUtterance: "Daily notes",
        dictationRaw: "um group the review points into three items",
        dictationFormatted: "Group the review points into three items.",
        searchQuery: "export",
        spoken: "um so tomorrow's one-on-one, could we like push it back thirty minutes",
        formatted: "Could we push tomorrow's 1:1 back 30 minutes?",
        inputDevice: "MacBook Pro Microphone",
        skippedDetail: "Formatting skipped (timed out)",
        liveSentences: [
            "Let's fold the feedback from this afternoon's review into next week's plan.",
            "We'll ship the next beta on Friday and collect feedback early next week.",
        ],
        messageTitle: "Messages — #design",
        messageFrom: "Mika",
        messageText: "Does tomorrow's 1:1 still work for you?",
        me: "You",
        eventNote: ["Today's focus is the first-run experience", "Walk through the first-run flow end to end", "What should come after search and export?"],
        recurring: ["Weekly 1:1", "I'll share the review doc by Friday.", "Share the review doc by Friday", "Check progress on the onboarding fixes", "How far should next quarter's goals reach?"]
    )

    static let chinese = DemoCopy(
        language: .simplifiedChinese,
        events: ["产品晨会", "设计评审", "下个版本规划"],
        calendar: "工作",
        utterances: [
            "搜索和导出都做好了，今天来过一遍首次使用的流程。",
            "如果有个地方能把完成的任务找回来，整理起来会更安心。",
            "日历不该用来切分对话，而是放在旁边作为参考。",
            "设置页面问的人最多，下个迭代先从文案改起。",
            "下一个测试版试试用快捷键导出，再交给任意 LLM。",
        ],
        memos: ["新手引导按顺序介绍三个核心功能", "使用手册里加上按天导出的界面"],
        pastUtterance: "日常记录",
        dictationRaw: "嗯把评审要看的点整理成三条",
        dictationFormatted: "把评审要看的点整理成三条。",
        searchQuery: "导出",
        spoken: "嗯那个明天的一对一，能不能往后推半个小时",
        formatted: "明天的一对一能往后推半小时吗？",
        inputDevice: "MacBook Pro 麦克风",
        skippedDetail: "已跳过整理（处理超时）",
        liveSentences: [
            "下午评审提的意见，直接放进下周的计划里。",
            "下一个测试版周五发出，下周初收集反馈。",
        ],
        messageTitle: "消息 — #design",
        messageFrom: "Mika",
        messageText: "明天的一对一时间还可以吗？",
        me: "我",
        eventNote: ["今天先过一遍首次使用的流程", "从头到尾走一遍首次使用流程", "搜索和导出之后，接下来展示什么？"],
        recurring: ["每周一对一", "评估资料我周五前发出来。", "周五前分享评估资料", "确认新手引导改进的进度", "下个季度的目标要定到多大？"]
    )
}
#endif
