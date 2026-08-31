# Koe 内部設計リファレンス

本書は現在のコードをモジュール単位で俯瞰するための実装リファレンスです。[HTML版](design.html) と同じ範囲を扱います。利用者から見える契約は [spec.md](spec.md) / [spec.html](spec.html)、データ取り扱いは [PRIVACY.md](../PRIVACY.md) を参照してください。

## 1. ビルドターゲットと依存関係

| Target / Product | Entry point | 役割 |
|---|---|---|
| `Koe` / `Koe.app` | `Sources/Koe/main.swift`, `Sources/Koe/AppIntents.swift` | SwiftUIアプリとApp Intents |
| `KoeCLI` / `koe-cli` | `Sources/KoeCLI/main.swift` | 標準入出力・ファイル・クリップボード向けCLI |
| `KoeMCP` / `koe-mcp` | `Sources/KoeMCP/main.swift` | stdio JSON-RPC MCP server |
| `KoeKit` | `Sources/KoeKit/` | ドメイン、ユースケース、OS/AI/DBアダプタ、UI |
| `KoeKitTests` | `Tests/KoeKitTests/` | Swift Testingによる単体・統合テスト |

```text
Koe ─────┐
KoeCLI ──┼──> KoeKit ──> GRDB
KoeMCP ──┘
```

外部Swift PackageはGRDBだけです。`Domain`、`App`、`Engines`などは単一の`KoeKit` target内の論理モジュールであり、import境界としては強制されません。

## 2. KoeKitのモジュール一覧

| Path | 主要型 | 現在の責務 |
|---|---|---|
| `Domain/` | `SessionDraft`, `SessionRecord`, `Mode`, `FormattingPolicy`, `LifeLogDay`, `LifeLogTodo` | 永続化やUIに依存しない状態、値、遷移、整形規則 |
| `App/` | `AppEnvironment`, `DictationCoordinator`, `LifeLogCoordinator`, `AppSettings`, `LifeLogDerivationService` | composition rootと二つの実行パイプライン |
| `Engines/` | `SttEngine`, `LlmEngine`, `SpeechAnalyzerStt`, `FoundationModelsLlm`, `RemoteLlm`, `EngineRegistry` | 音声認識・LLMの共通境界とprovider実装 |
| `Persistence/` | `KoeDatabase`, `HistoryStore`, `LifeLogStore`, `ModeStore`, `VocabularyStore` | GRDB schema、migration、query、backup |
| `System/` | `AudioCapture`, `ContinuousAudioCapture`, `TextInserter`, `HotkeyMonitor`, `CalendarProvider`, `SecretStore` | AVFoundation、Accessibility、EventKit、Keychain等のmacOS境界 |
| `Analysis/` | `VocabularySuggestionJob`, `ConversationSegmenter`, `LifeLogTextExporter` | 履歴分析、会話分割、外部向けテキスト生成 |
| `Automation/` | `KoeAutomationService` | CLIとMCPが共有するDB・設定ユースケース |
| `UI/` | `KoeApp`, `MainWindowView`, `LifeLogWindow`, `HistoryBrowserView`, settings views, HUD | SwiftUI sceneと表示・操作 |

## 3. プロセス構成と起動

`KoeApp`は`MenuBarExtra`を常設し、メイン、設定、ライフログミニ、全TODOのwindowを定義します。`AppEnvironment`は`@MainActor @Observable`のcomposition rootで、設定、DB、engine、hotkey、二つのcoordinator、画面投影用stateを所有します。

起動時の主要順序は次です。

1. `AppSettings`と`EngineRegistry`を生成する。
2. `KoeDatabase.openDefault()`でDBを開き、必要ならbackup、migration、builtin mode seedを行う。
3. mode、共通ルール、語彙、履歴、利用状況を読み込む。
4. 保持期間を超えた履歴とライフログ音声を削除する。
5. engine設定と4本のglobal hotkeyを反映する。
6. `LifeLogCoordinator.configure`後、保留audio chunkをバックグラウンド再処理する。
7. UI test用の明示的な遷移がなければ`mainSection = .lifeLog`としてmain windowを開く。

`LifeLogWindow`と`LifeLogMiniWindow`は表示開始時に`LifeLogCoordinator.followCurrentDay()`で今日を読み込み、初回だけtimeline末尾へscrollします。以後のreloadや認識結果追加では閲覧位置を動かさず、TODOの出典移動は専用の`sourceNavigationRevision`で明示的に行います。

終了時はApp delegateが進行中操作をinterruptし、音声writerのcommitと必要なDB保存を短時間だけ待ちます。停止時派生処理は起動せず、確定済みaudio chunkを次回起動時の再処理対象にすることで終了時間と復旧可能性を両立します。20秒のdeadlineはOS応答不能時の最終保険です。

## 4. 音声入力パイプライン

実装の中心は`DictationCoordinator`です。

```text
Hotkey/UI
  -> target app・mode・rules・vocabulary・engineをSessionContextへ固定
  -> AudioCapture + SpeechAnalyzerStt
  -> raw transcriptをSessionRecord(interrupted)として保存
  -> FormattingPolicy + LlmEngine
  -> TextInserter
  -> completed / fallback / clipboard_only / failed / cancelled
```

- 短押しと長押しの解釈は`HotkeyGestureInterpreter`、対象アプリは`FrontmostAppObserver`、mode選択は`ModeResolver`が担当します。
- `SessionDraft`がrecording、recognizing、formatting、insertingの進捗と計測値を保持し、永続化可能な`SessionRecord`へ確定します。
- STT確定後、LLMを呼ぶ前にraw transcriptを保存します。
- LLMのtimeout、利用不可、出力検証エラーではraw transcriptを挿入対象にします。
- `TextInserter`はclipboardを退避して対象アプリへpasteし、失敗時は結果をclipboardに残します。
- 通常の音声入力はaudio fileを作りません。
- `DictationCoordinator`のcapture destinationは通常音声入力とボイスメモの二つです。ボイスメモは同じ`AudioCapture`、STT、HUDを使いますが、`SessionDraft`、LLM、`HistoryStore`、`TextInserter`を通らず、確定した生textを`LifeLogCoordinator.addMemo`へ一度だけ渡します。
- `AppEnvironment`はボイスメモ開始前に`LifeLogCoordinator.suspendForVoiceMemo`の完了を待ち、終了結果にかかわらず`resumeAfterVoiceMemo`を呼びます。これにより同じ音声をlife-log utteranceとして生成するcapture区間そのものを作りません。
- `LifeLogMemoComposer`の音声ボタンとglobal hotkeyはどちらも`AppEnvironment.toggleVoiceMemo`を呼びます。UIは`isPreparingVoiceMemo`と`DictationCoordinator.isVoiceMemoRecording`だけを投影し、排他制御やmemo保存をViewへ持ち込みません。

## 5. ライフログパイプライン

`LifeLogCoordinator`は音声入力と状態を共有せず、専用の`ContinuousAudioCapture`とSpeechAnalyzer sessionを持ちます。

```text
capture request
  -> 30秒単位の .partial を同一directoryの .m4a へcommit
  -> LifeLogAudioChunkをDBへ保存
  -> 連続SpeechAnalyzer streamからtimestamp付きutteranceを保存
  -> calendar snapshotとの任意関連付け
  -> ConversationSegmenterでconversation再構築
  -> LifeLogDerivationServiceでsummaryとdraft TODOを生成
```

- 初回開始前にローカルaudio保存への明示同意が必要です。
- 30秒chunkは復旧・保持の単位であり、認識sessionの境界ではありません。
- 音声入力と重なる区間もraw audioと認識済みutteranceを保存します。読み取り時は音声入力の実録音区間（`startedAt`から`audioDurationMs`）を使って重複を解決し、成功した`SessionRecord`をtimeline、検索、exportの正本として、重なるlife-log utteranceをそれらのprojectionから除外します。summary/TODOは通常音声入力も重なるlife-log utteranceも使いません。cancelled/failed sessionは正本にせず、life-log utteranceを残します。この優先順位はUIや個別adapterではなくdomainの共通projectionに置きます。
- 未処理・失敗chunkは保存状態を持ち、起動後に古い順で再処理します。明確な無音chunkは`peakLevel`で除外します。
- Audio保持policyは「処理後削除」を既定とし、「7日」「30日」を選択可能にします。削除可能なのは`transcription_state = transcribed`かつ`processing_state = extracted`のchunkだけです。「処理後削除」は両状態の保存完了後、「7日」「30日」はさらに`capture_ended_at`から指定日数の経過後にfileを削除します。DBのchunk metadataと派生dataは削除しません。
- `LifeLogStore`が処理状態と保持policyから削除可能なaudio URLを決定し、`AppEnvironment`はその結果だけをfile systemから削除します。Policy変更時と起動時に同じuse caseを実行し、未処理・失敗chunkを期間だけで削除しない不変条件を一か所に置きます。
- `ContinuousAudioCapture`は実際のaudio writerの開始・停止を`onRunningChanged`で通知し、`LifeLogCoordinator.isCapturing`だけを全UIの実録音状態へ投影します。さらに`AVAudioEngineConfigurationChange`を再接続可能なfailureとして通知します。`LifeLogCoordinator`は旧writerとSpeechAnalyzer sessionの終了を待ち、`captureRequested`が残り、sleepまたはボイスメモによる明示的な一時停止中でなければbackoff付きで新しい入力構成へ再接続します。マイク権限拒否だけは再試行しません。
- calendarはEventKitから選択calendarの最小snapshotだけを保存します。設定画面の手動再取得も`LifeLogCoordinator.refreshCalendar`を通し、選択日のsnapshot保存、timeline再読込、月間activity更新を一つのuse caseとして実行します。発話との関連付けは前後2分を許容し、conversationは90秒以上の無発話で分割します。
- summaryとdraft TODOは設定間隔ごとに、前回以降のライフログ発話またはmemoがある場合だけ、その日のライフログ発話、memo、予定から作り直します。通常音声入力のprojectionはtimeline、検索、exportだけに使い、派生入力・更新triggerから除外します。明示的な停止時は対象日を最終更新しますが、app終了時は派生を開始しません。
- `LifeLogDerivationService`にはsummaryの基準時点を渡します。timeline入力のcalendar eventを基準時点との比較で`終了済み`、`進行中`、`これから`に分類し、system instructionにも現在日時と未来予定を過去形にしない制約を加えます。日付変更時は前日の差分がなくても全予定を含む最終summaryを再生成します。
- sleep前にstreamを閉じ、記録意図が残る場合だけwake後にbackoff付きで再接続します。

## 6. Engine構成

`EngineRegistry`は音声入力用とライフログ派生用の`LlmEngine`を別々に選び、STTは共通factoryから独立sessionを作ります。

| Backend | 実装 | 接続先 | Mac外への文字送信 |
|---|---|---|---|
| Apple Foundation Models | `FoundationModelsLlm` | OS内蔵 | なし |
| Ollama | `RemoteLlm` | `http://localhost:11434/v1` | なし |
| LM Studio | `RemoteLlm` | `http://localhost:1234/v1` | なし |
| OpenAI | `RemoteLlm` | provider API | あり、明示選択時のみ |
| Anthropic | `RemoteLlm` | provider API | あり、明示選択時のみ |
| Gemini | `RemoteLlm` | provider API | あり、明示選択時のみ |
| Groq | `GroqLlm` | Groq API | あり、明示選択時のみ |

`FormattingPrompt`は通常textか、名前とfield型を持つ構造化出力contractを明示します。`LifeLogDerivationService`はsummary/TODOのJSON contractを宣言し、model判定を持ちません。`GroqLlm`は構造化出力contractを温度0、推論本文なし、選択modelが対応する最小の推論量と最も強いJSON制約へ変換します。GPT-OSSは`reasoning_effort = low`とstrict JSON Schema、reasoningを無効化できるmodelは無効化とJSON Object Mode、それ以外は未対応parameterを送らずJSON Object Modeを使います。全経路で同じapp側decodeを最終検証とし、通常の文章変換は温度0とprovider既定の推論量を維持します。

過去履歴から語彙候補を作る`analysisLlm`は常にオンデバイスです。API keyは`SecretStore`を通してKeychainへ保存し、用途別に分離します。

## 7. 永続化

DBは`~/Library/Application Support/Koe/koe.sqlite`です。`DatabaseQueue`を使い、foreign keyを有効化します。

| Store | 主なtable |
|---|---|
| `HistoryStore` | `sessions`, `sessions_fts` |
| `ModeStore` | `modes` |
| `SharedRulesStore` | `meta` |
| `VocabularyStore` | `vocabulary`, `vocab_suggestions` |
| `LifeLogStore` | `life_log_audio_chunks`, `calendar_event_snapshots`, `life_log_conversations`, `life_log_utterances`, `life_log_memos`, `life_log_todos`, `daily_summaries`と各FTS |
| `LlmUsageStore` | `llm_usage_events` |

名前付きmigrationは`v1`から`v8`です。履歴、発話、memo、TODO、summaryの日本語部分一致にはFTS5 trigramを使います。Codable値と配列はJSON、日時はISO 8601文字列で保存します。

既存DBを開くと、未適用migrationの直前に`Backups/pre-migration-*.sqlite`を作ります。migrationがなくても1日1回`Backups/daily-*.sqlite`を作り、両種を合わせて更新日時が新しい7ファイルを保持します。backupはGRDBのonline backupで整合した単一SQLiteへ固定します。全データ削除はDB内利用者データ、保存audio、backupを削除します。

## 8. 設定、秘密、プロセス間同期

- `AppSettings.Storage`はsuite `dev.agatan.Koe`のUserDefaults key `koe.settings.v1`へJSONで保存します。
- provider/modelは音声入力とライフログで別設定です。通常音声入力、ライフログcapture、mini window、ボイスメモのhotkey、保持期間、calendar filter、summary間隔をここに入れます。Mini windowは常時手前を不変条件とし、表示levelの設定は持ちません。Color themeも設定として保持せず、`KoeTheme`の固定brand tokenを使います。
- API keyはUserDefaultsやDBには入れずKeychainへ保存します。
- CLI/MCPによるTODOまたはprompt変更は`DistributedNotificationCenter`でアプリへ通知し、`AppEnvironment`が再読込します。

## 9. UIとwindow対応

| Scene / View | 内容 |
|---|---|
| `KoeTheme` | app icon由来の固定blue/cyanをprimary/secondary、同じ明度と彩度へ揃えたrose/mint/goldを録音/成功/警告として定義する。Viewや設定からpaletteを差し替えない |
| `MenuBarPanel` | 用途別quick action。ライフログtabはcompactなcapture状態と記録切替、今日のmain/mini window入口、音声入力tabは録音、hotkey、mode、直前結果、履歴入口を持つ。共通footerは設定と終了だけに限定する。Main/mini入口はglass buttonによるtext rasterizationを避け、plain button内にsystem fontを直接描画する |
| `MenuBarLabel` | 音声入力のphase、入力level、ライフログcapture状態。`LifeLogCoordinator.isCapturing`中もKoe icon本体はmonochrome maskとして描画し、右下のrose色badgeだけを着色する。停止中または`isRecoveringCapture`のみの状態ではbadgeなしのmonochrome表示にする |
| `MainWindowView` | `lifeLog` / `history`のsegmented切替。初回はonboarding、通常起動は`lifeLog`を開く |
| `LifeLogWindow` | 月間activity、日別timeline、summary、global TODO。Timeline本体はevent/utterance/dictation/memoを一列の時刻順で表示し、column headerを持たない。Headerの予定buttonは時刻、件名、calendar名だけのplainな一覧をpopoverで開く。日付選択時はsnapshotを再取得し、予定一覧とtimelineを同じdataから更新する。検索buttonは`Command-F`も受け、検索結果のtimeline itemまたはTODO出典へ移動する。表示開始時だけ今日を読み込んで末尾へscrollし、その後のreloadでは閲覧位置を保つ。Toolbarにはcapture操作を置かず、今日のtimeline末尾の状態表示に`LifeLogCaptureControl`を置き、その下に`LifeLogMemoComposer`を置く。TODO本文はvertical axisを持つ複数行入力にし、source provenanceがある場合はラベル付きの「元の発言へ」を表示して該当行を中央へscroll・強調する |
| `LifeLogCaptureControl` | Main、mini、menu barで共有するcapture状態と開始・停止操作。停止中の開始はblue/cyanのrecord、記録開始意図がある間の停止はroseのstopとして、symbol、文言、semantic colorを一か所で決める。録音と文字起こしの内部Boolの中間状態を文言へ直接投影せず、利用者向け状態を安定させる。Main/miniでは状態textの隣へ配置する |
| `LifeLogExportSheet` | 表示開始時のdate/day/TODOをsnapshotとして保持し、cancel可能なbackground taskで人間向けMarkdownを一度だけ生成する。previewは折り返し可能な上限付きtextとし、完全版をcopy/fileへ再利用する。生成中と書込中はprogressを表示し、MainActorではclipboardとpanel操作だけを行う |
| `HistoryBrowserView` | 音声入力履歴、検索、詳細、コピー、削除 |
| `LifeLogMiniWindow` | title barを隠し、予定、utterance、dictation、memoを一列の時刻順で表示する。`CurrentCalendarEventStrip`をtimeline上部へ固定し、表示時は今日を読み込んで末尾へscrollする。Mainと同じ`LifeLogCaptureControl`を`LifeLogMemoComposer`の直上に置く。`AppEnvironment`がwindow levelを常に`.floating`、collection behaviorを`.canJoinAllSpaces`と`.fullScreenAuxiliary`に固定し、利用者がclose操作またはtoggle hotkeyを使うまで非表示にしない。`HotkeyMonitor`は成立したkey-downを保持し、対応するkey-upだけでreleaseを通知するため、修飾キーなしの同じ文字入力はtoggleしない |
| `LifeLogMemoComposer` | main/mini windowで共有するchat形式のmemo入力。空白を除外し、送信済みtextをclearして`LifeLogCoordinator.addMemo`へ渡す。送信と音声は同じ直径の円形controlにし、音声ボタンは`AppEnvironment.toggleVoiceMemo`と同じactionを受け、準備中、録音中、別処理中の状態だけを描画する |
| `LifeLogTodoManagerWindow` | 全TODOの編集、確定、完了、再開、削除。TODO本文はvertical axisを持つ複数行入力とし、本文量に応じてrowを広げる |
| `LifeLogCalendarSettingsView` | calendar選択、参加filter、選択日の予定を明示的に再取得する操作と進行状態 |
| `SettingsWindowView` | 一般、利用状況、語彙、privacy、連携、音声入力、AI整形、mode、ライフログ、要約とTODO、calendar |
| `DismissibleNoticeBanner` | 継続可能なmessageと明示的な`×`を表示する。Dismiss actionは表示stateだけをclearし、capture requestやretry taskを変更しない |
| `HudController` / `HudView` | 通常音声入力またはボイスメモのrecordingから終了までの一時表示 |

## 10. 自動化境界

`KoeAutomationService`がCLIとMCPで共有され、日別export、open TODO export、横断検索、TODO CRUD、summary/TODO prompt更新を提供します。App Intentsは起動中の`AppEnvironment`を使い、capture開始・終了とexportを提供します。公開コマンドとtool schemaは外部仕様に列挙します。

## 11. 並行実行とエラー表示

- UI stateとcoordinatorは`@MainActor`に固定します。
- EventKit読込は`CalendarProvider` actor、DB操作はGRDB `DatabaseQueue`で直列化します。
- STT/LLM protocolとdomain値は`Sendable`を基本とし、長時間処理は`Task`で所有・cancelします。
- 回復可能な失敗は履歴status、画面のmessage、MCPの`isError`、CLIのstderr/exit 1のいずれかへ出します。本文、API key、語彙はlogへ出しません。

## 12. 変更時の影響範囲

| 変更 | 最初に確認する場所 | 同時に更新するもの |
|---|---|---|
| provider追加 | `FormattingBackend`, `EngineRegistry`, `ModelsSettingsView`, `SecretStore` | privacy表示、engine tests、spec/design |
| 永続model変更 | `Domain`, `KoeDatabase.migrator`, 対応Store | migration test、backup/delete test、design |
| dictation状態変更 | `SessionDraft`, `DictationCoordinator`, `HistoryStore` | HUD/history、state tests、spec/design |
| 音声入力とlife-logの重複解決 | domainの共通projection, `LifeLogStore`, search/export/derivation | 成功・cancel・失敗・時間境界test、`make ui-test`、spec/design |
| life-log派生変更 | `LifeLogDerivationService`, `LifeLogStore` | 通常音声入力を除外するprompt/trigger test、E2E/export、spec/design |
| live summaryの時点変更 | `LifeLogDerivationService`, `LifeLogCoordinator` | 過去・進行中・未来予定と日次finalizeのtest、spec/design |
| 公開自動化変更 | `KoeAutomationService`, CLI/MCP/AppIntents | tool schema/help、spec.md/spec.html |
| 主要window変更 | `KoeApp`, 対応View, `AppEnvironment` | `make ui-test`、spec/design |
| life-log timeline・TODO表示変更 | `LifeLogWindow`, `LifeLogMiniWindow`, `LifeLogTodoManagerWindow`, `MonthActivityCalendar` | 初回だけのscroll、予定を含む一列timeline、予定一覧・検索結果の移動、calendarの今日/選択表現、一列mini、長文TODO、安定した記録状態、dismiss操作のUI test、spec/design |
| 日別export変更 | `LifeLogTextExporter`, `LifeLogExportSheet`, CLI/MCP/App Intents | 音声入力の独立選択、人間向けMarkdown、background生成、snapshot整合、`swift test`、`make ui-test`、spec/design |
| TODO重複防止 | `LifeLogDerivationService`, `LifeLogCoordinator`, `LifeLogStore` | 既存TODOをpromptへ含め、正規化後の同一文言を保存しない。新しいDraftには永続的に一意なIDを割り当て、確定済みの旧Draft IDと衝突しないdomain/persistence test、`swift test` |
| 再要約trigger | `LifeLogCoordinator` | 設定間隔と明示的停止だけをtriggerとし、ボイスメモ・sleep・再接続では強制更新しないstate test、`swift test` |
| global hotkeyの対イベント | `HotkeyMonitor` | 修飾キーなしの同一文字key-upを素通しする回帰test、`swift test` |
| menu bar状態表示変更 | `MenuBarLabel`, `DictationCoordinator`, `LifeLogCoordinator` | 状態別表示test、`make ui-test`、spec/design |
| 音声構成変更時の再接続 | `ContinuousAudioCapture`, `LifeLogCoordinator` | retry policyと一時停止状態test、`swift test`、spec/design |
| life-log audio保持policy | `AppSettings`, `LifeLogStore`, `AppEnvironment`, `LifeLogSettingsView` | 処理成功・未処理・失敗・7日/30日境界test、`swift test`、spec/design |
| ボイスメモ | `DictationCoordinator`, `LifeLogCoordinator`, `AppEnvironment`, `AppSettings` | memoのみを作るdestination test、hotkey/UI test、spec/design |
| calendar手動再取得 | `LifeLogCoordinator`, `LifeLogCalendarSettingsView` | 再取得中UI、`make ui-test`、spec/design |

## 13. テスト配置

`Tests/KoeKitTests`はdomain、formatting、engine、persistence、life log、automationを対象にします。`make ui-test`は署名済みappを起動し、`Scripts/KoeUIE2E.swift`から主要CUJを検証します。詳細な実行方法とE2E契約は[testing.md](testing.md)を参照してください。
