import Foundation
import Testing

@testable import KoeKit

// MARK: - ホットキー

@Suite("音声captureの出力先")
struct SpeechCaptureDestinationTests {
    @Test("ボイスメモは履歴と前面appへ出さずライフログを一時停止する")
    func voiceMemoIsMemoOnly() {
        #expect(!SpeechCaptureDestination.voiceMemo.writesHistory)
        #expect(!SpeechCaptureDestination.voiceMemo.insertsIntoFrontmostApp)
        #expect(SpeechCaptureDestination.voiceMemo.suspendsLifeLogCapture)
        #expect(SpeechCaptureDestination.dictation.writesHistory)
        #expect(SpeechCaptureDestination.dictation.insertsIntoFrontmostApp)
        #expect(!SpeechCaptureDestination.dictation.suspendsLifeLogCapture)
    }
}

@Suite("ホットキーのハイブリッド判定")
struct HotkeyGestureTests {
    let interpreter = HotkeyGestureInterpreter(holdThreshold: .milliseconds(300))

    @Test("押した瞬間に必ず録音が始まる")
    func pressStarts() {
        #expect(interpreter.intent(for: .pressed, isRecording: false, pressStartedSession: false) == .start(.toggle))
    }

    @Test("閾値未満で離したらトグルなので録音を続ける")
    func shortPressKeepsRecording() {
        let intent = interpreter.intent(
            for: .released(heldFor: .milliseconds(120)),
            isRecording: true,
            pressStartedSession: true
        )
        #expect(intent == .ignore)
    }

    @Test("閾値以上保持して離したら push-to-talk として停止する")
    func longPressStops() {
        let intent = interpreter.intent(
            for: .released(heldFor: .milliseconds(700)),
            isRecording: true,
            pressStartedSession: true
        )
        #expect(intent == .stopAndProcess)
    }

    @Test("録音中の再押下は停止")
    func pressWhileRecordingStops() {
        #expect(interpreter.intent(for: .pressed, isRecording: true, pressStartedSession: false) == .stopAndProcess)
    }

    @Test("停止させた押下の離上は何もしない")
    func releaseAfterStopIsIgnored() {
        let intent = interpreter.intent(
            for: .released(heldFor: .milliseconds(80)),
            isRecording: true,
            pressStartedSession: false
        )
        #expect(intent == .ignore)
    }

    @Test("トリガー種別は保持時間で決まる")
    func triggerKind() {
        #expect(interpreter.trigger(forHeldFor: .milliseconds(100)) == .toggle)
        #expect(interpreter.trigger(forHeldFor: .milliseconds(500)) == .pushToTalk)
    }
}

// MARK: - モード解決

@Suite("モードの解決")
struct ModeResolverTests {
    let fallback = Mode(id: "default", name: "Default", bundleIDs: [], prompt: "", sortOrder: 0)
    let chat = Mode(id: "chat", name: "Chat", bundleIDs: ["com.tinyspeck.slackmacgap"], prompt: "", sortOrder: 20)
    let jetbrains = Mode(id: "ide", name: "IDE", bundleIDs: ["com.jetbrains.*"], prompt: "", sortOrder: 10)
    let specific = Mode(id: "idea", name: "IDEA", bundleIDs: ["com.jetbrains.intellij"], prompt: "", sortOrder: 30)

    var modes: [Mode] { [fallback, chat, jetbrains, specific] }

    @Test("完全一致で解決する")
    func exactMatch() {
        let mode = ModeResolver.resolve(bundleID: "com.tinyspeck.slackmacgap", modes: modes)
        #expect(mode?.id == "chat")
    }

    @Test("ワイルドカードで解決する")
    func wildcardMatch() {
        let mode = ModeResolver.resolve(bundleID: "com.jetbrains.goland", modes: modes)
        #expect(mode?.id == "ide")
    }

    @Test("完全一致はワイルドカードより優先する")
    func exactBeatsWildcard() {
        let mode = ModeResolver.resolve(bundleID: "com.jetbrains.intellij", modes: modes)
        #expect(mode?.id == "idea")
    }

    @Test("マッチしなければフォールバック")
    func fallbackWhenNoMatch() {
        #expect(ModeResolver.resolve(bundleID: "com.apple.Notes", modes: modes)?.id == "default")
        #expect(ModeResolver.resolve(bundleID: nil, modes: modes)?.id == "default")
    }

    @Test("手動固定は自動判定に勝つ")
    func overrideWins() {
        let mode = ModeResolver.resolve(bundleID: "com.tinyspeck.slackmacgap", modes: modes, overrideID: "ide")
        #expect(mode?.id == "ide")
    }

    @Test("ビルトインモードはすべて解決可能")
    func builtinsResolve() {
        #expect(ModeResolver.resolve(bundleID: "com.apple.Terminal", modes: BuiltinModes.all)?.id == BuiltinModes.defaultModeID)
        #expect(ModeResolver.resolve(bundleID: "com.unknown.app", modes: BuiltinModes.all)?.id == BuiltinModes.defaultModeID)
    }
}

// MARK: - 整形ポリシー

@Suite("整形プロンプトと出力検証")
struct FormattingPolicyTests {
    let mode = Mode(id: "m", name: "Custom", prompt: "指示文として明瞭に整形する")
    let vocabulary = [
        VocabularyEntry(surface: "レセコン", reading: "れせこん", misrecognitions: ["レセ困", "レ背コン"]),
        VocabularyEntry(surface: "無効", enabled: false),
    ]

    @Test("system プロンプトに共通ルール・語彙・モード指示が入る")
    func promptComposition() {
        let prompt = FormattingPolicy.systemPrompt(mode: mode, vocabulary: vocabulary)

        // 言いよどみを閉じた列挙で書くと、実際の発話に出る語が漏れて残る
        // (「そのー」だけを挙げていると「その」が消えない)。
        // 日本語の考え中の語が名指しされていることを固定する。
        for word in ["えーと", "その", "なんか", "なんていうの", "こう", "まあ"] {
            #expect(prompt.contains(word), "言いよどみとして「\(word)」が挙がっていない")
        }
        // 同じ語句の繰り返しをまとめる指示。抽象的な「重複を残さない」では効かない。
        #expect(prompt.contains("1 回にする"))

        #expect(prompt.contains("レセコン"))
        #expect(prompt.contains("レセ困"))
        #expect(prompt.contains("指示文として明瞭に整形する"))
        // 無効な語彙は注入しない
        #expect(!prompt.contains("「無効」"))
    }

    @Test("空出力は却下する")
    func rejectsEmpty() {
        #expect(FormattingPolicy.validate(output: "   \n ", input: "これはテストの入力です") == .failure(.empty))
    }

    @Test("極端に短い出力は却下する")
    func rejectsTooShort() {
        let input = String(repeating: "あ", count: 100)
        let result = FormattingPolicy.validate(output: "あ", input: input)
        #expect(result.isFailure)
    }

    @Test("極端に長い出力は却下する")
    func rejectsTooLong() {
        let input = "これは検証のためのそれなりの長さを持つ入力テキストです"
        let result = FormattingPolicy.validate(output: String(repeating: "あ", count: 500), input: input)
        #expect(result.isFailure)
    }

    @Test("短文には比率検証を適用しない")
    func skipsRatioForShortInput() {
        let result = FormattingPolicy.validate(output: "はい、承知しました。", input: "はい")
        #expect(try! result.get() == "はい、承知しました。")
    }

    @Test("プロンプト漏洩を検出する")
    func detectsLeakage() {
        let result = FormattingPolicy.validate(
            output: "以下が整形結果です。この関数をリファクタリングしてください。",
            input: "この関数をリファクタして"
        )
        #expect(result.isFailure)
    }

    @Test("コードフェンスと前置きは剥がす")
    func sanitizesDecoration() {
        #expect(FormattingPolicy.sanitize("```\nこんにちは\n```") == "こんにちは")
        #expect(FormattingPolicy.sanitize("整形後: こんにちは") == "こんにちは")
        #expect(FormattingPolicy.sanitize("「こんにちは」") == "こんにちは")
        // 途中に鉤括弧がある場合は剥がさない
        #expect(FormattingPolicy.sanitize("「A」と「B」") == "「A」と「B」")
    }

    @Test("コードフェンスは応答の兆候として却下する")
    func rejectsCodeFenceInside() {
        let result = FormattingPolicy.validate(
            output: "整形しました。\n```\n- 手順1\n- 手順2\n```",
            input: "テストを直してコミットメッセージも書いてほしい"
        )
        #expect(result.isFailure)
    }

    @Test("入力の 2 倍を超える出力は応答とみなす")
    func rejectsRunawayOutput() {
        let input = "テストが落ちてる原因を調べてほしい"
        let output = String(repeating: "詳細な説明を付け足します。", count: 6)
        #expect(FormattingPolicy.validate(output: output, input: input).isFailure)
    }

    @Test("ユーザープロンプトは入力を囲んで命令を後ろに置く")
    func userPromptAnchorsInstruction() {
        let prompt = FormattingPolicy.userPrompt(transcript: "テスト入力")
        #expect(prompt.contains("テスト入力"))
        // 小型モデルが応答に流れないよう、命令は入力より後ろにある
        let transcriptIndex = prompt.range(of: "テスト入力")!.lowerBound
        let instructionIndex = prompt.range(of: "整形したテキストだけ")!.lowerBound
        #expect(transcriptIndex < instructionIndex)
    }

    @Test("質問文はそのまま通す(応答ではなく変換であること)")
    func questionPassesThrough() {
        let result = FormattingPolicy.validate(
            output: "これはどうやって動いているんですか？",
            input: "これってどうやって動いてるんですかね"
        )
        #expect(result.isSuccess)
    }
}

// MARK: - 言語判定

@Suite("言語判定")
struct LanguageDetectorTests {
    @Test("日本語")
    func japanese() {
        #expect(LanguageDetector.detect("この関数をリファクタリングしてください") == .ja)
    }

    @Test("英語")
    func english() {
        #expect(LanguageDetector.detect("Please refactor this function and add tests") == .en)
    }

    @Test("日英混在")
    func mixed() {
        #expect(LanguageDetector.detect("この function を refactor して test も書いてください") == .mixed)
    }

    @Test("技術用語混じりの日本語は日本語のまま")
    func japaneseWithFewLatinTerms() {
        #expect(LanguageDetector.detect("この関数のリファクタリングをお願いします。あとテストも書いてください。TS で") == .ja)
    }

    @Test("文字が無ければ方針に従う")
    func noLetters() {
        #expect(LanguageDetector.detect("123 456", preference: .auto) == .unknown)
        #expect(LanguageDetector.detect("123", preference: .ja) == .ja)
        #expect(LanguageDetector.detect("123", preference: .zhHans) == .zhHans)
    }

    @Test("Whisper制御tokenを本文から除去する")
    func stripsWhisperSpecialTokens() {
        #expect(TranscriptText.sanitized("<|startoftranscript|><|en|><|transcribe|><|0.00|> hello <|20.00|><|endoftext|>") == "hello")
        #expect(TranscriptText.sanitized("通常の本文") == "通常の本文")
    }
}

// MARK: - セッション状態機械

@Suite("セッションの状態遷移と不変条件")
struct SessionDraftTests {
    func makeContext(trigger: DictationTrigger = .toggle) -> SessionContext {
        SessionContext(
            appBundleID: "com.apple.Terminal",
            appName: "ターミナル",
            mode: BuiltinModes.chat,
            systemPrompt: "system",
            vocabularyCount: 3,
            sttEngine: .speechAnalyzer,
            sttModel: "model",
            llmEngine: .foundationModels,
            llmModel: "afm",
            trigger: trigger
        )
    }

    @Test("STT 確定まで永続化可能な記録は存在しない")
    func noRecordBeforeFinalization() {
        var draft = SessionDraft(context: makeContext())
        #expect(draft.record == nil)
        draft.updatePartial("とりあえずの暫定テキスト")
        #expect(draft.record == nil)

        let record = draft.finalizeTranscript("確定テキスト", language: .ja, sttLatencyMs: 120, audioDurationMs: 3_000)
        #expect(record.rawTranscript == "確定テキスト")
        #expect(record.status == .interrupted)
        #expect(draft.phase == .formatting)
    }

    @Test("整形成功 → 挿入で completed")
    func completedFlow() {
        var draft = SessionDraft(context: makeContext())
        _ = draft.finalizeTranscript("生テキスト", language: .ja, sttLatencyMs: 100, audioDurationMs: 2_000)
        _ = draft.markFormatted("整形済みテキスト", llmLatencyMs: 400)
        let record = draft.markInserted(insertLatencyMs: 900)
        #expect(record?.status == .completed)
        #expect(record?.formattedText == "整形済みテキスト")
        #expect(record?.resultText == "整形済みテキスト")
        #expect(draft.phase == .finished(.completed))
    }

    @Test("整形スキップ → 挿入で fallback、結果は生テキスト")
    func fallbackFlow() {
        var draft = SessionDraft(context: makeContext())
        _ = draft.finalizeTranscript("生テキスト", language: .ja, sttLatencyMs: 100, audioDurationMs: 2_000)
        _ = draft.markFormattingSkipped(reason: "タイムアウト", llmLatencyMs: 6_000)
        let record = draft.markInserted(insertLatencyMs: 6_500)
        #expect(record?.status == .fallback)
        #expect(record?.resultText == "生テキスト")
        #expect(record?.llmEngine == EngineIdentifier.none)
        #expect(record?.error == "タイムアウト")
    }

    @Test("挿入失敗は clipboardOnly になり結果は残る")
    func clipboardOnlyFlow() {
        var draft = SessionDraft(context: makeContext())
        _ = draft.finalizeTranscript("生テキスト", language: .ja, sttLatencyMs: 100, audioDurationMs: 2_000)
        _ = draft.markFormatted("整形済み", llmLatencyMs: 300)
        let record = draft.markClipboardOnly(reason: "セキュア入力中")
        #expect(record?.status == .clipboardOnly)
        #expect(record?.resultText == "整形済み")
    }

    @Test("確定前のキャンセルでも暫定テキストは履歴に残る")
    func cancelKeepsPartial() {
        var draft = SessionDraft(context: makeContext())
        draft.updatePartial("途中まで認識したテキスト")
        let record = draft.markCancelled()
        #expect(record?.status == .cancelled)
        #expect(record?.rawTranscript == "途中まで認識したテキスト")
    }

    @Test("何も認識していないキャンセルは記録を作らない")
    func cancelWithoutTextCreatesNothing() {
        var draft = SessionDraft(context: makeContext())
        #expect(draft.markCancelled() == nil)
    }

    @Test("トリガー種別は離した後に確定して記録に載る")
    func triggerIsResolvedAfterRelease() {
        var draft = SessionDraft(context: makeContext(trigger: .toggle))
        draft.setTrigger(.pushToTalk)
        let record = draft.finalizeTranscript("テキスト", language: .ja, sttLatencyMs: 10, audioDurationMs: 100)
        #expect(record.modeSnapshot.trigger == .pushToTalk)
    }

    @Test("記録にはモードとプロンプトのスナップショットが載る")
    func snapshotIsRecorded() {
        var draft = SessionDraft(context: makeContext())
        let record = draft.finalizeTranscript("テキスト", language: .ja, sttLatencyMs: 10, audioDurationMs: 100)
        #expect(record.modeSnapshot.modeName == BuiltinModes.chat.name)
        #expect(record.modeSnapshot.systemPrompt == "system")
        #expect(record.modeSnapshot.vocabularyCount == 3)
    }
}

// MARK: - 語彙提案

@Suite("語彙提案の解析")
struct VocabularySuggestionJobTests {
    @Test("前置き付きの出力から JSON 配列を取り出す")
    func extractsJSON() {
        let output = """
        以下が候補です。
        ```json
        [{"surface":"レセコン","kind":"repeated_correction","reading":"れせこん","misrecognitions":["レセ困"]}]
        ```
        """
        let candidates = VocabularySuggestionJob.parse(output)
        #expect(candidates.count == 1)
        #expect(candidates.first?.surface == "レセコン")
        #expect(candidates.first?.kind == .repeatedCorrection)
        #expect(candidates.first?.misrecognitions == ["レセ困"])
    }

    @Test("JSON でなければ候補なし")
    func parsesGarbageAsEmpty() {
        #expect(VocabularySuggestionJob.parse("候補はありません").isEmpty)
        #expect(VocabularySuggestionJob.parse("[壊れた").isEmpty)
    }

    @Test("上限を超える候補は切り捨てる")
    func limitsCandidates() {
        let items = (0..<20).map { "{\"surface\":\"語\($0)\"}" }.joined(separator: ",")
        #expect(VocabularySuggestionJob.parse("[\(items)]").count == VocabularySuggestionJob.maxCandidates)
    }

    @Test("抜粋は前後の文脈を含む")
    func excerptIncludesContext() {
        let text = "今日はレセコンの締め処理について話しました。明日も続きをやります。"
        let excerpt = VocabularySuggestionJob.excerpt(around: "レセコン", in: text, radius: 6)
        #expect(excerpt?.contains("レセコン") == true)
        #expect(excerpt?.hasSuffix("…") == true)
    }
}

// MARK: - ヘルパ

private extension Result {
    var isFailure: Bool {
        switch self {
        case .success: false
        case .failure: true
        }
    }

    var isSuccess: Bool { !isFailure }
}

// MARK: - 中身のすり替え検出

@Suite("整形結果が入力と繋がっているか")
struct ContentOverlapTests {
    @Test("実測で起きた「例文がそのまま出力される」ケースを弾く")
    func rejectsPromptExampleBleed() {
        // 語彙の few-shot 例を system に入れたとき、実際にこの出力が返ってきた。
        // 長さ比は妥当な範囲で、漏洩マーカーにも当たらず、検証を通過してしまっていた。
        let result = FormattingPolicy.validate(
            output: "TypeScript の型定義を直しておきます。",
            input: "変理のレセ困の締め処理を明日やりますあとレ背コンの設定も見ときます"
        )
        #expect(result.isFailure)
        if case .failure(.unrelated) = result {} else {
            Issue.record("すり替えとして検出されるべき: \(result)")
        }
    }

    @Test("普通の整形は通る")
    func acceptsNormalFormatting() {
        let result = FormattingPolicy.validate(
            output: "この関数をリファクタリングして、テストも一緒に書いてください。",
            input: "えーとこの関数をリファクタして、あーやっぱりテストも一緒に書いて"
        )
        #expect(result.isSuccess)
    }

    @Test("箇条書きへの構造化も通る")
    func acceptsRestructuring() {
        let result = FormattingPolicy.validate(
            output: "- テストが落ちている原因を調べる\n- 直したらテストを追加する\n- コミットメッセージは日本語で書く",
            input: "テストが落ちてる原因を調べてほしくて、直したらテスト追加して、あとコミットメッセージは日本語で書いて"
        )
        #expect(result.isSuccess)
    }

    @Test("日英の翻訳は素材が共有されないので検証を外す")
    func skipsCheckForTranslation() {
        let result = FormattingPolicy.validate(
            output: "Please refactor this function and add tests for it.",
            input: "この関数をリファクタリングして、テストも追加してください"
        )
        #expect(result.isSuccess)
    }

    @Test("一致度は整形で高く、別文で低い")
    func overlapValues() {
        let formatted = FormattingPolicy.contentOverlap(
            input: "えーとこの関数をリファクタして",
            output: "この関数をリファクタリングしてください。"
        )
        let unrelated = FormattingPolicy.contentOverlap(
            input: "えーとこの関数をリファクタして",
            output: "明日の天気は晴れです。"
        )
        #expect(formatted > 0.6)
        #expect(unrelated < 0.15)
    }
}

// MARK: - 語彙の渡し方

/// 語彙は**モデルへのヒント**であって置換規則ではない(C-43)。
/// Koe 自身が文字列を書き換えないことと、代わりに STT と整形の両方へ確実に届くことを固定する。
@Suite("語彙はモデルへのヒントとして渡る")
struct VocabularyHintTests {
    let entries = [
        VocabularyEntry(surface: "レセコン", reading: "レセコン", misrecognitions: ["レセ困", "レ背コン"]),
        VocabularyEntry(surface: "Ruby", reading: "るびー", misrecognitions: ["る"]),
        VocabularyEntry(surface: "無効", misrecognitions: ["夢Ф"], enabled: false),
    ]

    @Test("整形プロンプトの語彙表に表記と誤認識が載る")
    func vocabularyReachesFormattingPrompt() {
        let prompt = FormattingPolicy.systemPrompt(mode: BuiltinModes.defaultMode, vocabulary: entries)
        #expect(prompt.contains("レセコン"))
        #expect(prompt.contains("レセ困"))
        // 1 文字でも除外しない。機械置換をやめたので「短すぎて危険」な語は無くなった。
        #expect(prompt.contains("Ruby"))
        #expect(prompt.contains("る"))
        // 無効にした語は渡さない。
        #expect(!prompt.contains("夢Ф"))
    }

    @Test("STT のバイアスには表記と読みが渡る")
    func vocabularyReachesSttBias() {
        let strings = FormattingPolicy.contextualStrings(entries)
        #expect(strings.contains("レセコン"))
        #expect(strings.contains("るびー"))
        #expect(!strings.contains("無効"))

        let hint = FormattingPolicy.vocabularyHint(entries)
        #expect(hint?.contains("Ruby") == true)
        #expect(hint?.contains("無効") == false)
    }

    @Test("整形をスキップしたら生テキストがそのまま結果になる")
    func skippedFormattingKeepsRawTranscript() {
        let context = SessionContext(
            appBundleID: nil,
            appName: nil,
            mode: BuiltinModes.defaultMode,
            systemPrompt: "system",
            vocabularyCount: 1,
            sttEngine: .speechAnalyzer,
            sttModel: nil,
            llmEngine: .foundationModels,
            llmModel: nil,
            trigger: .toggle
        )
        var draft = SessionDraft(context: context)
        _ = draft.finalizeTranscript("レセ困の設定", language: .ja, sttLatencyMs: 10, audioDurationMs: 2_000)
        let record = draft.markFormattingSkipped(reason: "タイムアウト", llmLatencyMs: 100)

        // Koe は矯正しないので、raw がそのまま挿入される。
        #expect(record?.formattedText == nil)
        #expect(record?.resultText == "レセ困の設定")
    }
}

// MARK: - 処理中の押下

@Suite("処理中にホットキーを押したとき")
struct HotkeyDuringProcessingTests {
    let interpreter = HotkeyGestureInterpreter(holdThreshold: .milliseconds(500))

    @Test("録音していない(整形中など)なら開始意図になる")
    func pressDuringProcessingAsksToStart() {
        // 実際に開始できるかは Coordinator が判断する。押下の意図自体は「開始」。
        #expect(interpreter.intent(for: .pressed, isRecording: false, pressStartedSession: false) == .start(.toggle))
    }

    @Test("開始できなかった押下の離上は何も起こさない")
    func releaseAfterRefusedStartDoesNothing() {
        // Coordinator は start が失敗したら pressStartedSession を false のままにする。
        let intent = interpreter.intent(
            for: .released(heldFor: .milliseconds(120)),
            isRecording: false,
            pressStartedSession: false
        )
        #expect(intent == .ignore)
    }

    @Test("500ms 閾値では 300ms の押下はトグル扱いになる")
    func threeHundredMillisecondsIsATap() {
        #expect(interpreter.trigger(forHeldFor: .milliseconds(300)) == .toggle)
        let intent = interpreter.intent(
            for: .released(heldFor: .milliseconds(300)),
            isRecording: true,
            pressStartedSession: true
        )
        #expect(intent == .ignore)
    }

    @Test("既定の閾値は 500ms")
    func defaultThreshold() {
        #expect(AppSettings.Storage().holdThresholdMs == 500)
    }
}
