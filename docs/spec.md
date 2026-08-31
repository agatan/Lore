# Koe 外部仕様

本書はKoeの利用者と自動化クライアントから観測できる仕様をまとめた正本です。[HTML版](spec.html)も同じ公開面を扱います。内部構造は[design.md](design.md)、データの詳細は[PRIVACY.md](../PRIVACY.md)を参照してください。

## 1. 動作環境と製品境界

| 項目 | 仕様 |
|---|---|
| OS | macOS 26以降 |
| CPU | Apple Silicon |
| 配布形態 | メニューバー常駐macOS app。Dockには常駐しない |
| 必須権限 | マイク。カーソル位置への挿入にはアクセシビリティ |
| 任意権限 | ライフログに予定を表示する場合のcalendar |
| 音声認識 | Apple SpeechAnalyzerによるオンデバイス認識 |
| 既定の文章処理 | Apple Foundation Modelsによるオンデバイス処理 |
| 保存 | Mac内のSQLite、UserDefaults、Keychain、ライフログaudio file |

対象外はmacOS以外、音声fileの一括文字起こし、音声commandによるアプリ操作、通常の音声入力audioの保存、cloud STTです。

## 2. 初回起動と権限

- 初回はonboardingを表示し、マイク、入力操作、任意のcalendar権限と保存範囲を説明します。
- 通常起動ではメニューバー常駐に加えてmain windowを開き、ライフログを選択した状態で表示します。
- マイク権限がなければ録音できません。アクセシビリティ権限がなければ結果を対象appへ挿入できません。
- calendar権限は音声入力には不要です。
- ライフログ開始時は、30秒単位の復旧用audioをMac内へ保存することを初回だけ確認します。同意前にShortcutsから開始した場合は、Koeを開いて同意するようエラーを返します。

## 3. 音声入力

### 3.1 操作

- 既定hotkeyは右Optionです。
- 短押しは開始・停止のtoggle、長押しはpush-to-talkとして離した時に停止します。既定の長押し判定は500msです。
- menu barからも開始・停止できます。同時に進行できる音声入力は一つです。
- 録音中のEscは挿入をcancelします。認識済みtextがあれば`cancelled`履歴として残ります。
- 録音中、認識中、整形中、挿入中、完了または失敗をHUDとmenu barに表示します。HUD、効果音、入力level表示は設定で切り替えられます。

### 3.2 認識、mode、語彙

- 音声はSpeechAnalyzerへstreamし、暫定textをHUDへ表示します。通常の音声入力audioはfileやDBへ保存せず、外部へ送信しません。
- 録音開始時の前面appからmodeを一度決め、そのsession内では固定します。手動固定は自動選択より優先します。
- modeは名前、対象bundle ID pattern、文章化の指示、言語、任意のmodel指定を持ち、作成、編集、削除、並べ替えができます。
- 共通ruleは全modeへ適用されます。
- 語彙は表記、任意の読み、誤認識pattern、有効/無効を持ち、STT hintと文章処理の指示へ反映します。
- 履歴からの語彙候補はMac内で分析し、根拠を確認して承認したものだけ登録します。

### 3.3 文章処理

音声入力とライフログの文章処理先は別々に選べます。

| 選択肢 | 送信境界 |
|---|---|
| Apple Foundation Models | Mac内で処理 |
| Ollama | `localhost:11434`へ送信 |
| LM Studio | `localhost:1234`へ送信 |
| OpenAI / Anthropic / Gemini / Groq | 利用者が明示選択したproviderへ文字dataを送信 |

cloud音声入力で送るのは今回の文字起こし、共通rule、mode指示、有効な語彙です。録音audio、過去履歴、前面app名・bundle ID、API keyはprompt dataとして送りません。処理は質問への回答ではなく文章変換として実行します。

空出力、異常な長さ、指示漏洩の兆候、timeout、provider errorでは、生の文字起こしをそのまま挿入します。利用したprovider/modelとfallback理由は履歴で確認できます。

### 3.4 挿入と履歴

- 結果は録音開始時に対象だったappのカーソル位置へ一括pasteします。
- 既存clipboardを一時退避し、成功後に元へ戻します。挿入できなければ結果をclipboardに残して通知します。
- STT確定後は文章処理より先に生textを履歴へ保存します。
- 履歴は日時、対象app、modeと最終指示、STT/LLM providerとmodel、生text、結果、status、error、各段の時間を表示できます。
- statusは`interrupted`、`completed`、`cancelled`、`failed`、`fallback`、`clipboard_only`です。
- 生textと結果の日本語部分一致検索、再copy、個別削除、一括削除ができます。
- 履歴保持期間は日数または無期限を選べ、現在の保存件数を設定画面で確認できます。

### 3.5 ボイスメモ

- 専用global hotkey、main windowとmini windowのmemo入力欄にある音声ボタンは、いずれも押すたびに録音開始・停止を切り替え、認識した生textを今日のライフログmemoとして保存します。文章整形、前面appへの挿入、通常の音声入力履歴への保存は行いません。
- memo入力欄の音声ボタンは、開始準備中をprogress表示、録音中をKoeのblueと調和するrose色とpulse animationで示し、通常の音声入力など別の音声処理中は新規開始できません。
- ライフログ記録中に開始した場合は、現在の復旧用audio chunkを確定してライフログcaptureを一時停止します。ボイスメモの完了、cancel、失敗後は、利用者の記録開始意図が残っている場合だけライフログを自動再開します。
- この排他境界により、一回のボイスメモはmemo一件だけを作り、通常の音声入力履歴やライフログutteranceへ同じ内容を追加しません。

## 4. ライフログ

### 4.1 記録

- ライフログは通常の音声入力と独立して開始・停止でき、同時利用できます。
- menu bar、main window、専用global hotkey、macOS Shortcutsから操作できます。
- ライフログが実際に録音している間も、menu barのKoe icon本体はmonochromeで表示し、右下の小さなrose色badgeだけを着色します。停止中と再接続待ちではbadgeを外し、再接続待ちを録音中とは表示しません。
- 音声入力との同時利用中も、復旧可能なライフログaudioの記録は中断しません。音声入力が成功した区間はそのraw transcriptを正本とし、同じ録音時間帯にライフログ側で認識した発話はtimeline、検索、書き出し、summary/TODO生成へ重複して出しません。音声入力がcancelまたは失敗した場合は、ライフログ側の発話を残します。
- 入力deviceを選択できます。記録中は30秒ごとに復旧用`.m4a`をMac内へ確定します。audioをcloud STTへ送ることはありません。
- 保存済みaudioは文字起こしと派生処理が両方成功するまで必ず保持します。既定の「処理後削除」では成功直後にaudioだけを削除し、保存済みの発話、conversation、summary、TODOは残します。設定は「処理後削除」「7日」「30日」から選べます。
- 7日または30日を選んだ場合も、未処理・失敗chunkは期間を超えて保持し、次回起動後の再処理に使います。保持期間を短く変更したときは、新しい条件を満たす処理済みaudioを削除します。
- 記録中の一時中断と、既定マイクの切替・接続解除などの音声構成変更では、現在のchunkを確定して自動再接続します。sleep時も安全に閉じ、記録意図が残ればwake後に再開します。マイク権限が失われた場合だけ自動再試行しません。
- app終了時は保存・認識・最終派生処理を待ちます。完了できなかった保存済みchunkは次回起動時に再処理します。

### 4.2 日別表示

- main windowは「ライフログ」と「音声入力」を切り替え、ライフログを既定表示にします。
- ライフログは月間activity calendar、選択日のtimeline、summary、global TODOを表示します。
- timelineは時刻付き発話、text memo、calendar予定を区別します。今日のtimeline最下部とミニwindowには同じchat形式の入力欄があり、送信したmemoを今日のtimelineへ即時追加します。送信ボタンと音声入力ボタンは同じ直径の円形controlに揃えます。過去日の履歴へ現在のmemoを混入させないため、main windowの入力欄は今日を選択中だけ表示します。
- ボイスメモも手入力と同じmemoとして今日のtimelineへ追加します。
- 発話は90秒以上の無発話でconversationに分けます。予定との関連は前後2分のずれを許容しますが、予定境界だけではconversationを分けません。
- 日付をまたぐ記録は実時刻の日へ分配され、表示が今日を追従中なら新しい日へ切り替わります。

### 4.3 Calendar

- 選択したcalendarの予定を読み取り、時刻、件名、calendar名、終日、参加statusのsnapshotを保存します。
- 既定では参加済み、またはRSVPのない予定だけを表示・派生処理に含めます。このfilterは変更できます。
- Calendar設定の「予定を再取得」から、現在timelineで選択している日の予定を明示的に読み直せます。処理中は連打できず、完了後にtimelineと月間activityを更新します。
- KoeからRSVPを変更せず、Calendar appへの操作導線も提供しません。

### 4.4 SummaryとTODO

- summaryとdraft TODOを30分、1時間、2時間の設定間隔で同時更新します。
- 前回更新後に発話またはmemoが増えた場合だけ処理し、対象日の全発話、memo、対象予定から作り直します。入力上限を超える場合は時系列に分割して統合します。
- 当日のライブsummaryには生成時刻を基準時点として渡し、予定を「終了済み」「進行中」「これから」に区別します。開始前の予定を実施済みの事実として書かず、「このあと予定されている」内容として明示します。
- 日付が変わった後の最終summaryは、発話やmemoの追加がなくても対象日の全予定を含めて作り直し、`isFinal`として保存します。
- 停止時は記録対象日を最終更新します。audio chunkごとにはLLMを呼びません。
- draft TODOは未確定候補です。編集して確定、または棄却できます。次回生成時に置換されるのはdraftだけで、確定・完了TODOは変更しません。
- TODOは`draft`、`open`、`completed`を持ち、全TODO window、CLI、MCPで追加、編集、完了、再開、削除できます。
- TODOが発話またはmemoの出典情報を持つ場合は「元の発言へ」を表示します。選ぶと出典の日へ移動し、該当するtimeline行を中央へscrollして強調します。意味の伝わらない記号だけの操作にはしません。
- summary用とTODO用の指示文は設定、CLI、MCPから編集できます。
- cloudを選んだ場合は対象日の発話、memo、予定の時刻と件名、各指示文を送ります。録音audio、通常の音声入力履歴、前面app情報は送りません。
- Groqで選んだmodelにかかわらず、summaryとTODO案は再現性を優先する温度0、modelが対応する最小の推論量、共通のJSON出力contractで生成します。APIが対応する最も強いschema制約を使い、最終的にKoeが同じ型として検証します。推論本文は応答dataへ含めません。

### 4.5 検索と書き出し

- 発話、memo、TODO、summaryを日本語部分一致で横断検索します。
- 日別書き出しはcalendar、発話、memo、summary、その日に作成または完了したTODOを個別選択できます。
- open TODO全体を別に書き出せます。
- UIではclipboardまたはfile、Shortcutsではclipboard、返却file、指定folderへの上書き保存を利用できます。

## 5. 画面と設定

Koeのprimary colorはapp icon由来の爽やかなblueに固定し、利用者がcolor themeを切り替える設定は持ちません。録音、成功、警告は同じbrand paletteに合わせたsemantic colorを全画面で共有します。

| 場所 | 公開機能 |
|---|---|
| Menu bar | ライフログ/音声入力の用途別quick action。ライフログは記録切替、今日の画面、mini window、音声入力は録音、mode、直前結果、履歴を各tab内にまとめ、共通footerは設定と終了だけを置く。「今日を開く」「ミニウィンドウ」はsystem fontを直接描画するcompact buttonとする |
| Main window | 通常起動時にライフログを選択して表示。onboarding、ライフログ、今日のtimeline最下部からの手入力・音声memo追加、音声入力履歴。停止中のcapture操作はrose色の録音記号と「録音を開始」、録音中は停止記号と「録音を停止」を表示する |
| Mini window | ライフログ状態、今日のtimelineへの手入力・音声memo追加。常に手前を設定可能 |
| 全TODO window | draft確認、編集、確定、完了、再開、削除 |
| Settings: 共通 | 一般、利用状況、語彙、privacy、連携 |
| Settings: 音声入力 | hotkey、feedback、履歴、AI整形、mode |
| Settings: ライフログ | 記録・mini window・ボイスメモhotkey、入力device、audio保持、summary間隔、要約/TODO AI、calendar再取得 |

利用状況には音声入力回数・時間、ライフログ記録時間、cloud AIの実測token数、Koe dataのstorage使用量を表示します。local modelはcloud token集計に含みません。

## 6. 保存、backup、削除

| Data | 保存先 | 既定保持 |
|---|---|---|
| 履歴、mode、語彙、ライフログ、TODO、利用量 | `~/Library/Application Support/Koe/koe.sqlite` | 履歴は無期限、各設定に従う |
| ライフログaudio | Application Support配下 | 文字起こし・派生処理の成功後に削除。7日または30日へ変更可能 |
| 一般設定 | app UserDefaults | app data削除まで |
| API key | macOS Keychain | 個別削除まで |
| DB backup | `~/Library/Application Support/Koe/Backups/` | 最新7file |

- 既存DBは未適用migrationの直前にbackupします。通常起動でも同日重複なしで1日1回backupします。
- backupに失敗した場合はmigrationを開始しません。
- 「全データを削除」は履歴、mode、語彙、ライフログ、TODO、保存audio、DB backupを削除します。設定とKeychainは画面で示す個別範囲に従います。
- 履歴から語彙候補へ複製済みの短い根拠は履歴とは別dataであり、履歴だけの削除では残る場合があります。

## 7. macOS Shortcuts / App Intents

| Action | Input / Output |
|---|---|
| ライフログを開始 | 冪等に開始。audio保存同意がなければerror |
| ライフログを終了 | 停止し、文字起こしと最終summaryを待つ |
| ライフログを書き出してcopy | 任意日とinclude項目を受け、clipboardへcopy |
| ライフログをfileにする | 任意日、include項目、folder、`{{date}}`対応filename。folder指定時は同名をatomic上書き |
| 未実施TODOをすべてcopy | 確定済みopen TODOをclipboardへcopy |
| 未実施TODOをfileにする | `Koe-Open-TODO.txt`を返す |

## 8. CLI

実行名はbuild productでは`koe-cli`、配布・link後の利用名は`koe`です。成功時は標準出力、失敗時はstderrへ`koe: ...`を出してexit status 1を返します。

```text
koe export day [--date YYYY-MM-DD] [--include calendar,speech,memos,summary,todos] [--clipboard|--output PATH]
koe export todos [--clipboard|--output PATH]
koe todo list [--status open|draft|completed|all]
koe todo add "タイトル" | complete ID | reopen ID | delete ID
koe prompt get summary|todo
koe prompt set summary|todo "プロンプト"   # - で標準入力
koe search "検索語" [--limit N]
```

`--clipboard`と`--output`は同時指定できません。`--output .`は既定filenameを現在directoryへ書きます。TODO一覧と検索結果はtab区切りです。

## 9. MCP

`koe-mcp`は1行1JSONのstdio JSON-RPC serverです。MCP protocol versionは`2025-03-26`、server versionは`1.0.0`です。notificationには応答しません。tool errorはJSON-RPC成功response内の`isError: true`とtextで返します。

| Tool | Arguments |
|---|---|
| `life_log_export` | `date?: YYYY-MM-DD`, `include?: [calendar,speech,memos,summary,todos]` |
| `todo_export_open` | なし |
| `life_log_search` | `query: string`, `limit?: integer` |
| `todo_list` | `status?: open|draft|completed|all`。省略時open |
| `todo_add` | `title: string` |
| `todo_update` | `id: string`, `title?: string`, `status?: open|draft|completed` |
| `todo_delete` | `id: string` |
| `prompt_get` | `kind: summary|todo` |
| `prompt_set` | `kind: summary|todo`, `value: string` |

## 10. 障害時の外部挙動

- STTを確定できない場合は`failed`として理由を表示します。process再起動が必要なSpeechAnalyzer状態は利用者へ再起動を案内します。
- 整形失敗はraw transcriptへのfallback、挿入失敗はclipboard退避になります。
- DB初期化、保存、検索、backupの失敗は成功として扱わず、画面、CLI、MCPまたはlogへ理由を出します。
- ライフログcapture中断は記録が有効な間だけ自動再接続し、保存済みchunkを失いません。
- Shortcutsの停止が時間切れになった場合、保存済みaudioは次回起動時に再処理されることをerrorへ含めます。

## 11. 受け入れ条件

1. オンデバイス構成では文字起こしと指示文がMac外へ送られない。
2. cloud構成は利用者の明示選択後だけ使われ、送信範囲を設定画面で確認できる。
3. 通常の音声入力audioは保存されず、ライフログaudioは同意後だけ保存される。
4. 整形失敗後もraw transcript、挿入失敗後もclipboardから内容を回収できる。
5. 履歴から当時のmode、指示、provider、model、結果、状態を確認できる。
6. 保留ライフログchunkは再起動後に再処理される。
7. migration前backupと日次backupが作られ、合計7file以内に保たれる。
8. CLI、MCP、Shortcutsの公開interfaceが本書と一致する。
9. ライフログの実録音中だけmenu barのmonochrome Koe icon右下にrose色badgeが表示され、停止または再接続待ちではbadgeなしへ戻る。
10. ライフログ記録中に成功した音声入力は一件だけ表示・検索・書き出し・派生処理へ現れ、cancelまたは失敗した音声入力の時間帯はライフログ発話が失われない。
11. 当日のライブsummaryは未来の予定を実施済みとして書かず、日付変更後の最終summaryはその日の全予定を含む。
12. Calendar設定から予定を再取得すると、現在選択日のsnapshot、timeline、月間activityが更新される。
13. マイク切替などの音声構成変更後も、記録開始意図が残る限りライフログcaptureが自動再開する。
14. ボイスメモ一回につきmemoだけが一件作られ、通常の音声入力履歴とライフログutteranceには同じ内容が追加されない。
15. 通常起動時にmain windowのライフログ画面が開き、memo入力欄の音声ボタンは専用hotkeyと同じボイスメモを開始・停止する。
16. 「処理後削除」でも未処理・失敗chunkは残り、文字起こしと派生処理が成功したaudioだけが削除される。
