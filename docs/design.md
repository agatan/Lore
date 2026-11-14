# Lore 内部設計リファレンス

本書は現在のコードをモジュール単位で俯瞰するための実装リファレンスです。[HTML版](design.html) と同じ範囲を扱います。利用者から見える契約は [spec.md](spec.md) / [spec.html](spec.html)、データ取り扱いは [PRIVACY.md](../PRIVACY.md) を参照してください。

## 1. ビルドターゲットと依存関係

| Target / Product | Entry point | 役割 |
|---|---|---|
| `Lore` / `Lore.app` | `Sources/Lore/main.swift`, `Sources/Lore/AppIntents.swift` | SwiftUIアプリとApp Intents |
| `LoreCLI` / `lore-cli` | `Sources/LoreCLI/main.swift` | 標準入出力・ファイル・クリップボード向けCLI |
| `LoreMCP` / `lore-mcp` | `Sources/LoreMCP/main.swift` | stdio JSON-RPC MCP server |
| `LoreKit` | `Sources/LoreKit/` | ドメイン、ユースケース、OS/AI/DBアダプタ、UI |
| `LoreKitTests` | `Tests/LoreKitTests/` | Swift Testingによる単体・統合テスト |

```text
Lore ─────┐
LoreCLI ──┼──> LoreKit ──> GRDB / whisper.cpp
LoreMCP ──┘
```

外部依存はGRDB Swift Packageと公式whisper.cpp XCFrameworkです。`Domain`、`App`、`Engines`などは単一の`LoreKit` target内の論理モジュールであり、import境界としては強制されません。

## 2. LoreKitのモジュール一覧

| Path | 主要型 | 現在の責務 |
|---|---|---|
| `Domain/` | `SessionDraft`, `SessionRecord`, `Mode`, `FormattingPolicy`, `LifeLogDay`, `LifeLogMemo`, `LifeLogSchedule` | 永続化やUIに依存しない状態、値、遷移、整形規則 |
| `App/` | `AppEnvironment`, `DictationCoordinator`, `LifeLogCoordinator`, `AppSettings` | composition rootと二つの実行パイプライン |
| `Engines/` | `SttEngine`, `SpeechAnalyzerStt`, `WhisperCppStt`, `LlmEngine`, `EngineRegistry` | 音声認識、local model管理、LLMの共通境界とprovider実装 |
| `Persistence/` | `LoreDatabase`, `HistoryStore`, `LifeLogStore`, `ModeStore`, `VocabularyStore` | GRDB schema、migration、query、backup |
| `System/` | `AudioCapture`, `ContinuousAudioCapture`, `TextInserter`, `HotkeyMonitor`, `CalendarProvider`, `SecretStore` | AVFoundation、Accessibility、EventKit、Keychain等のmacOS境界 |
| `Analysis/` | `AdaptiveSpeechSegmenter`, `LifeLogTextExporter` | 発話burst境界、外部向けテキスト生成 |
| `Automation/` | `LoreAutomationService` | CLIとMCPが共有する日一覧・期間取得・日別export・検索・memo追加ユースケース |
| `Sync/` | `SyncCode`, `SyncFileFormat`, `SyncEngine`, `SyncCoordinator` | 暗号化した変更fileによるMac間同期 |
| `UI/` | `LoreApp`, `LoreWindowPresenter`, `MainWindowView`, `LifeLogWindow`, `HistoryBrowserView`, settings views, HUD | app lifecycle、window所有、SwiftUI表示・操作 |

## 3. プロセス構成と起動

`LoreApp`は`MenuBarExtra`を常設します。`LoreApplicationDelegate`はwindow sceneの生成有無に依存せずruntimeを起動し、`LoreWindowPresenter`がメイン、設定、ライフログミニの各windowを一意に所有します。Main windowは1680×960 ptで生成します。Presenterはwindowを表示してkey windowにした後、activation policyの切替がwindow serverへ反映されるまで短く待ち、activeになるまで最大1秒だけactivateを再要求します。通常起動を含む明示的な表示要求では対象windowを前面にします。UI、menu、hotkeyは`AppEnvironment`の同じ表示actionを呼び、同種windowを重複生成しません。`AppEnvironment`は`@MainActor @Observable`のcomposition rootで、設定、DB、engine、hotkey、二つのcoordinator、画面投影用stateを所有します。

起動時の主要順序は次です。

1. `AppSettings`と`EngineRegistry`を生成する。
2. `LoreDatabase.openDefault()`でDBを開き、必要ならbackup、migration、builtin mode seedを行う。
3. mode、共通ルール、語彙、履歴を読み込む。
4. 保持期間を超えた履歴とライフログ音声を削除する。
5. engine設定と4本のglobal hotkeyを反映する。
6. `LifeLogCoordinator.configure`後、保留audio chunkをバックグラウンド再処理する。
7. UI test用の明示的なsettings遷移がなければ`mainSection = .lifeLog`としてmain windowを開く。

起動時の`captureRequested`は必ず`false`です。保存設定から以前のruntime記録意図を復元せず、保留chunkの再処理だけを行います。UI、hotkey、App Intentからの明示操作と、有効な自動記録scheduleだけが新しい記録意図を作ります。

自動記録は三層に分けます。`Domain/LifeLogSchedule`は曜日・開始分・終了分だけを持つ値で、`window(containing:)`と`nextTransition(after:)`をCalendar経由で計算します（日付またぎとDSTを含む）。`Domain/LifeLogScheduleController`は「scheduleが開始した記録か」「手動停止で抑止中の時間帯の開始時刻」だけを状態に持つ純粋な状態機械で、現在時刻と記録意図から開始・停止・何もしないを決めます。`AppEnvironment`は起動完了、設定変更、wake、`NSSystemClockDidChange`、`NSSystemTimeZoneDidChange`で評価し、次の切替時刻までsleepする単一の`Task`を張り直します。Polling loopは使いません。手動の開始・停止は`setLifeLogCaptureEnabled`から状態機械へ通知し、scheduleの開始は同じcapture遷移を`bySchedule`で通します。録音audio保存への同意がなければscheduleは開始せず、bannerで手動開始を案内します。

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

ライフログから要約、話題、TODOを生成するLLM経路は持ちません。振り返りや作業整理は外部の汎用AIがCLI/MCPの日別exportと検索を読む前提で、Loreはsource of truthの記録、検索、書き出しだけを担います。

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
| whisper.cpp deferred | `WhisperCppStt` | Loreがlocal downloadを管理するaccuracy優先のcurated GGML model | なし |

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

API keyは`SecretStore`を通してKeychainへ保存します。旧版のライフログ用keyは読み出さず、全削除の対象としてだけ列挙します。

## 7. 永続化

DBは`~/Library/Application Support/Lore/lore.sqlite`です。`DatabaseQueue`を使い、foreign keyを有効化します。

| Store | 主なtable |
|---|---|
| `HistoryStore` | `sessions`, `sessions_fts` |
| `ModeStore` | `modes` |
| `SharedRulesStore` | `meta` |
| `VocabularyStore` | `vocabulary` |
| `LifeLogStore` | `life_log_audio_chunks`, `calendar_event_snapshots`, `life_log_utterances`, `life_log_memos`と各FTS |
| `SyncStore` | `sync_control`, `sync_outbox`, `sync_versions`, `sync_cursors` |

名前付きmigrationは`v1`から`v11`です。`v9-remove-todo-summary-usage`はTODO、日次要約、token集計、会話区切りのtableとFTSを削除し、`life_log_utterances`を`conversation_id`なしで作り直してFTSを再構築します。削除前の内容はmigration直前backupに残ります。`v10-sync`は同期用tableとtriggerを追加し、`life_log_utterances.audio_chunk_id`をNULL許容へ作り直します（7.1）。`v11-remove-vocab-suggestions`は履歴からの語彙候補を廃止したため`vocab_suggestions`を削除します。候補から登録済みの語彙（`source = suggested`）は`vocabulary`に残します。履歴、発話、memoの日本語部分一致にはFTS5 trigramを使います。Codable値と配列はJSON、日時はISO 8601文字列で保存します。

旧名Koeからの移行は`Persistence/LegacyKoeMigration`に閉じ込め、旧名（`dev.agatan.Koe`、`Koe/`、`koe.sqlite`、`koe.settings.v1`）はこのfileとそのtestだけが知ります。`LoreDatabase.openDefault()`はDBを開く前（既存のmigration直前backupより前）に`migrateApplicationSupport`を呼び、旧folderだけがあれば同じvolume内のrenameで`Lore/`へ移してから`koe.sqlite`と`-wal`/`-shm`/`-journal`を`lore.sqlite`側へ改名します（本体を最後に移すため、途中で止まっても次回続きから改名します）。新旧両方があれば混ぜずに`.leftLegacyInPlace`を返し、`AppEnvironment`が`dataMigrationIssue`としてmenu barに出します。移動が失敗したら例外をそのまま返してDBを開きません（空DBを作ると次回「両方ある」状態になり旧dataへ戻れなくなるため）。保存audioの`local_path`は絶対pathなので、`LifeLogStore.rewriteAudioPaths`が開くたびに旧folder配下を指す行だけを新folderへ付け替えます（該当がなければ書きません）。backup名は`pre-migration-*`/`daily-*`でapp名を含まないため、移した後もそのまま7世代の数に入ります。設定は`AppEnvironment.settings`の生成前に`migrateDefaults`が旧domainを一度だけ写し（設定JSONの鍵は`lore.settings.v1`へ改名、新domainに設定があれば写さない、`lore.migratedFromKoe`で再実行しない）、Keychainは起動直後に`SecretStore.migrateLegacyKoeService`が旧serviceの各accountを新serviceへ写してから旧itemを消します。写せなかったaccountは旧itemを残し、理由を`dataMigrationIssue`に出します。CLI/MCPは`LoreAutomationService.openDefault()`で設定とfolderの移行を同じ手順で行い、Keychainには触れません。UI test bundleとscreenshot demoは移行しません。

既存DBを開くと、未適用migrationの直前に`Backups/pre-migration-*.sqlite`を作ります。migrationがなくても1日1回`Backups/daily-*.sqlite`を作り、両種を合わせて更新日時が新しい7ファイルを保持します。backupはGRDBのonline backupで整合した単一SQLiteへ固定します。全データ削除はDB内利用者データ、保存audio、whisper.cpp modelと途中download、旧WhisperKit model、backupを削除します。

## 7.1 Mac間同期

`Sync/`は利用者が選んだfolderを経由するMac間同期です。Loreはnetworkへ接続せず、folderの提供元が運ぶ暗号化fileだけを読み書きします。

- **変更の記録**: `v10-sync`が`life_log_utterances`、`life_log_memos`、`sessions`、`vocabulary`のINSERT/UPDATE/DELETE triggerを作り、`sync_control`の`enabled=1`かつ`suppressed=0`の間だけ`sync_outbox(entity, record_id, changed_at)`へ記録します。CLI/MCPは読み取り専用のため、別processからの書き込みはありません。保持期間による削除、一括削除、全data削除、他のMacからの適用は`suppressed=1`の同じtransaction内で行い、outboxへ載せません。
- **書き出し**: `SyncEngine.export`はoutboxを読み、行が残っていれば現在の列値をupsert、無ければtombstoneにしたbatchを作ります。`<folder>/Lore Sync/devices/<device-id>/<10桁seq>.loresync`へ一時fileを書いてrenameし、その後のtransactionで、書き出し時と`changed_at`が同じoutbox行だけを消して`sync_versions`へ版を記録します。seqはDBの次番号と既存file最大値+1の大きい方で、file書込後のcrashでも番号を再利用しません。
- **取り込み**: 自分以外のdevice directoryを`sync_cursors`の次seqから連番で読みます。復号・検証・適用とcursor更新を1 transactionで行い、失敗したfileで止めて同じdeviceの後続を待たせます。iCloud Driveの`.icloud` placeholderはdownloadを要求して次回へ回します。
- **競合**: 版は`(changed_at, device_id)`の辞書順で比較し、新しい方だけを適用します（後勝ち）。未書き出しのoutbox行も自分の版として比較に含めます。Tombstoneも`sync_versions`に`deleted=1`で残し、古いupsertで復活させません。
- **列の範囲**: 発話は`id`、時刻、`text`だけを送り、他のMacでは`audio_chunk_id`と`calendar_event_id`をNULLで保存します。このため`v10-sync`は`life_log_utterances.audio_chunk_id`をNULL許容へ作り直し、FTSを再構築します。履歴は`sessions`の全列、語彙は`vocabulary`の全列、memoは全列です。Audio、calendar snapshot、mode、設定、API keyは対象外です。
- **file形式**: `LORESYNC` magic、format version 1 byte、header JSON長(UInt32 big endian)、header JSON（`device`, `seq`）、AES-GCM combined box（nonce 12 byte + 暗号文 + tag 16 byte）。Magicからheader JSONまでをassociated dataとして認証します。平文はLZFSE圧縮したbatch JSONです。`Lore Sync/keycheck.loresync`は既知の平文を同じ鍵で封じたfileで、参加時に同期コードを検証します。
- **鍵と状態**: 256-bit鍵は`SecretStore`の`sync.key`（non-synchronizable generic password）に同期コード文字列として保存します。同期コードは鍵32 byteとSHA-256先頭2 byteをRFC 4648 base32にして4文字ずつ区切ったものです。Device ID、folder bookmark、次seq、最終同期時刻、最後のerrorは`sync_control`の1行に置き、全data削除と同期解除で消します。
- **実行契機**: `SyncCoordinator`(`@MainActor`)はoutboxの変更をGRDBの`DatabaseRegionObservation`で受けて5秒debounceで書き出し、起動時、app activation、120秒timer、「今すぐ同期」で書き出しと取り込みを行います。取り込みで行が変わった場合は履歴、語彙、life logを再読込します。

## 8. 設定、秘密、プロセス間同期

- `AppSettings.Storage`はsuite `dev.agatan.Lore`のUserDefaults key `lore.settings.v1`へJSONで保存します。
- `ApplicationLanguage`は`system`、`en`、`ja`、`zh-Hans`の閉じた値として保存し、既定は`system`です。`system`はmacOSの優先言語から最初の対応localeを選び、なければ`en`へ解決します。`zh-Hant`は`zh-Hans`へ暗黙変換しません。既存設定にfieldがなければ`system`で補完し、GRDB migrationは追加しません。
- 整形のprovider/modelは音声入力だけの設定です。通常音声入力、ライフログcapture、mini window、ボイスメモのhotkey、自動記録schedule（`lifeLogSchedule`、既定は無効）、保持期間、calendar filterをここに入れます。廃止したライフログ用provider、prompt、要約間隔のkeyは読み捨て、保存し直した時点で消えます。Mini windowは常時手前を不変条件とし、表示levelの設定は持ちません。Color themeも設定として保持せず、`LoreTheme`の固定brand tokenを使います。
- `dictationSttBackend`と`lifeLogSttBackend`は用途ごとのengine選択です。whisper.cpp modelは両用途で共有し、保存keyは共有化前の`lifeLogWhisperModel`を維持します。`LifeLogTranscriptionLanguage`はライフログ設定だけに置き、音声入力はmodeの言語設定を使います。認識言語の既定値`applicationLanguage`は`ApplicationLanguage`を`ja`、`en`、`zh-Hans`の固定hintへ解決し、明示的な`auto`も選べます。Runtimeの`captureRequested`は設定として永続化しません。GGML model本体と途中downloadは`Application Support/Lore/Models/WhisperCpp/`へ置き、全データ削除に含めます。
- `AppEnvironment`の設定から解決した`Locale`を全SwiftUI表示へ注入します。localization resourceの開発言語と欠損keyのfallbackは英語です。表示言語はUI shellだけのvariation pointで、ライフログ設定が明示する`applicationLanguage`解決以外はSTT locale、mode、prompt、保存data、export、CLI/MCP contractへ伝播させません。
- API keyはUserDefaultsやDBには入れずKeychainへ保存します。

## 9. UIとwindow対応

| Scene / View | 内容 |
|---|---|
| `LoreTheme` | app iconの「L.」と同じ固定violet/cyanをprimary/secondary、同じ明度と彩度へ揃えたrose/mint/goldを録音/成功/警告、goldより赤みのあるorangeをmemoの印として定義する。Viewや設定からpaletteを差し替えない。色は一色の面で塗り、gradient、光彩、色付きの影は使わない。文字は本文・補足・見出しの3段と桁揃えの時刻書体に限る。Glassは浮くもの(HUD、menu、main/miniの`LifeLogComposerBar`)だけに使い、sidebarとtoolbarはsystemの素材に任せる。設定sectionは`panelSurface`の淡い塗りと細い罫線で区切る。大見出しは`titleFont`（28 pt bold rounded）の1段だけ足す。`SettingsCard`は行の間へ罫線を自動で入れ、各画面は`Divider`を置かない |
| `MenuBarPanel` | 用途別quick action。Tabで隠さず、ライフログと音声入力を同じ文法の二枚のcardに並べる。各cardは左に丸い主操作（ライフログは`LifeLogRecordButton`、音声入力は同じ直径のmic/停止button）、右に状態と補足、区切り線の下に行き先を置く。ライフログcardは記録状態と自動記録の時刻（なければ今日の件数）、今日のmain/mini window入口、音声入力cardはhotkey、直前結果、履歴入口、mode menuを持つ。共通footerは設定と終了だけに限定する。行き先はglass buttonによるtext rasterizationを避け、plain button内にsystem fontを直接描画する |
| `MenuBarLabel` | 音声入力のphase、入力level、ライフログcapture状態。どの状態でも`MenuBarStatusIcon`がapp iconと同じ「L.」を描き、状態は「.」の色だけで示す。録音中（音声入力またはライフログ）はrose、処理中はviolet、完了はmint、整形skip・clipboardのみ・失敗はgold、ライフログ再接続中はgoldの輪。音声入力の状態をライフログより優先する。入力level表示が有効な録音中は「.」が直近の入力levelで膨らむ。状態がない時はtemplate画像にしてmenu barの明暗をsystemに任せ、色がある時は「L」を`labelColor`で描く |
| `MainWindowView` | `NavigationSplitView`。全高sidebarの上部navigation rowで`lifeLog` / `history`を切り替え、`lifeLog`表示中だけnavigationの下へ`MonthActivityCalendar`を置く。Windowは`.fullSizeContentView`と`.unified` toolbarで、sidebarがtraffic lightを含む全高のsystem素材になる。初回はonboarding、通常起動は`lifeLog`を開く |
| `LifeLogWindow` | 中央のtimelineと右の`.inspector`（`LifeLogDayInspector`）。Timeline本体はevent/utterance/dictation/memoを一列の時刻順で表示し、column headerを持たない。日付選択時はsnapshotを再取得し、inspectorとtimelineを同じ`LifeLogDay`から更新する。検索buttonは`Command-F`も受け、発話・音声入力・memoの検索結果だけをtimeline itemへ移動する。表示開始時だけ今日を読み込んで末尾へscrollし、その後のreloadでは閲覧位置を保つ。Calendarは`MainWindowView`のsidebarに置く。Timelineは約680 ptの列をwindow中央に置き、scrollする大見出し（「今日」、日付と曜日、記録状態、終日の予定）から始まる。Inspector切替/検索/書き出しはwindow toolbarの`ToolbarItemGroup`に置く。Main windowはAppKit windowにhostしたviewでSwiftUIのsceneを持たず`SceneStorage`が値を保てないため、inspectorの表示は`AppStorage`に残す。記録がない日は、timelineの縦線の位置に`TimelineRowFrame`で案内の一行を置く。行の並び、予定区間の線の色、空き時間はUIから独立した`LifeLogTimelineLayout`が決め、`CalendarEventCard`と`TimelineEntryRow`は共通の`TimelineRail`の上に描く。最下部は`safeAreaInset`で浮かせた`LifeLogComposerBar`で、scroll edge effectがtimelineとの境界を作る |
| `LifeLogCaptureControl` | Menu barのcapture状態と開始・停止操作。状態のsymbol、文言、semantic colorは`LifeLogCaptureStatus`で一か所に決め、main/miniの`LifeLogComposerBar`と共有する。停止中は「記録を開始」のblue、記録開始意図がある間は「停止」のrose。停止中は状態の補足文を重ねない。録音と文字起こしの内部Boolの中間状態を文言へ直接投影せず、利用者向け状態を安定させる。自動記録が有効なら、scheduleが始めた記録中は終了時刻、停止中は次の開始時刻を補足に出す |
| `LifeLogScheduleSettingsView` | ライフログ設定の「自動記録」card。有効化、曜日capsule、開始・終了時刻を`AppEnvironment.updateLifeLogSchedule`へ渡し、次の時間帯を補足に示す |
| `LifeLogTranscriptionProgressRow` | `LifeLogCoordinator.activeTranscriptionStartedAt`がある間だけMain/miniの`LifeLogComposerBar`直上へ浮いた一行として表示し、認識対象audio長、1秒ごとの処理経過時間、Shimmerで実際のSTT job実行中を示す。発話burstの確定待ちや録音状態は表現しない |
| `LifeLogExportSheet` | 表示開始時のdate/dayをsnapshotとして保持し、cancel可能なbackground taskで人間向けMarkdownを一度だけ生成する。previewは折り返し可能な上限付きtextとし、完全版をcopy/fileへ再利用する。生成中と書込中はprogressを表示し、MainActorではclipboardとpanel操作だけを行う |
| `LifeLogSearchSheet` | 横断検索。結果の印と色を`TimelineEntryRow`と揃え（発話は灰の波形、音声入力はvioletのkeyboard、memoはorangeのpencil）、一致した語を`AttributedString`で強調する。選択中の結果は入力欄の`onKeyPress`で↑↓に動かし、`onSubmit`で開く |
| `ModesSettingsView` | 共通ruleとmodeの編集。Scrollせず、settings windowの高さに固定した中で指示文の入力欄だけを伸縮させる。入力欄は理想の高さを小さく取り、長い指示文でもpaneがwindowより高くならない |
| `HistoryBrowserView` | 音声入力履歴の一覧column（toolbar検索）と、大見出しの時刻から始まる詳細。詳細は読みやすい幅で中央に置き、挿入した文章を本文として大きく、聞き取った文字を補助として示す。かかった時間は話し終わってから挿入までを聞き取り・仕上げ・挿入の帯に分ける。コピー、削除 |
| `LifeLogMiniWindow` | title barを隠し、予定、utterance、dictation、memoを一列の時刻順で表示する。`CurrentCalendarEventStrip`をtimeline上部へ固定し、表示時は今日を読み込んで末尾へscrollする。Window全体を`VisualEffectBackground`の半透明素材で描き、Mainと同じ`LifeLogComposerBar`を最下部へ浮かせる。`AppEnvironment`がwindow levelを常に`.floating`、collection behaviorを`.canJoinAllSpaces`と`.fullScreenAuxiliary`に固定し、利用者がclose操作またはtoggle hotkeyを使うまで非表示にしない。`HotkeyMonitor`は成立したkey-downを保持し、対応するkey-upだけでreleaseを通知するため、修飾キーなしの同じ文字入力はtoggleしない |
| `LifeLogComposerBar` | main/mini windowの最下部に浮かぶglass capsule。左端の記録button（停止中はblueの録音記号、記録意図がある間はroseの停止記号）と状態text、続いて`LifeLogMemoComposer`を並べる。Memoを受け付けない過去日は記録操作と状態だけを持つ |
| `LifeLogMemoComposer` | main/mini windowで共有するchat形式のmemo入力。空白を除外し、送信済みtextをclearして`LifeLogCoordinator.addMemo`へ渡す。送信と音声は同じ直径の円形controlにし、音声ボタンは`AppEnvironment.toggleVoiceMemo`と同じactionを受け、準備中、録音中、別処理中の状態だけを描画する |
| `TimelineEntryRow` | main/miniで共有する1行。Memoだけはhoverの編集buttonかdouble-clickでinline編集し、空文字を除いて`LifeLogCoordinator.updateMemo`へ渡す。作成時刻は変えない。左の時刻列と`TimelineRail`の印（発話は点、memo・音声入力は記号）を持つ |
| `LifeLogDayInspector` | Inspector「この日」。話した時間（発話のstart〜endの合計）と件数、`LifeLogDayMap`を表示する。Day mapは`LifeLogDayMapLayout`が決めた時間範囲（記録と予定を含み最低9〜18時）を高さに合わせて縦に割り、時刻目盛り、記録の印、重なりを列に分けた予定block、今日の現在時刻線を描く。予定blockと任意の位置のclickは`LifeLogCoordinator.jumpToTime`へ渡す |
| `LifeLogCalendarSettingsView` | calendar選択、参加filter、選択日の予定を明示的に再取得する操作と進行状態 |
| `SyncSettingsView` | 共通の「同期」section。新しく始める（folder選択→同期コード表示）、同期コードで参加、状態・最終同期・error、今すぐ同期、確認つきの同期コード再表示、同期の解除 |
| `SettingsWindowView` | 一般（表示言語を含む）、語彙、privacy、同期、連携、音声入力、AI整形、mode、ライフログ、calendar。Privacyは保存場所の下にLore dataの合計使用量を一行で示す。各設定行は操作列を共通幅で確保し、Pickerなど可変幅controlの右端を揃える |
| `WhisperModelSettingsView` | 音声入力とライフログで共有するcurated local modelを列挙し、選択、download進捗・cancel・再試行・削除・使用中状態を表示する。両方の設定画面で同じviewを使う |
| `DismissibleNoticeBanner` | 継続可能なmessageと明示的な`×`を表示する。Dismiss actionは表示stateだけをclearし、capture requestやretry taskを変更しない |
| `HudController` / `HudView` | 通常音声入力またはボイスメモのrecordingから終了までの一時表示。普段は高さ44 ptのglass capsuleで、左から状態の印（録音中は入力levelで脈打つrose、処理中は回る弧、終了時は結果の記号）、録音中は波形と経過時間・それ以外は状態の語、mode、escを並べる。逐次textや終了時の補足があるとcapsuleの上へ本文の段が伸び、角の丸い板へ形を変える。逐次textは末尾の約100字だけを見せる。入力deviceはtooltipに置く |

## 10. 自動化境界

LifeLogTextExporterは90秒未満の連続発話を別種の表示項目で区切ってまとめます。LifeLogExportSheetはプレビューもbackgroundで4,000文字に制限します。timelineの予定rowは淡い塗りと左端の色帯で発話と区別します。

`LoreAutomationService`がCLIとMCPで共有され、記録がある日の一覧、期間の構造化項目、日別export、横断検索を読み取り専用で提供します。期間取得は画面と同じ`LifeLogStore.day`を日ごとに読み、音声入力優先の発話projectionと参加中予定filterをそのまま使います。Loreへの書き込みは提供しません。App Intentsは`AppEnvironment.boot()`の完了後にcapture開始・終了だけを実行します。開始Actionはマイクを扱うためforeground mode、終了Actionはbackground modeです。Shortcutsからの実行にはmacOSが検証できるbundle署名が必要なため、buildは有効な`Apple Development` identityを自己署名より優先します。公開コマンドとtool schemaは外部仕様に列挙します。

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
| 永続model変更 | `Domain`, `LoreDatabase.migrator`, 対応Store | migration test、backup/delete test、design |
| dictation状態変更 | `SessionDraft`, `DictationCoordinator`, `HistoryStore` | HUD/history、state tests、spec/design |
| 音声入力とlife-logの重複解決 | domainの共通projection, `LifeLogStore`, search/export | 成功・cancel・失敗・時間境界test、`make ui-test`、spec/design |
| 公開自動化変更 | `LoreAutomationService`, CLI/MCP/AppIntents | tool schema/help、spec.md/spec.html |
| 主要window変更 | `LoreApp`, 対応View, `AppEnvironment` | `make ui-test`、spec/design |
| life-log timeline表示変更 | `LifeLogWindow`, `LifeLogMiniWindow`, `MonthActivityCalendar` | 初回だけのscroll、予定を含む一列timeline、calendarの今日/選択表現、UI test、spec/design |
| 日別export変更 | `LifeLogTextExporter`, `LifeLogExportSheet`, CLI/MCP | 音声入力の独立選択、人間向けMarkdown、background生成、snapshot整合、`swift test`、`make ui-test`、spec/design |
| global hotkeyの対イベント | `HotkeyMonitor` | 登録型hotkeyのmodifier変換と競合分離、修飾キーなしの同一文字key-upを素通しする回帰test、`swift test` |
| menu bar状態表示変更 | `MenuBarLabel`, `DictationCoordinator`, `LifeLogCoordinator` | 状態別表示test、`make ui-test`、spec/design |
| 音声構成変更時の再接続 | `ContinuousAudioCapture`, `LifeLogCoordinator` | retry policyと一時停止状態test、`swift test`、spec/design |
| life-log audio保持policy | `AppSettings`, `LifeLogStore`, `AppEnvironment`, `LifeLogSettingsView` | 処理成功・未処理・失敗・7日/30日境界test、`swift test`、spec/design |
| ボイスメモ | `DictationCoordinator`, `LifeLogCoordinator`, `AppEnvironment`, `AppSettings` | memoのみを作るdestination test、hotkey/UI test、spec/design |
| 同期対象・形式変更 | `SyncEngine`, `SyncStore`, `v10-sync` trigger, `SyncFileFormat` | 暗号・改ざん・途中file、後勝ち、tombstone、suppress、cursor test、PRIVACY、spec/design |
| calendar手動再取得 | `LifeLogCoordinator`, `LifeLogCalendarSettingsView` | 再取得中UI、`make ui-test`、spec/design |

## 13. テスト配置

`Tests/LoreKitTests`はdomain、formatting、engine、persistence、life log、automationを対象にします。同期は`SyncTests`が、同期コードとfileの暗号（違う鍵、改ざん、途中まで、新形式）と、2つのin-memory DBと一時folderによる往復（memo・履歴・語彙・発話、後勝ち、tombstone、保持期間と一括削除の非伝播、初回snapshot、読めないfileでのcursor停止、番号の非再利用、解除）、`v10-sync` migrationを検証します。`AdaptiveSpeechSegmenter`はbackground noiseの校正と追従、一定noiseだけではjobを作らないこと、相対的な発話levelが250ms続けば開始すること、30秒未満/以上の有声境界で1.5/1秒へ切り替わること、5分で安全flushすることをclock非依存のdomain testで固定します。統合testはwhisper.cppのpreview cadence、chunkをまたぐaudio offset timestamp、録音session開始時の語彙snapshot、失敗後の保存audio再処理を検証します。`make ui-test`は本番と別のbundle IDを持つ署名済み`LoreUITests.app`を別process instanceとして起動し、`Scripts/LoreUIE2E.swift`から主要CUJを検証します。UI test bundleは常に専用UserDefaultsとインメモリDBを使い、global hotkeyと権限監視を起動しません。E2E runnerは専用bundle ID以外のappを終了せず、本番bundle IDを指定された場合は実行を拒否します。詳細な実行方法とE2E契約は[testing.md](testing.md)を参照してください。
