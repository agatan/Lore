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

## 4. ライフログ

### 4.1 記録

- ライフログは通常の音声入力と独立して開始・停止でき、同時利用できます。
- menu bar、main window、専用global hotkey、macOS Shortcutsから操作できます。
- 入力deviceを選択できます。記録中は30秒ごとに復旧用`.m4a`をMac内へ確定します。audioをcloud STTへ送ることはありません。
- 保存済みaudioの既定保持期間は30日で、無期限を含む設定値へ変更できます。
- 記録中の一時中断は自動再接続します。sleep時は安全に閉じ、記録意図が残ればwake後に再開します。
- app終了時は保存・認識・最終派生処理を待ちます。完了できなかった保存済みchunkは次回起動時に再処理します。

### 4.2 日別表示

- main windowは「ライフログ」と「音声入力」を切り替え、ライフログを既定表示にします。
- ライフログは月間activity calendar、選択日のtimeline、summary、global TODOを表示します。
- timelineは時刻付き発話、text memo、calendar予定を区別します。ミニwindowからmemoを追加できます。
- 発話は90秒以上の無発話でconversationに分けます。予定との関連は前後2分のずれを許容しますが、予定境界だけではconversationを分けません。
- 日付をまたぐ記録は実時刻の日へ分配され、表示が今日を追従中なら新しい日へ切り替わります。

### 4.3 Calendar

- 選択したcalendarの予定を読み取り、時刻、件名、calendar名、終日、参加statusのsnapshotを保存します。
- 既定では参加済み、またはRSVPのない予定だけを表示・派生処理に含めます。このfilterは変更できます。
- KoeからRSVPを変更せず、Calendar appへの操作導線も提供しません。

### 4.4 SummaryとTODO

- summaryとdraft TODOを30分、1時間、2時間の設定間隔で同時更新します。
- 前回更新後に発話またはmemoが増えた場合だけ処理し、対象日の全発話、memo、対象予定から作り直します。入力上限を超える場合は時系列に分割して統合します。
- 停止時は記録対象日を最終更新します。audio chunkごとにはLLMを呼びません。
- draft TODOは未確定候補です。編集して確定、または棄却できます。次回生成時に置換されるのはdraftだけで、確定・完了TODOは変更しません。
- TODOは`draft`、`open`、`completed`を持ち、全TODO window、CLI、MCPで追加、編集、完了、再開、削除できます。
- summary用とTODO用の指示文は設定、CLI、MCPから編集できます。
- cloudを選んだ場合は対象日の発話、memo、予定の時刻と件名、各指示文を送ります。録音audio、通常の音声入力履歴、前面app情報は送りません。

### 4.5 検索と書き出し

- 発話、memo、TODO、summaryを日本語部分一致で横断検索します。
- 日別書き出しはcalendar、発話、memo、summary、その日に作成または完了したTODOを個別選択できます。
- open TODO全体を別に書き出せます。
- UIではclipboardまたはfile、Shortcutsではclipboard、返却file、指定folderへの上書き保存を利用できます。

## 5. 画面と設定

| 場所 | 公開機能 |
|---|---|
| Menu bar | ライフログ/音声入力切替、開始停止、直前結果copy、mode固定、window起動、終了 |
| Main window | onboarding、ライフログ、音声入力履歴 |
| Mini window | ライフログ状態、memo追加。常に手前を設定可能 |
| 全TODO window | draft確認、編集、確定、完了、再開、削除 |
| Settings: 共通 | 一般、利用状況、語彙、privacy、連携 |
| Settings: 音声入力 | hotkey、feedback、履歴、AI整形、mode |
| Settings: ライフログ | hotkey、入力device、audio保持、summary間隔、要約/TODO AI、calendar |

利用状況には音声入力回数・時間、ライフログ記録時間、cloud AIの実測token数、Koe dataのstorage使用量を表示します。local modelはcloud token集計に含みません。

## 6. 保存、backup、削除

| Data | 保存先 | 既定保持 |
|---|---|---|
| 履歴、mode、語彙、ライフログ、TODO、利用量 | `~/Library/Application Support/Koe/koe.sqlite` | 履歴は無期限、各設定に従う |
| ライフログaudio | Application Support配下 | 30日 |
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
