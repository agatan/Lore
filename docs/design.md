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
KoeCLI ──┼──> KoeKit ──> GRDB / whisper.cpp
KoeMCP ──┘
```

外部依存はGRDB Swift Packageと公式whisper.cpp XCFrameworkです。`Domain`、`App`、`Engines`などは単一の`KoeKit` target内の論理モジュールであり、import境界としては強制されません。

## 2. KoeKitのモジュール一覧

| Path | 主要型 | 現在の責務 |
|---|---|---|
| `Domain/` | `SessionDraft`, `SessionRecord`, `Mode`, `FormattingPolicy`, `LifeLogDay`, `LifeLogMemo` | 永続化やUIに依存しない状態、値、遷移、整形規則 |
| `App/` | `AppEnvironment`, `DictationCoordinator`, `LifeLogCoordinator`, `AppSettings` | composition rootと二つの実行パイプライン |
| `Engines/` | `SttEngine`, `SpeechAnalyzerStt`, `WhisperCppStt`, `LlmEngine`, `EngineRegistry` | 音声認識、local model管理、LLMの共通境界とprovider実装 |
| `Persistence/` | `KoeDatabase`, `HistoryStore`, `LifeLogStore`, `ModeStore`, `VocabularyStore` | GRDB schema、migration、query、backup |
| `System/` | `AudioCapture`, `ContinuousAudioCapture`, `TextInserter`, `HotkeyMonitor`, `CalendarProvider`, `SecretStore` | AVFoundation、Accessibility、EventKit、Keychain等のmacOS境界 |
| `Analysis/` | `VocabularySuggestionJob`, `AdaptiveSpeechSegmenter`, `LifeLogTextExporter` | 履歴分析、発話burst境界、外部向けテキスト生成 |
| `Automation/` | `KoeAutomationService` | CLIとMCPが共有する日一覧・期間取得・日別export・検索・memo追加ユースケース |
| `UI/` | `KoeApp`, `KoeWindowPresenter`, `MainWindowView`, `LifeLogWindow`, `HistoryBrowserView`, settings views, HUD | app lifecycle、window所有、SwiftUI表示・操作 |

## 3. プロセス構成と起動

`KoeApp`は`MenuBarExtra`を常設します。`KoeApplicationDelegate`はwindow sceneの生成有無に依存せずruntimeを起動し、`KoeWindowPresenter`がメイン、設定、ライフログミニの各windowを一意に所有します。Main windowは1680×960 ptで生成します。Presenterはwindowを表示してkey windowにした後、activation policyの切替がwindow serverへ反映されるまで短く待ち、activeになるまで最大1秒だけactivateを再要求します。通常起動を含む明示的な表示要求では対象windowを前面にします。UI、menu、hotkeyは`AppEnvironment`の同じ表示actionを呼び、同種windowを重複生成しません。`AppEnvironment`は`@MainActor @Observable`のcomposition rootで、設定、DB、engine、hotkey、二つのcoordinator、画面投影用stateを所有します。

起動時の主要順序は次です。

1. `AppSettings`と`EngineRegistry`を生成する。
2. `KoeDatabase.openDefault()`でDBを開き、必要ならbackup、migration、builtin mode seedを行う。
3. mode、共通ルール、語彙、履歴を読み込む。
4. 保持期間を超えた履歴とライフログ音声を削除する。
5. engine設定と4本のglobal hotkeyを反映する。
6. `LifeLogCoordinator.configure`後、保留audio chunkをバックグラウンド再処理する。
7. UI test用の明示的なsettings遷移がなければ`mainSection = .lifeLog`としてmain windowを開く。

起動時の`captureRequested`は必ず`false`です。保存設定から以前のruntime記録意図を復元せず、保留chunkの再処理だけを行います。UI、hotkey、App Intentからの明示操作だけが新しい記録意図を作ります。

`LifeLogWindow`と`LifeLogMiniWindow`は表示開始時に`LifeLogCoordinator.followCurrentDay()`で今日を読み込み、初回だけtimeline末尾へscrollします。以後のreloadや認識結果追加では閲覧位置を動かしません。

App終了時はApp delegateが進行中操作をinterruptし、音声writerのcommitと必要なDB保存を短時間だけ待ちます。確定済みaudio chunkを次回起動時の再処理対象にすることで終了時間と復旧可能性を両立します。20秒のdeadlineはOS応答不能時の最終保険です。

## 4. 音声入力パイプライン

実装の中心は`DictationCoordinator`です。

```text
Hotkey/UI
  -> target app・mode・rules・vocabulary・engineをSessionContextへ固定
  -> AudioCapture + dictation SttEngine (SpeechAnalyzerStt / WhisperCppStt)
  -> raw transcriptをSessionRecord(interrupted)として保存
  -> FormattingPolicy + LlmEngine
  -> TextInserter
  -> completed / fallback / clipboard_only / failed / cancelled
```

- 短押しと長押しの解釈は`HotkeyGestureInterpreter`、対象アプリは`FrontmostAppObserver`、mode選択は`ModeResolver`が担当します。
- `HotkeyMonitor`は文字keyを含む組み合わせを`RegisterEventHotKey`で標準event dispatcherへnon-exclusive登録します。macOS 26でdispatcherから通知されないことがあるOptionのみ（Option+Shiftを含む）の文字keyは、`CGPreflightListenEventAccess`で入力監視権限を確認して`CGEventTap`も併用します。`pressStart`を単一の押下状態として二経路をdeduplicateし、最初の押下と離上だけをdomain eventにします。同じtapで修飾キー単体と録音中Escを扱います。四つのmonitorは独立して開始します。
- `SessionDraft`がrecording、recognizing、formatting、insertingの進捗と計測値を保持し、永続化可能な`SessionRecord`へ確定します。
- STT確定後、LLMを呼ぶ前にraw transcriptを保存します。
- LLMのtimeout、利用不可、出力検証エラーではraw transcriptを挿入対象にします。
- `TextInserter`はclipboardを退避して対象アプリへpasteし、失敗時は結果をclipboardに残します。
- 通常の音声入力はaudio fileを作りません。
- `DictationCoordinator`のcapture destinationは通常音声入力とボイスメモの二つです。ボイスメモは同じ`AudioCapture`、STT、HUDを使いますが、`SessionDraft`、LLM、`HistoryStore`、`TextInserter`を通らず、確定した生textを`LifeLogCoordinator.addMemo`へ一度だけ渡します。
- `AppEnvironment`はボイスメモ開始前に`LifeLogCoordinator.suspendForVoiceMemo`の完了を待ち、終了結果にかかわらず`resumeAfterVoiceMemo`を呼びます。これにより同じ音声をlife-log utteranceとして生成するcapture区間そのものを作りません。
- `LifeLogMemoComposer`の音声ボタンとglobal hotkeyはどちらも`AppEnvironment.toggleVoiceMemo`を呼びます。UIは`isPreparingVoiceMemo`と`DictationCoordinator.isVoiceMemoRecording`だけを投影し、排他制御やmemo保存をViewへ持ち込みません。

## 5. ライフログパイプライン

`LifeLogCoordinator`は音声入力と状態を共有せず、専用の`ContinuousAudioCapture`で音声を耐久化します。Life Log STTはadaptiveな発話burstごとのrolling previewと確定jobとして選択engineを実行します。

```text
capture request
  -> 30秒単位の .partial を同一directoryの .m4a へcommit
  -> LifeLogAudioChunkをDBへ保存
  -> input signalからadaptiveな発話burst rangeを確定
  -> durable audio rangeをSTT jobで遅延認識しtimestamp付きutteranceを保存
  -> calendar snapshotとの任意関連付け
  -> timelineと月間activityを再読込
```

ライフログから要約、話題、TODOを生成するLLM経路は持ちません。振り返りや作業整理は外部の汎用AIがCLI/MCPの日別exportと検索を読む前提で、Koeはsource of truthの記録、検索、書き出しだけを担います。

- 初回開始前にローカルaudio保存への明示同意が必要です。
- Audio chunkは復旧・保持の単位です。30秒ごと、またはburst確定時にcommitし、burst rangeがchunkをまたぐ場合も対応する全chunkのcommit後に一つの確定job入力として扱います。
- `AdaptiveSpeechSegmenter`はcaptureやSTT adapterから独立したdomain policyです。入力にはUI表示用の対数正規化levelではなく`AudioCapture.rootMeanSquare(of:)`の線形RMSを使います。開始直後の1秒をbackground noise floorの校正に使い、非発話中も緩やかに更新します。約-50 dBFSの絶対下限に加えてnoise floorからの差と倍率を満たす入力が250ms継続した場合だけburstを始め、微小noiseや一定のbackground noiseをjobにしません。Burst内の累積有声時間が30秒未満なら1.5秒、30秒以上なら1秒の連続無音でflushします。Flush時は累積有声時間0.5秒以上かつ有声比率20%以上を`SpeechBurstEvidence`の不変条件とし、満たさない候補はSTTとcheckpointへ渡しません。連続入力でもburstのwall timeが5分に達したら安全flushします。
- Flush後は参照する全audio rangeのcommitを待ってからjobを開始します。Recognition結果のtimestampはcapture開始時刻へaudio offsetを加えて導出し、処理開始時刻やmodel内部clockを正本にしません。Vocabularyは録音session開始時にsnapshot化し、途中の設定変更を混ぜません。保存audioの再処理では最新の有効語彙を使います。
- 音声入力と重なる区間もraw audioと認識済みutteranceを保存します。読み取り時は音声入力の実録音区間（`startedAt`から`audioDurationMs`）を使って重複を解決し、成功した`SessionRecord`をtimeline、検索、exportの正本として、重なるlife-log utteranceをそれらのprojectionから除外します。cancelled/failed sessionは正本にせず、life-log utteranceを残します。この優先順位はUIや個別adapterではなくdomainの共通projectionに置きます。
- 未処理・失敗chunkは保存状態を持ち、起動後に古い順で再処理します。保存済み`peakLevel`はUI用の正規化levelのまま保持し、その尺度で約-50 dBFS未満の明確な無音chunkを除外します。それ以外も保存audioを線形RMSで同じ`AdaptiveSpeechSegmenter`へ戻してから、有効なburstだけを個別にSTTへ渡します。30秒chunk全体や無音区間をLarge modelへ入力しません。
- Audio保持policyは「処理後削除」を既定とし、「7日」「30日」を選択可能にします。削除可能なのは`transcription_state = transcribed`かつ`processing_state = extracted`のchunkだけです。`processing_state = extracted`は発話の保存まで完了したことを表し、旧版の派生処理状態名を保存互換のため流用します。「処理後削除」は両状態の保存完了後、「7日」「30日」はさらに`capture_ended_at`から指定日数の経過後にfileを削除します。DBのchunk metadataと発話は削除しません。
- `LifeLogStore`が処理状態と保持policyから削除可能なaudio URLを決定し、`AppEnvironment`はその結果だけをfile systemから削除します。Policy変更時と起動時に同じuse caseを実行し、未処理・失敗chunkを期間だけで削除しない不変条件を一か所に置きます。
- `ContinuousAudioCapture`は実際のaudio writerの開始・停止を`onRunningChanged`で通知し、`LifeLogCoordinator.isCapturing`だけを全UIの実録音状態へ投影します。音声構成変更時はwriterを安全にcommitし、同じprocessの`captureRequested`が残り、sleepまたはボイスメモによる一時停止中でなければbackoff付きで新しい入力構成へ再接続します。マイク権限拒否だけは再試行しません。確定済みburst jobはcapture再接続と独立して継続・再試行します。
- calendarはEventKitから選択calendarの最小snapshotだけを保存します。設定画面の手動再取得も`LifeLogCoordinator.refreshCalendar`を通し、選択日のsnapshot保存、timeline再読込、月間activity更新を一つのuse caseとして実行します。発話との関連付けは前後2分を許容します。
- sleep前にstreamを閉じ、記録意図が残る場合だけwake後にbackoff付きで再接続します。

## 6. Engine構成

`EngineRegistry`は音声入力・ボイスメモ用とライフログのpreview・確定job用の`SttEngine`を、それぞれ`SpeechAnalyzerStt`または`WhisperCppStt`から選びます。セッションとjobは開始時のengineを最後まで使います。`LlmEngine`は音声入力の整形にだけ選びます。

| STT | 実装 | Model | Audio送信 |
|---|---|---|---|
| Apple SpeechAnalyzer | `SpeechAnalyzerStt` | macOS管理 | なし |
| whisper.cpp deferred | `WhisperCppStt` | Koeがlocal downloadを管理するaccuracy優先のcurated GGML model | なし |

`WhisperCppStt`はLarge v3 Turbo Q5_0 574 MBを既定とし、accuracy優先の非Turbo Large v3 Q5_0も選べるmodel catalog、download、cancel、SHA-256検証、削除を一つの境界に置きます。GGML重みは`WhisperModelCache`がfileごとにprocess内で一つだけloadし、全stateが手放した時点で解放します。`EngineRegistry`は音声入力用とライフログ用に別の`WhisperCppStt`を持ち、それぞれが自分の推論stateを所有するため、両用途の推論は互いを待ちません。同じstateでの推論と結果読取りはactorとstate handleの排他で直列実行します。実行中jobは自分のstateと重みを保持して完了まで使います。音声入力は`captureFormat`で録音を待たせずにstateの準備を開始し、10分のidle後に音声入力用stateだけを解放します。ライフログ用stateは記録停止の完了時に解放します。Download完了だけでは推論stateをloadしません。音声は前後の無音を`WhisperInputPolicy`で除いてから渡し、segment offsetへ除いた長さを加えて保存audioのoffsetと一致させます。語彙promptは同じpolicyで並び順を保ってtoken上限へ収め、prompt全体の写しだけのsegmentを除きます。公式XCFrameworkのC APIをprocess内から直接呼び、GGML modelをMetalとCPUで実行します。Core ML modelとANE specialization、Homebrewや外部CLIへの依存は持ちません。Decode時はspecial tokenを出力せず、engine境界でcontrol/timestamp tokenと、独立した文として現れる既知の定型hallucination「ご視聴ありがとうございました」を除去してからdomain eventへ渡します。後続する実発話は保持し、Read/UI側の補正や既存dataの自動書換えは持ちません。Model取得通信に音声、文字起こし、利用者dataを含めません。

`LifeLogCoordinator`は`SpeechBurstEvidence`が有効になった発話だけを対象に、発話検出から1.5秒後、前のpreviewが完了していれば1.5秒ごとに直近5秒のsnapshotを同じ`SttEngine`へ渡し、結果をephemeralな`liveTranscript`としてだけ公開します。実行中previewへ新しいsnapshotを重ねず、burst確定時はpreviewのcancel完了後に最終認識を優先します。Preview失敗は記録済みaudioの再処理状態を変更せずlogへ残し、最終認識の失敗だけをchunkのfailureとして扱います。有効なburst確定時だけ`ContinuousAudioCapture`へcheckpointを要求し、writer queue上の入力を原子的にcommitして次のfileを開始します。確定結果は対象audioのcommit callbackを待ってからtimestamp付きで保存します。Checkpoint後は定期rotationを30秒後へ再設定し、同時rotationによる空chunkを作りません。

Main/mini timelineはそれぞれ、scroll geometryから末尾が見えているかを保持します。初回と追従中のitem追加だけ末尾へscrollし、利用者操作またはsource navigationで末尾を離れた場合は追従を停止します。末尾へ戻った時だけ追従を再開し、更新のたびに過去の閲覧位置を奪いません。

| Backend | 実装 | 接続先 | Mac外への文字送信 |
|---|---|---|---|
| Apple Foundation Models | `FoundationModelsLlm` | OS内蔵 | なし |
| Ollama | `RemoteLlm` | `http://localhost:11434/v1` | なし |
| LM Studio | `RemoteLlm` | `http://localhost:1234/v1` | なし |
| OpenAI | `RemoteLlm` | provider API | あり、明示選択時のみ |
| Anthropic | `RemoteLlm` | provider API | あり、明示選択時のみ |
| Gemini | `RemoteLlm` | provider API | あり、明示選択時のみ |
| Groq | `GroqLlm` | Groq API | あり、明示選択時のみ |

`FormattingPrompt`はsystem、user、期待出力長だけを持つtext変換の要求です。`GroqLlm`を含む全providerは温度0とprovider既定の推論量で文章変換し、推論を出すmodelの`<think>`部分はadapter境界で除去します。

過去履歴から語彙候補を作る`analysisLlm`は常にオンデバイスです。API keyは`SecretStore`を通してKeychainへ保存します。旧版のライフログ用keyは読み出さず、全削除の対象としてだけ列挙します。

## 7. 永続化

DBは`~/Library/Application Support/Koe/koe.sqlite`です。`DatabaseQueue`を使い、foreign keyを有効化します。

| Store | 主なtable |
|---|---|
| `HistoryStore` | `sessions`, `sessions_fts` |
| `ModeStore` | `modes` |
| `SharedRulesStore` | `meta` |
| `VocabularyStore` | `vocabulary`, `vocab_suggestions` |
| `LifeLogStore` | `life_log_audio_chunks`, `calendar_event_snapshots`, `life_log_utterances`, `life_log_memos`と各FTS |

名前付きmigrationは`v1`から`v9`です。`v9-remove-todo-summary-usage`はTODO、日次要約、token集計、会話区切りのtableとFTSを削除し、`life_log_utterances`を`conversation_id`なしで作り直してFTSを再構築します。削除前の内容はmigration直前backupに残ります。履歴、発話、memoの日本語部分一致にはFTS5 trigramを使います。Codable値と配列はJSON、日時はISO 8601文字列で保存します。

既存DBを開くと、未適用migrationの直前に`Backups/pre-migration-*.sqlite`を作ります。migrationがなくても1日1回`Backups/daily-*.sqlite`を作り、両種を合わせて更新日時が新しい7ファイルを保持します。backupはGRDBのonline backupで整合した単一SQLiteへ固定します。全データ削除はDB内利用者データ、保存audio、whisper.cpp modelと途中download、旧WhisperKit model、backupを削除します。

## 8. 設定、秘密、プロセス間同期

- `AppSettings.Storage`はsuite `dev.agatan.Koe`のUserDefaults key `koe.settings.v1`へJSONで保存します。
- `ApplicationLanguage`は`system`、`en`、`ja`、`zh-Hans`の閉じた値として保存し、既定は`system`です。`system`はmacOSの優先言語から最初の対応localeを選び、なければ`en`へ解決します。`zh-Hant`は`zh-Hans`へ暗黙変換しません。既存設定にfieldがなければ`system`で補完し、GRDB migrationは追加しません。
- 整形のprovider/modelは音声入力だけの設定です。通常音声入力、ライフログcapture、mini window、ボイスメモのhotkey、保持期間、calendar filterをここに入れます。廃止したライフログ用provider、prompt、要約間隔のkeyは読み捨て、保存し直した時点で消えます。Mini windowは常時手前を不変条件とし、表示levelの設定は持ちません。Color themeも設定として保持せず、`KoeTheme`の固定brand tokenを使います。
- `dictationSttBackend`と`lifeLogSttBackend`は用途ごとのengine選択です。whisper.cpp modelは両用途で共有し、保存keyは共有化前の`lifeLogWhisperModel`を維持します。`LifeLogTranscriptionLanguage`はライフログ設定だけに置き、音声入力はmodeの言語設定を使います。認識言語の既定値`applicationLanguage`は`ApplicationLanguage`を`ja`、`en`、`zh-Hans`の固定hintへ解決し、明示的な`auto`も選べます。Runtimeの`captureRequested`は設定として永続化しません。GGML model本体と途中downloadは`Application Support/Koe/Models/WhisperCpp/`へ置き、全データ削除に含めます。
- `AppEnvironment`の設定から解決した`Locale`を全SwiftUI表示へ注入します。localization resourceの開発言語と欠損keyのfallbackは英語です。表示言語はUI shellだけのvariation pointで、ライフログ設定が明示する`applicationLanguage`解決以外はSTT locale、mode、prompt、保存data、export、CLI/MCP contractへ伝播させません。
- API keyはUserDefaultsやDBには入れずKeychainへ保存します。
- `AppEnvironment`は`DistributedNotificationCenter`の`dataChanged`を受けるとライフログを再読込します。CLI/MCPの`memo add`/`memo_add`だけがmemo保存後にこの通知を送ります。

## 9. UIとwindow対応

| Scene / View | 内容 |
|---|---|
| `KoeTheme` | app icon由来の固定blue/cyanをprimary/secondary、同じ明度と彩度へ揃えたrose/mint/goldを録音/成功/警告として定義する。Viewや設定からpaletteを差し替えない。文字は本文・補足・見出しの3段と桁揃えの時刻書体に限る。Glassは浮くもの(HUD、menu)だけに使い、常に見えるpanelと設定sectionは`panelSurface`の淡い塗りと細い罫線で区切る。`SettingsCard`は行の間へ罫線を自動で入れ、各画面は`Divider`を置かない |
| `MenuBarPanel` | 用途別quick action。ライフログtabはcompactなcapture状態と記録切替、今日のmain/mini window入口、音声入力tabは録音、hotkey、mode、直前結果、履歴入口を持つ。共通footerは設定と終了だけに限定する。Main/mini入口はglass buttonによるtext rasterizationを避け、plain button内にsystem fontを直接描画する |
| `MenuBarLabel` | 音声入力のphase、入力level、ライフログcapture状態。`LifeLogCoordinator.isCapturing`中もKoe icon本体はmonochrome maskとして描画し、右下のrose色badgeだけを着色する。停止中または`isRecoveringCapture`のみの状態ではbadgeなしのmonochrome表示にする |
| `MainWindowView` | `lifeLog` / `history`のsegmented切替。初回はonboarding、通常起動は`lifeLog`を開く |
| `LifeLogWindow` | 月間activityと日別timelineの2ペイン。Timeline本体はevent/utterance/dictation/memoを一列の時刻順で表示し、column headerを持たない。日付選択時はsnapshotを再取得し、予定一覧とtimelineを同じdataから更新する。検索buttonは`Command-F`も受け、発話・音声入力・memoの検索結果だけをtimeline itemへ移動する。表示開始時だけ今日を読み込んで末尾へscrollし、その後のreloadでは閲覧位置を保つ。左columnはcalendarの下に発話と予定から描く時間帯を置く。右のtimelineは`PanelHeader`に選択日・項目数・予定/検索/書き出しbuttonを置き、行は`TimelineEntryRow`をminiと共有する |
| `LifeLogCaptureControl` | Main、mini、menu barで共有するcapture状態と開始・停止操作。停止中は「記録を開始」のblue、記録開始意図がある間は「停止」のroseのcapsule buttonとして、symbol、文言、semantic colorを一か所で決める。停止中は状態の補足文を重ねない。録音と文字起こしの内部Boolの中間状態を文言へ直接投影せず、利用者向け状態を安定させる。Main/miniでは状態textの隣へ配置する |
| `LifeLogTranscriptionProgressRow` | `LifeLogCoordinator.activeTranscriptionStartedAt`がある間だけMain/miniのcapture状態直上へ一行表示し、認識対象audio長、1秒ごとの処理経過時間、Shimmerで実際のSTT job実行中を示す。発話burstの確定待ちや録音状態は表現しない |
| `LifeLogExportSheet` | 表示開始時のdate/dayをsnapshotとして保持し、cancel可能なbackground taskで人間向けMarkdownを一度だけ生成する。previewは折り返し可能な上限付きtextとし、完全版をcopy/fileへ再利用する。生成中と書込中はprogressを表示し、MainActorではclipboardとpanel操作だけを行う |
| `HistoryBrowserView` | 音声入力履歴、検索、詳細、コピー、削除 |
| `LifeLogMiniWindow` | title barを隠し、予定、utterance、dictation、memoを一列の時刻順で表示する。`CurrentCalendarEventStrip`をtimeline上部へ固定し、表示時は今日を読み込んで末尾へscrollする。Mainと同じ`LifeLogCaptureControl`を`LifeLogMemoComposer`の直上に置く。`AppEnvironment`がwindow levelを常に`.floating`、collection behaviorを`.canJoinAllSpaces`と`.fullScreenAuxiliary`に固定し、利用者がclose操作またはtoggle hotkeyを使うまで非表示にしない。`HotkeyMonitor`は成立したkey-downを保持し、対応するkey-upだけでreleaseを通知するため、修飾キーなしの同じ文字入力はtoggleしない |
| `LifeLogMemoComposer` | main/mini windowで共有するchat形式のmemo入力。空白を除外し、送信済みtextをclearして`LifeLogCoordinator.addMemo`へ渡す。送信と音声は同じ直径の円形controlにし、音声ボタンは`AppEnvironment.toggleVoiceMemo`と同じactionを受け、準備中、録音中、別処理中の状態だけを描画する |
| `TimelineEntryRow` | main/miniで共有する1行。Memoだけはhoverの編集buttonかdouble-clickでinline編集し、空文字を除いて`LifeLogCoordinator.updateMemo`へ渡す。作成時刻は変えない。Main timelineは本文幅を約800 ptに抑える |
| `LifeLogCalendarSettingsView` | calendar選択、参加filter、選択日の予定を明示的に再取得する操作と進行状態 |
| `SettingsWindowView` | 一般（表示言語を含む）、語彙、privacy、連携、音声入力、AI整形、mode、ライフログ、calendar。Privacyは保存場所の下にKoe dataの合計使用量を一行で示す。各設定行は操作列を共通幅で確保し、Pickerなど可変幅controlの右端を揃える |
| `WhisperModelSettingsView` | 音声入力とライフログで共有するcurated local modelを列挙し、選択、download進捗・cancel・再試行・削除・使用中状態を表示する。両方の設定画面で同じviewを使う |
| `DismissibleNoticeBanner` | 継続可能なmessageと明示的な`×`を表示する。Dismiss actionは表示stateだけをclearし、capture requestやretry taskを変更しない |
| `HudController` / `HudView` | 通常音声入力またはボイスメモのrecordingから終了までの一時表示 |

## 10. 自動化境界

LifeLogTextExporterは90秒未満の連続発話を別種の表示項目で区切ってまとめます。LifeLogExportSheetはプレビューもbackgroundで4,000文字に制限します。timelineの予定rowは淡い塗りと左端の色帯で発話と区別します。

`KoeAutomationService`がCLIとMCPで共有され、記録がある日の一覧、期間の構造化項目、日別export、横断検索、memo追加を提供します。期間取得は画面と同じ`LifeLogStore.day`を日ごとに読み、音声入力優先の発話projectionと参加中予定filterをそのまま使います。書き込みはmemo追加だけです。App Intentsは`AppEnvironment.boot()`の完了後にcapture開始・終了だけを実行します。開始Actionはマイクを扱うためforeground mode、終了Actionはbackground modeです。Shortcutsからの実行にはmacOSが検証できるbundle署名が必要なため、buildは有効な`Apple Development` identityを自己署名より優先します。公開コマンドとtool schemaは外部仕様に列挙します。

## 11. 並行実行とエラー表示

- UI stateとcoordinatorは`@MainActor`に固定します。
- EventKit読込は`CalendarProvider` actor、DB操作はGRDB `DatabaseQueue`で直列化します。
- STT/LLM protocolとdomain値は`Sendable`を基本とし、長時間処理は`Task`で所有・cancelします。
- 回復可能な失敗は履歴status、画面のmessage、MCPの`isError`、CLIのstderr/exit 1のいずれかへ出します。本文、API key、語彙はlogへ出しません。

## 12. 変更時の影響範囲

| 変更 | 最初に確認する場所 | 同時に更新するもの |
|---|---|---|
| provider追加 | `FormattingBackend`, `EngineRegistry`, `ModelsSettingsView`, `SecretStore` | privacy表示、engine tests、spec/design |
| Life Log発話burst・STT変更 | `AdaptiveSpeechSegmenter`, `LifeLogCoordinator`, `SttEngine` | background noise floor校正、0.5秒/20% gate、1.5/1秒tier、1.5秒preview、5秒rolling window、無音時STTなし、5分flush、chunk跨ぎoffset、語彙snapshot、再試行test、`swift test` |
| Whisper model管理変更 | `EngineRegistry`, `WhisperCppStt`, settings | download失敗/cancel/検証、job中削除防止、全削除、privacy、`swift test`、`make ui-test` |
| 永続model変更 | `Domain`, `KoeDatabase.migrator`, 対応Store | migration test、backup/delete test、design |
| dictation状態変更 | `SessionDraft`, `DictationCoordinator`, `HistoryStore` | HUD/history、state tests、spec/design |
| 音声入力とlife-logの重複解決 | domainの共通projection, `LifeLogStore`, search/export | 成功・cancel・失敗・時間境界test、`make ui-test`、spec/design |
| 公開自動化変更 | `KoeAutomationService`, CLI/MCP/AppIntents | tool schema/help、spec.md/spec.html |
| 主要window変更 | `KoeApp`, 対応View, `AppEnvironment` | `make ui-test`、spec/design |
| life-log timeline表示変更 | `LifeLogWindow`, `LifeLogMiniWindow`, `MonthActivityCalendar` | 初回だけのscroll、予定を含む一列timeline、calendarの今日/選択表現、UI test、spec/design |
| 日別export変更 | `LifeLogTextExporter`, `LifeLogExportSheet`, CLI/MCP | 音声入力の独立選択、人間向けMarkdown、background生成、snapshot整合、`swift test`、`make ui-test`、spec/design |
| global hotkeyの対イベント | `HotkeyMonitor` | 登録型hotkeyのmodifier変換と競合分離、修飾キーなしの同一文字key-upを素通しする回帰test、`swift test` |
| menu bar状態表示変更 | `MenuBarLabel`, `DictationCoordinator`, `LifeLogCoordinator` | 状態別表示test、`make ui-test`、spec/design |
| 音声構成変更時の再接続 | `ContinuousAudioCapture`, `LifeLogCoordinator` | retry policyと一時停止状態test、`swift test`、spec/design |
| life-log audio保持policy | `AppSettings`, `LifeLogStore`, `AppEnvironment`, `LifeLogSettingsView` | 処理成功・未処理・失敗・7日/30日境界test、`swift test`、spec/design |
| ボイスメモ | `DictationCoordinator`, `LifeLogCoordinator`, `AppEnvironment`, `AppSettings` | memoのみを作るdestination test、hotkey/UI test、spec/design |
| calendar手動再取得 | `LifeLogCoordinator`, `LifeLogCalendarSettingsView` | 再取得中UI、`make ui-test`、spec/design |

## 13. テスト配置

`Tests/KoeKitTests`はdomain、formatting、engine、persistence、life log、automationを対象にします。`AdaptiveSpeechSegmenter`はbackground noiseの校正と追従、一定noiseだけではjobを作らないこと、相対的な発話levelが250ms続けば開始すること、30秒未満/以上の有声境界で1.5/1秒へ切り替わること、5分で安全flushすることをclock非依存のdomain testで固定します。統合testはwhisper.cppのpreview cadence、chunkをまたぐaudio offset timestamp、録音session開始時の語彙snapshot、失敗後の保存audio再処理を検証します。`make ui-test`は本番と別のbundle IDを持つ署名済み`KoeUITests.app`を別process instanceとして起動し、`Scripts/KoeUIE2E.swift`から主要CUJを検証します。UI test bundleは常に専用UserDefaultsとインメモリDBを使い、global hotkeyと権限監視を起動しません。E2E runnerは専用bundle ID以外のappを終了せず、本番bundle IDを指定された場合は実行を拒否します。詳細な実行方法とE2E契約は[testing.md](testing.md)を参照してください。
