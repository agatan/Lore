# Koe 外部仕様


本書はKoeの利用者と自動化クライアントから観測できる仕様をまとめた正本です。[HTML版](spec.html)も同じ公開面を扱います。内部構造は[design.md](design.md)、データの詳細は[PRIVACY.md](../PRIVACY.md)を参照してください。

## 1. 動作環境と製品境界

| 項目 | 仕様 |
|---|---|
| OS | macOS 26以降 |
| CPU | Apple Silicon |
| 配布形態 | メニューバー常駐macOS app。Dockには常駐しない |
| 必須権限 | マイク。カーソル位置への挿入にはアクセシビリティ。Option+文字keyのhotkeyには入力監視 |
| 任意権限 | ライフログに予定を表示する場合のcalendar |
| 音声認識 | 音声入力・ボイスメモとライフログで個別に、Apple SpeechAnalyzerかlocal downloadしたwhisper.cpp GGML modelを選択。whisper.cppは音声入力では停止後の一括認識、ライフログでは発話burstの遅延認識 |
| 既定の文章処理 | Apple Foundation Modelsによるオンデバイス処理 |
| 表示言語 | システム設定、英語、日本語、簡体字中国語から選択可能。既定はシステム設定 |
| 保存 | Mac内のSQLite、UserDefaults、Keychain、ライフログaudio file |

対象外はmacOS以外、任意の音声fileの一括文字起こし、音声commandによるアプリ操作、通常の音声入力audioの保存、cloud STTです。

## 2. 初回起動と権限

- 初回はonboardingを表示し、マイク、入力操作、任意のcalendar権限と保存範囲を説明します。
- 通常起動ではメニューバー常駐に加えてmain windowを開き、ライフログを選択した状態で表示します。
- app起動だけではライフログ記録を開始しません。前回processの記録開始意図は復元せず、起動後の明示的なUI、hotkey、Shortcuts操作でだけ開始します。
- マイク権限がなければ録音できません。アクセシビリティ権限がなければ結果を対象appへ挿入できません。Option+文字keyのhotkeyは入力監視権限がなければ開始しません。
- calendar権限は音声入力には不要です。
- ライフログ開始時は、30秒単位の復旧用audioをMac内へ保存することを初回だけ確認します。同意前にShortcutsから開始した場合は、Koeを開いて同意するようエラーを返します。

## 3. 音声入力

### 3.1 操作

- 既定hotkeyは右Optionです。
- 短押しは開始・停止のtoggle、長押しはpush-to-talkとして離した時に停止します。既定の長押し判定は500msです。
- 文字keyを含むhotkeyはmacOSの標準event dispatcherへ個別登録します。macOS 26でdispatcherから通知されないことがあるOptionのみ（Option+Shiftを含む）の文字keyは、利用者が入力監視を許可した場合にinput event監視も併用し、先に届いた一組の押下・離上だけを採用します。修飾キー単体と録音中のEscもinput event監視を使います。Secure Input中はinput event監視と対象appへのpasteがmacOSに遮断されます。一つのhotkeyの登録失敗や権限不足でほかのhotkeyを停止しません。
- menu barからも開始・停止できます。同時に進行できる音声入力は一つです。
- 録音中のEscは挿入をcancelします。認識済みtextがあれば`cancelled`履歴として残ります。
- 録音中、認識中、整形中、挿入中、完了または失敗をHUDとmenu barに表示します。HUD、効果音、入力level表示は設定で切り替えられます。

### 3.2 認識、mode、語彙

- 通常の音声入力とボイスメモは既定でApple SpeechAnalyzerへstreamし、暫定textをHUDへ表示します。設定でwhisper.cppを選ぶと、録音開始と並行してmodelを準備し、停止後に録音全体をMac内で一括認識します。この場合、録音中の暫定textは表示しません。通常の音声入力audioはfileやDBへ保存せず、外部へ送信しません。
- whisper.cppへ渡す音声は、前後の無音（約-50 dBFS未満）を0.5秒の余白を残して除きます。有声区間を検出できない場合は録音全体を渡します。停止後の確定待ちは30秒に録音時間を加えた長さを上限とします。
- whisper.cppには有効な語彙の表記を並び順のまま、約200 token以内のpromptとして渡します。2語以上のprompt全体をそのまま読み上げただけのsegmentは、無音から生成された写しとして結果から除きます。
- ライフログも音声入力とは別にSpeechAnalyzerまたはローカルへダウンロードしたwhisper.cpp GGML modelを選べます。連続録音とは分離し、入力signalから検出した発話burstを保存audioから認識します。比較的大きいlocal modelでも入力確認を待たせないよう、発話中は暫定textを表示し、発話確定後にtimestamp付きの最終結果へ置き換えます。
- 発話開始はUI用levelではなく入力signalの線形RMSを使い、約-50 dBFSの絶対下限、校正したbackground noise floorとの差と倍率、継続時間で判定します。開始候補のうち、累積有声時間が0.5秒未満、またはburst全体に占める有声比率20%未満の入力は生活音・無音として破棄し、whisper.cppを起動しません。Whisper.cpp選択時は有効な発話の開始から1.5秒後、前の暫定認識が完了していれば1.5秒ごとに直近5秒を暫定認識します。累積有声時間が30秒未満なら1.5秒、30秒以上なら1秒の連続無音でburstを確定し、wall timeが5分に達した場合も安全のため確定します。
- 暫定textは入力確認専用で、誤認識や語尾が更新されることがあります。DB、timeline、検索、書き出し、summary/TODOへは保存せず、永続化済みaudioを使った最終認識だけを正本にします。
- whisper.cppが無音・環境音から生成する既知の定型文「ご視聴ありがとうございました」は、独立した文として認識された場合に限り表示・保存しません。同じsegmentに続く実発話は残します。
- 有効な発話を確定した時点で現在の復旧用audio chunkも原子的に確定し、参照範囲のaudioが永続化された後に最終認識を実行します。破棄した候補のためにはchunkを分割しません。発話timestampは録音開始時刻とaudio offsetから復元します。録音session開始時の語彙snapshotを完了まで固定し、保存audioの再処理でも同じ発話判定で無音区間を除き、最新の有効語彙を使います。
- whisper.cpp modelは音声入力とライフログで共通の選択です。どちらの設定画面からも一覧、download進捗と失敗理由を確認し、downloadをcancel、再試行、削除できます。Download完了前のmodelは認識に利用できず、ライフログの記録・処理中または音声入力の処理中は削除できません。
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
- app起動時は常に停止状態から始まり、前回終了時に記録中だった場合も自動開始しません。記録中のsleep復帰や入力device再接続は、同じprocessに残る記録開始意図に限って自動再開します。
- ライフログの全画面とmenu barは、実際のaudio writerの稼働状態を同じ記録状態として表示します。実際に録音している間もmenu barのKoe icon本体はmonochromeで表示し、右下の小さなrose色badgeだけを着色します。開始準備中、停止中、再接続待ちではbadgeを外し、それぞれを録音中とは表示しません。
- 音声入力との同時利用中も、復旧可能なライフログaudioの記録は中断しません。音声入力が成功した区間はそのraw transcriptを正本とし、同じ録音時間帯にライフログ側で認識した発話はtimeline、検索、書き出し、summary/TODO生成へ重複して出しません。音声入力がcancelまたは失敗した場合は、ライフログ側の発話を残します。
- 入力deviceを選択できます。記録中は30秒ごと、または発話burstの確定時に復旧用`.m4a`をMac内へ確定します。audioをcloud STTへ送ることはありません。
- audio chunkは耐久化・復旧の単位です。30秒に達する前でも発話確定時にchunkを閉じるため、最終認識は次の定期確定を待ちません。認識はadaptiveな発話burst単位で実行し、持続するnear-silenceを文字起こししません。
- Main windowとmini windowは有効な発話と判定した時点で、記録状態とは別のlive行を表示します。最初は「聞き取り中」と入力audioの長さを示し、暫定認識が返るたびにrolling textを更新します。発話確定後は「文字起こし中」と処理経過時間へ切り替え、最終結果をtimelineへ保存したらlive行を消します。
- Main windowとmini windowのtimelineは初回表示時に最新項目を表示し、利用者が最新位置にいる間だけ、新しい発話・メモ・予定へ自動追従します。利用者が過去へscrollした場合や検索・予定から項目へ移動した場合は追従を止め、末尾へ戻ると再開します。
- ライフログの認識言語は「表示言語に合わせる」「自動判定」「日本語」「English」「简体中文」から選べ、既定は表示言語に合わせます。表示言語が「システム設定」の場合も解決後の対応言語を使います。この設定はライフログだけに適用し、通常の音声入力、ボイスメモ、modeには伝播しません。
- whisper.cppのcontrol tokenとtimestamp tokenはSTT engine境界で認識結果から除き、timeline、検索、書き出し、summary/TODO入力へ新しく保存しません。過去に保存されたtextへ表示時の補正や自動書換えは行いません。
- whisper.cppの既定modelは量子化済みWhisper Large v3 Turbo Q5_0 (574 MB)です。非TurboのLarge v3 Q5_0も明示的に選べます。
- 保存済みaudioは文字起こしと派生処理が両方成功するまで必ず保持します。既定の「処理後削除」では成功直後にaudioだけを削除し、保存済みの発話、conversation、summary、TODOは残します。設定は「処理後削除」「7日」「30日」から選べます。
- 7日または30日を選んだ場合も、未処理・失敗chunkは期間を超えて保持し、次回起動後の再処理に使います。保持期間を短く変更したときは、新しい条件を満たす処理済みaudioを削除します。
- 記録中の一時中断と、既定マイクの切替・接続解除などの音声構成変更では、現在のchunkを確定して自動再接続します。sleep時も安全に閉じ、記録意図が残ればwake後に再開します。マイク権限が失われた場合だけ自動再試行しません。
- app終了時は進行中の操作を割り込み、復旧用audioの確定と必要なDB保存だけを短時間待ちます。終了時にsummary/TODO生成は開始せず、完了できなかった保存済みchunkは次回起動時に再処理します。

### 4.2 日別表示

- main windowは「ライフログ」と「音声入力」を切り替え、ライフログを既定表示にします。
- ライフログは月間activity calendar、選択日のtimeline、summary、global TODOを表示します。
- 通常起動時とmain windowのライフログを開いた時は今日を表示し、dataの読込後にtimeline最下部の最新項目へ一度だけscrollします。mini windowも開いた時に今日を表示して最下部へ一度だけscrollします。その後に新しい認識結果や予定が届いても利用者の閲覧位置を奪いません。
- timeline paneは予定、発話、音声入力、text memoを一列の時刻順で表示し、column headerは置きません。右上の予定buttonは選択日の予定を時刻と件名中心の素朴な一覧で表示します。日付を選ぶとその日の予定を読み直し、一覧とtimelineの両方へ反映します。予定一覧では塗りを使いません。
- 右上の検索buttonまたは`Command-F`で横断検索を開きます。検索結果の発話、音声入力、memoを選ぶと対象日を開いてその項目へ移動し、summaryは対象日へ移動します。TODOは一覧へ表示しますが、出典への移動操作は提供しません。
- mini windowは予定、発話、音声入力、memoを一列の時刻順で表示し、今日進行中の予定をtimeline上部に固定します。OS標準のtitle barは表示せず、Space切替やfull-screen appの利用中も明示的に閉じるまで手前に残ります。Mini windowのtoggle hotkeyは、設定された修飾キーを含む押下と離上が対になった場合だけ切り替え、同じ文字keyだけの通常入力では開閉しません。
- 今日のtimeline最下部とmini windowには同じchat形式の入力欄があり、送信したmemoを今日のtimelineへ即時追加します。記録状態と開始・停止操作はどちらも入力欄の直上に配置します。送信ボタンと音声入力ボタンは同じ直径の円形controlに揃えます。過去日の履歴へ現在のmemoを混入させないため、main windowの入力欄は今日を選択中だけ表示します。
- ボイスメモも手入力と同じmemoとして今日のtimelineへ追加します。
- ライフログの記録意図が続いている間、状態文言は実装内部の文字起こし開始・終了に追従して切り替えず、記録、開始準備、一時停止、再接続の利用者向け状態を安定して表示します。
- 発話は90秒以上の無発話でconversationに分けます。予定との関連は前後2分のずれを許容しますが、予定境界だけではconversationを分けません。
- 日付をまたぐ記録は実時刻の日へ分配され、表示が今日を追従中なら新しい日へ切り替わります。

### 4.3 Calendar

- 選択したcalendarの予定を読み取り、時刻、件名、calendar名、終日、参加statusのsnapshotを保存します。
- 既定では参加済み、またはRSVPのない予定だけを表示・派生処理に含めます。このfilterは変更できます。
- Calendar設定の「予定を再取得」から、現在timelineで選択している日の予定を明示的に読み直せます。処理中は連打できず、完了後にtimelineと月間activityを更新します。
- KoeからRSVPを変更せず、Calendar appへの操作導線も提供しません。
- 月間activity calendarでは今日をprimary colorの塗りで示し、timelineで表示中の日をprimary colorの枠線で示します。同じ日なら両方を併用します。

### 4.4 SummaryとTODO

- summaryとdraft TODOは30分、1時間、2時間の設定間隔、または選択日の左下Summary viewにある手動更新操作で同時更新します。手動更新は差分や設定間隔の有無にかかわらず、選択日のsource of truth全体から作り直します。
- 定期更新は前回更新後にライフログ発話またはmemoが増えた場合だけ処理し、設定間隔が到来した時点で対象日の全発話、memo、対象予定から作り直します。通常の音声入力履歴はsummary/TODOの入力にも更新triggerにも使いません。録音停止、app終了、ボイスメモ、sleep、入力device・音声構成・語彙変更による一時停止・再接続では再要約しません。入力上限を超える場合は時系列に分割して統合します。既存のDraft、未実施、完了TODOの文言をpromptへ渡し、同じ作業を再提案しません。モデルが同じ文言を返しても保存前に除外します。
- 既定promptは日報として読めるMarkdownを要求します。対象日の記録に根拠がある範囲だけで、会議ごとの目的・参加文脈・話題、決定事項と未決事項、考えていたこと・検討の流れ、次の行動を見出しと箇条書きで整理し、根拠のない参加者、決定、感情、因果を補いません。情報がないsectionを作り話で埋めません。
- Summary viewは生成済みMarkdownを見出し、箇条書き、強調、linkとして描画し、raw Markdown文字列をそのまま表示しません。手動更新中は進捗を表示して重複実行を防ぎ、失敗理由を表示して既存summaryとdraft TODOを保持します。
- 当日のライブsummaryには生成時刻を基準時点として渡し、予定を「終了済み」「進行中」「これから」に区別します。開始前の予定を実施済みの事実として書かず、「このあと予定されている」内容として明示します。
- 日付が変わった後の最終summaryは、発話やmemoの追加がなくても対象日の全予定を含めて作り直し、`isFinal`として保存します。
- audio chunkごと、または録音停止時にはLLMを呼びません。
- draft TODOは未確定候補です。編集して確定、または棄却できます。次回生成時に置換されるのはdraftだけで、確定・完了TODOは変更しません。
- TODOは`draft`、`open`、`completed`を持ち、全TODO window、CLI、MCPで追加、編集、完了、再開、削除できます。
- Main windowと全TODO windowのTODO本文は複数行へ折り返し、長い文言でも省略せず表示・編集できます。本文に応じて行の高さを広げます。
- TODOの発話・memo出典情報は説明可能性と将来の監査のため保存しますが、UIに「元の発言へ」などの出典移動操作は表示しません。
- summary用とTODO用の指示文は設定、CLI、MCPから編集できます。
- cloudを選んだ場合は対象日の発話、memo、予定の時刻と件名、各指示文を送ります。録音audio、通常の音声入力履歴、前面app情報は送りません。
- Groqで選んだmodelにかかわらず、summaryとTODO案は再現性を優先する温度0、modelが対応する最小の推論量、共通のJSON出力contractで生成します。APIが対応する最も強いschema制約を使い、最終的にKoeが同じ型として検証します。推論本文は応答dataへ含めません。

### 4.5 検索と書き出し

連続する発話は90秒未満の間隔で途中に別の表示項目がなければ時刻範囲付きの段落へまとめます。プレビューは先頭4,000文字、書き出しは全文です。「この日の約束」は出力せず、「この日発生したタスク」と「この日完了したタスク」を作成日・完了日で抽出します。作成日の一覧には完了済みも含め、未確定Draftは除外します。話題はプロジェクト・活動のタグとして最大5件に整理し、対象日以前90日分（最大100件）の既存話題名と同じ対象なら同じ表記を再利用します。過去日の本文は参照せず、既存タグは再要約時に更新します。Day領域は縦スクロールでき、タイムラインの予定は塗りを使わず細い線と文字の強弱で区別します。

- 発話、memo、TODO、summaryを日本語部分一致で横断検索します。
- 日別書き出しはcalendar、ライフログ発話、通常の音声入力、memo、summary、その日に作成または完了したTODOを個別選択できます。ボイスメモは手入力と同じmemoに含めます。
- 書き出しは日付を見出しにした人間向けMarkdownで、予定、発話、音声入力、memoを読みやすい時系列の箇条書き、TODOをcheckboxとして表します。機械用の英大文字tagやraw metadataは出力しません。
- 書き出し画面は開いた時点のdataをsnapshotとして扱い、previewをUI thread外で組み立てます。準備中はprogressを表示し、選択変更、画面を閉じる操作、ほかの音声処理をblockしません。
- open TODO全体を別に書き出せます。
- UIではclipboardまたはfile、Shortcutsではclipboard、返却file、指定folderへの上書き保存を利用できます。

## 5. 画面と設定

Koeのprimary colorはapp icon由来の爽やかなblueに固定し、利用者がcolor themeを切り替える設定は持ちません。録音、成功、警告は同じbrand paletteに合わせたsemantic colorを全画面で共有します。

表示言語は「システム設定」「English」「日本語」「简体中文」から選べ、選択は再起動後も保持します。「システム設定」はmacOSの優先言語から最初の対応言語を使い、対応言語がない場合は英語へfallbackします。繁体字中国語を簡体字中国語へ暗黙に置き換えません。変更はmenu bar、各windowの内容、onboarding、settings、HUD、dialog、noticeへ直ちに反映します。ライフログの認識言語で「表示言語に合わせる」を明示的に選んだ場合だけSTT hintへ使い、通常の音声入力、ボイスメモ、mode、prompt、保存済みtext、検索、書き出し内容、CLI/MCPの機械向けinterfaceは変更しません。

| 場所 | 公開機能 |
|---|---|
| Menu bar | ライフログ/音声入力の用途別quick action。ライフログは記録切替、今日の画面、mini window、音声入力は録音、mode、直前結果、履歴を各tab内にまとめ、共通footerは設定と終了だけを置く。「今日を開く」「ミニウィンドウ」はsystem fontを直接描画するcompact buttonとする |
| Main window | 通常起動時に前面のkey windowとして1680×960 ptで開き、3ペインを同時に表示する。ライフログの今日を選択してtimelineの最新位置を表示。onboarding、ライフログ、今日のtimeline最下部からの手入力・音声memo追加、音声入力履歴。記録操作はtoolbar右肩ではなくtimeline内の状態表示に置く |
| Mini window | ライフログ状態、今日のtimelineへの手入力・音声memo追加。一度開いたら明示的に閉じるまで、ほかのapp、desktop Space、full-screen Spaceより手前に表示し続ける。記録操作はwindow右肩ではなく状態表示に置く |
| 全TODO window | draft確認、編集、確定、完了、再開、削除 |
| Settings: 共通 | 一般（表示言語を含む）、利用状況、語彙、privacy、連携 |
| Settings: 音声入力 | hotkey、聞き取りengine・whisper.cpp model、feedback、履歴、AI整形、mode |
| Settings: ライフログ | 記録・mini window・ボイスメモhotkey、入力device、STT engine・認識言語・whisper.cpp model、audio保持、summary間隔、要約/TODO AI、calendar再取得 |

利用状況には音声入力回数・録音時間、ライフログの実発話時間、cloud AIの実測token数、Koe dataのstorage使用量を表示します。ライフログの実発話時間は、無音を含む連続録音時間ではなくtimelineに残る発話区間を日ごとに重複なく集計し、成功した音声入力と重なる発話は二重計上しません。local modelはcloud token集計に含みません。

Main window、mini window、menu barのライフログ状態表示は同じ記録操作を共有します。停止中の開始操作はblue/cyanの録音記号と「録音を開始」、記録開始意図がある間の停止操作はroseの停止記号と「録音を停止」を表示します。再接続中やボイスメモによる一時停止中も、停止操作は同じroseの外観を保ちます。

音声構成変更や処理失敗など、継続操作を妨げないmessageはdismiss可能なbannerとして表示し、右端の`×`で閉じられます。閉じる操作はmessageだけを消し、記録開始意図、自動再接続、保存済みdataには影響しません。

## 6. 保存、backup、削除

| Data | 保存先 | 既定保持 |
|---|---|---|
| 履歴、mode、語彙、ライフログ、TODO、利用量 | `~/Library/Application Support/Koe/koe.sqlite` | 履歴は無期限、各設定に従う |
| ライフログaudio | Application Support配下 | 文字起こし・派生処理の成功後に削除。7日または30日へ変更可能 |
| whisper.cpp model | `~/Library/Application Support/Koe/Models/WhisperCpp/` | 利用者が個別に削除、または全データ削除まで |
| 一般設定（表示言語を含む） | app UserDefaults | app data削除まで |
| API key | macOS Keychain | 個別削除まで |
| DB backup | `~/Library/Application Support/Koe/Backups/` | 最新7file |

- 既存DBは未適用migrationの直前にbackupします。通常起動でも同日重複なしで1日1回backupします。
- backupに失敗した場合はmigrationを開始しません。
- 「全データを削除」は履歴、mode、語彙、ライフログ、TODO、保存audio、download済みwhisper.cpp model、途中のdownload file、旧WhisperKit model、DB backupを削除します。設定とKeychainは画面で示す個別範囲に従います。
- 履歴から語彙候補へ複製済みの短い根拠は履歴とは別dataであり、履歴だけの削除では残る場合があります。

## 7. macOS Shortcuts / App Intents

Koeは下記のApp Intent ActionをShortcutsへ公開します。各ActionはKoeの起動とDB初期化完了を待ってから実行します。「ライフログを開始」はマイクを扱うためKoeをforegroundで起動し、それ以外はbackgroundで実行します。

| Action | Input / Output |
|---|---|
| ライフログを開始 | 冪等に開始。audio保存同意がなければerror |
| ライフログを終了 | 停止し、進行中の文字起こしと保存を待つ。summary/TODOは更新しない |
| ライフログを書き出してcopy | 任意日とinclude項目を受け、clipboardへcopy |
| ライフログをfileにする | 任意日、include項目、folder、`{{date}}`対応filename。folder指定時は同名をatomic上書き |
| 未実施TODOをすべてcopy | 確定済みopen TODOをclipboardへcopy |
| 未実施TODOをfileにする | `Koe-Open-TODO.md`を返す |

## 8. CLI

実行名はbuild productでは`koe-cli`、配布・link後の利用名は`koe`です。成功時は標準出力、失敗時はstderrへ`koe: ...`を出してexit status 1を返します。

```text
koe export day [--date YYYY-MM-DD] [--include calendar,speech,voice-input,memos,summary,todos] [--clipboard|--output PATH]
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
| `life_log_export` | `date?: YYYY-MM-DD`, `include?: [calendar,speech,voice-input,memos,summary,todos]` |
| `todo_export_open` | なし |
| `life_log_search` | `query: string`, `limit?: integer` |
| `todo_list` | `status?: open|draft|completed|all`。省略時open |
| `todo_add` | `title: string` |
| `todo_update` | `id: string`, `title?: string`, `status?: open|draft|completed` |
| `todo_delete` | `id: string` |
| `prompt_get` | `kind: summary|todo` |
| `prompt_set` | `kind: summary|todo`, `value: string` |

## 10. 障害時の外部挙動

- STTを確定できない場合は`failed`として理由を表示します。process再起動が必要なSpeechAnalyzer状態は利用者へ再起動を案内し、whisper.cpp modelの未download・破損・容量不足は設定画面で復旧方法を示します。
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
10. ライフログ記録中に成功した音声入力は一件だけ表示・検索・書き出しへ現れ、summary/TODOには使われない。cancelまたは失敗した音声入力の時間帯はライフログ発話が失われない。
11. 当日のsummaryは根拠のある会議、話題、決定、検討の流れ、次の行動をMarkdownの日報として表示し、未来の予定を実施済みとして書かない。手動更新は選択日のsummaryとdraft TODOを同時に更新し、失敗時は既存値を保持する。
12. Calendar設定から予定を再取得すると、現在選択日のsnapshot、timeline、月間activityが更新される。
13. マイク切替などの音声構成変更後も、記録開始意図が残る限りライフログcaptureが自動再開する。
14. ボイスメモ一回につきmemoだけが一件作られ、通常の音声入力履歴とライフログutteranceには同じ内容が追加されない。
15. 通常起動時にmain windowのライフログ画面が前面のkey windowとして開き、memo入力欄の音声ボタンは専用hotkeyと同じボイスメモを開始・停止する。
16. 「処理後削除」でも未処理・失敗chunkは残り、文字起こしと派生処理が成功したaudioだけが削除される。
17. 通常起動時、main windowでライフログを開いた時、mini windowを開いた時は、今日のtimelineの最新項目が表示される。
18. Timelineはheaderなしの一列で予定・発話・音声入力・memoを時刻順に表示する。日付選択時に予定一覧とtimelineが更新され、検索は`Command-F`でも開く。TODO本文は複数行へ折り返され、出典移動UIは表示しないがprovenance dataは保持する。
19. Mini windowはtitle barなしの一列timelineで予定と記録を時刻順に表示し、進行中の予定を上部へ固定する。明示的に閉じるまでSpace切替やfull-screen appの利用中も手前に残り、通常の文字入力ではtoggleされない。
20. Main window、mini window、menu barの記録状態は実際のaudio writerの稼働状態から同期され、同じ色、symbol、文言を使う。Main/mini windowでは開始・停止をmemo入力欄の直上に配置する。
21. 継続可能なmessageは`×`で閉じられ、dismissしても自動再接続や記録開始意図は変わらない。
22. 月間calendarは今日を塗り、表示中の日を枠線で示し、既存TODOと同じ作業を新しいDraft TODOとして再提案しない。
23. Summary/TODO派生は設定間隔の到来またはSummary viewの手動更新だけで実行し、録音停止を含むcapture状態変化では実行しない。確定済みTODOのIDと新しいDraftのIDは衝突しない。
24. App起動だけではライフログ記録を開始せず、前回processの記録開始意図を復元しない。
25. 音声入力・ボイスメモとライフログは、それぞれSpeechAnalyzerまたはdownload済みwhisper.cpp modelを選べる。音声入力でwhisper.cppを選ぶと停止後に録音全体を一括認識し、modelは両用途で共有する。Download・cancel・再試行・削除の状態と容量が設定に表示され、audioはMac外へ送信されない。
26. Life Logは起動直後に線形RMSの背景noise floorを校正し、その後も非発話中の入力から更新する。約-50 dBFSの絶対下限と直近のnoise floorに対する十分な上昇を短時間継続した場合だけ発話burstを開始し、微小noiseや持続する空調音では認識jobを作らない。Whisper.cppでは前のpreviewが完了している場合に限り、発話中に1.5秒cadence・直近5秒の暫定textを表示し、30秒未満の発話は1.5秒、30秒以上は1秒の無音でflushする。Burst確定時にaudioをcommitし、timestampは保存audio offsetに一致する。暫定textは永続化せず、語彙は録音session開始時のsnapshotで固定される。
27. 累積有声時間0.5秒未満または有声比率20%未満の候補はpreview、最終STT、burst checkpointを開始せず、保存audioの再処理でも除外する。Main/mini timelineは末尾表示中だけ新しい項目へ追従し、過去へscrollまたはsource移動した場合は追従を止め、末尾へ戻ると再開する。
28. whisper.cppの既知の定型hallucination「ご視聴ありがとうございました」は独立した文だけをengine境界で除外し、同じsegmentの実発話は保持する。
