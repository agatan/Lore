# Lore 外部仕様


本書はLoreの利用者と自動化クライアントから観測できる仕様をまとめた正本です。[HTML版](spec.html)も同じ公開面を扱います。内部構造は[design.md](design.md)、データの詳細は[PRIVACY.md](../PRIVACY.md)を参照してください。

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
| 表示言語 | システム設定、英語、日本語、簡体字中国語から選択可能。既定はシステム設定。変えると開いているwindowと日付の表記もその場で切り替わる |
| 保存 | Mac内のSQLite、UserDefaults、Keychain、ライフログaudio file |
| 同期 | 任意。利用者が選んだfolderへ、Mac内で暗号化した文字dataだけを置いて複数のMac間で共有する（6.1） |

対象外はmacOS以外、任意の音声fileの一括文字起こし、音声commandによるアプリ操作、通常の音声入力audioの保存、cloud STTです。

## 2. 初回起動と権限

- 初回はwindow全体を使うonboardingを表示し、ライフログ、音声入力、ボイスメモの三つの機能、マイク・アクセシビリティ・任意のcalendar権限とそれぞれの許可状況、保存範囲を説明します。
- 通常起動ではメニューバー常駐に加えてmain windowを開き、ライフログを選択した状態で表示します。
- アプリ名をKoeからLoreへ変えました。Lore（bundle ID `dev.agatan.Lore`）の初回起動時は、旧Koe（`dev.agatan.Koe`）のdataを一度だけ引き継ぎます。`~/Library/Application Support/Koe/`を`~/Library/Application Support/Lore/`へ移してDB fileを`lore.sqlite`へ改名し、保存audioの参照先も付け替えます。設定は旧Koeの値を写し、Lore側にすでに設定があれば写しません。Keychainに保存したAPI keyと同期の鍵は新しい保存先へ写してから旧itemを消します。Lore側のfolderがすでにある場合は混ぜずに旧folderを残し、menu barに残した場所を表示します。folderを移せない場合はDBを開かず、理由を表示します（旧dataはそのまま残ります）。macOSの権限（マイク、アクセシビリティ、入力監視、calendar）とログイン項目はbundle IDごとのため、Loreで改めて許可・設定します。CLIは`lore`、MCP serverは`lore-mcp`になり、AIクライアントへ登録し直します。CLI/MCPが先に起動した場合も、同じ手順でdataを移します。
- 前回processの記録開始意図は復元しません。ライフログ記録は起動後の明示的なUI、hotkey、Shortcuts操作か、利用者が有効にした自動記録の時間帯でだけ開始します（4.1）。
- マイク権限がなければ録音できません。アクセシビリティ権限がなければ結果を対象appへ挿入できません。Option+文字keyのhotkeyは入力監視権限がなければ開始しません。
- calendar権限は音声入力には不要です。設定の「一般」には各権限の状態を並べ、未許可の項目には「許可する」を置きます。まだ尋ねていない権限はシステムのダイアログを出し、一度拒否された権限はシステム設定の該当箇所を開きます。
- ライフログ開始時は、30秒単位の復旧用audioをMac内へ保存することを初回だけ確認します。同意前にShortcutsから開始した場合は、Loreを開いて同意するようエラーを返します。

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
- 暫定textは入力確認専用で、誤認識や語尾が更新されることがあります。DB、timeline、検索、書き出しへは保存せず、永続化済みaudioを使った最終認識だけを正本にします。
- whisper.cppが無音・環境音から生成する既知の定型文「ご視聴ありがとうございました」は、独立した文として認識された場合に限り表示・保存しません。同じsegmentに続く実発話は残します。
- 有効な発話を確定した時点で現在の復旧用audio chunkも原子的に確定し、参照範囲のaudioが永続化された後に最終認識を実行します。破棄した候補のためにはchunkを分割しません。発話timestampは録音開始時刻とaudio offsetから復元します。録音session開始時の語彙snapshotを完了まで固定し、保存audioの再処理でも同じ発話判定で無音区間を除き、最新の有効語彙を使います。
- whisper.cpp modelは音声入力とライフログで共通の選択です。どちらの設定画面からも一覧、download進捗と失敗理由を確認し、downloadをcancel、再試行、削除できます。Download完了前のmodelは認識に利用できず、ライフログの記録・処理中または音声入力の処理中は削除できません。
- 録音開始時の前面appからmodeを一度決め、そのsession内では固定します。手動固定は自動選択より優先します。
- modeは名前、対象bundle ID pattern、文章化の指示、言語、任意のmodel指定を持ち、作成、編集、削除、並べ替えができます。
- 共通ruleは全modeへ適用されます。同梱の共通ruleとmodeの指示は、表示言語や話す言語に関わらず英語で書き、整形結果は発話と同じ言語で返して翻訳しません。未編集の共通rule・Default modeは同梱内容の更新に追従し、編集済みの内容は変えません。
- 語彙は表記、任意の読み、誤認識pattern、有効/無効を持ち、STT hintと文章処理の指示へ反映します。

### 3.3 文章処理

文章処理は音声入力の整形だけに使います。ライフログのtextは文章処理へ渡しません。

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
- memo入力欄の音声ボタンは、開始準備中をprogress表示、録音中をapp iconの点と同じrose色とpulse animationで示し、通常の音声入力など別の音声処理中は新規開始できません。
- ライフログ記録中に開始した場合は、現在の復旧用audio chunkを確定してライフログcaptureを一時停止します。ボイスメモの完了、cancel、失敗後は、利用者の記録開始意図が残っている場合だけライフログを自動再開します。
- この排他境界により、一回のボイスメモはmemo一件だけを作り、通常の音声入力履歴やライフログutteranceへ同じ内容を追加しません。

## 4. ライフログ

### 4.1 記録

- ライフログは通常の音声入力と独立して開始・停止でき、同時利用できます。
- menu bar、main window、専用global hotkey、macOS Shortcutsから操作できます。
- app起動時は停止状態から始まり、前回終了時に記録中だったことを理由には開始しません。自動記録の時間帯の中で起動した場合だけ、自動記録として開始します。記録中のsleep復帰や入力device再接続は、同じprocessに残る記録開始意図に限って自動再開します。
- 設定の「自動記録」を有効にすると、選んだ曜日の開始時刻から終了時刻までライフログを自動で記録します。既定は無効、月〜金、9:00〜18:00です。終了時刻が開始時刻以前なら日付をまたぐ一つの時間帯として扱い、開始日の曜日に属します。
  - 時間帯に入った時、またはapp起動・sleep復帰・設定変更の時点で時間帯の中にいる場合は、記録していなければ開始します。
  - 時間帯を出た時は、自動記録が開始した記録だけを停止します。利用者がUI、hotkey、Shortcutsで開始した記録は自動では停止しません。
  - 時間帯の途中で利用者が停止した場合、その時間帯の残りでは再開せず、次の時間帯から自動記録を再開します。
  - 録音audio保存への初回同意がない場合は自動開始せず、一度手動で開始して同意するようbannerで案内します。マイク権限がない場合は手動開始と同じ失敗表示になり、自動で再試行しません。
  - 設定画面は次の自動開始・停止時刻を示します。自動記録中の状態表示は「自動記録中・18:00まで」のように終了時刻を、自動記録の待機中は「次の自動記録 9:00」のように次の開始時刻を示します。
  - 時刻判定はMacのcalendarとtime zoneに従い、時計やtime zoneの変更、sleep復帰で次の切替時刻を計算し直します。
- ライフログの全画面とmenu barは、実際のaudio writerの稼働状態を同じ記録状態として表示します。実際に録音している間もmenu barのLore icon本体はmonochromeで表示し、右下の小さなrose色badgeだけを着色します。開始準備中、停止中、再接続待ちではbadgeを外し、それぞれを録音中とは表示しません。
- 音声入力との同時利用中も、復旧可能なライフログaudioの記録は中断しません。音声入力が成功した区間はそのraw transcriptを正本とし、同じ録音時間帯にライフログ側で認識した発話はtimeline、検索、書き出しへ重複して出しません。音声入力がcancelまたは失敗した場合は、ライフログ側の発話を残します。
- 入力deviceを選択できます。記録中は30秒ごと、または発話burstの確定時に復旧用`.m4a`をMac内へ確定します。audioをcloud STTへ送ることはありません。
- audio chunkは耐久化・復旧の単位です。30秒に達する前でも発話確定時にchunkを閉じるため、最終認識は次の定期確定を待ちません。認識はadaptiveな発話burst単位で実行し、持続するnear-silenceを文字起こししません。
- Main windowとmini windowは有効な発話と判定した時点で、記録状態とは別のlive行を表示します。最初は「発話中」と入力audioの長さを示し、暫定認識が返るたびにrolling textを更新します。発話確定後は「文字起こし中」と処理経過時間へ切り替え、最終結果をtimelineへ保存したらlive行を消します。
- Main windowとmini windowのtimelineは初回表示時に最新項目を表示し、利用者が最新位置にいる間だけ、新しい発話・メモ・予定へ自動追従します。利用者が過去へscrollした場合や検索・予定から項目へ移動した場合は追従を止め、末尾へ戻ると再開します。
- ライフログの認識言語は「表示言語に合わせる」「自動判定」「日本語」「English」「简体中文」から選べ、既定は表示言語に合わせます。表示言語が「システム設定」の場合も解決後の対応言語を使います。この設定はライフログだけに適用し、通常の音声入力、ボイスメモ、modeには伝播しません。
- whisper.cppのcontrol tokenとtimestamp tokenはSTT engine境界で認識結果から除き、timeline、検索、書き出しへ新しく保存しません。過去に保存されたtextへ表示時の補正や自動書換えは行いません。
- whisper.cppの既定modelは量子化済みWhisper Large v3 Turbo Q5_0 (574 MB)です。非TurboのLarge v3 Q5_0も明示的に選べます。
- 保存済みaudioは文字起こしが成功し、発話をDBへ保存するまで必ず保持します。既定の「処理後削除」では成功直後にaudioだけを削除し、保存済みの発話は残します。設定は「処理後削除」「7日」「30日」から選べます。
- 7日または30日を選んだ場合も、未処理・失敗chunkは期間を超えて保持し、次回起動後の再処理に使います。保持期間を短く変更したときは、新しい条件を満たす処理済みaudioを削除します。
- 記録中の一時中断と、既定マイクの切替・接続解除などの音声構成変更では、現在のchunkを確定して自動再接続します。sleep時も安全に閉じ、記録意図が残ればwake後に再開します。マイク権限が失われた場合だけ自動再試行しません。
- app終了時は進行中の操作を割り込み、復旧用audioの確定と必要なDB保存だけを短時間待ちます。完了できなかった保存済みchunkは次回起動時に再処理します。

### 4.2 日別表示

- main windowは全高の半透明sidebarを持つsplit viewです。Sidebar上部の「ライフログ」「音声入力」で表示を切り替え、ライフログを既定表示にします。
- ライフログ表示中は三列です。Sidebarはnavigationの下に月間activity calendarを置きます。中央は選択日のtimelineで、読みやすい幅の列をwindow中央に置き、先頭に大きな日付と曜日、今日なら「今日」と記録状態、終日の予定を表示します。右のinspector「概要」は話した時間、発話・メモ・音声入力の件数と、予定のblockと記録の印を時刻の縦軸へ並べた一日の流れを表示します。予定blockや一日の流れの位置を選ぶと、timelineのその時刻へ移動します。今日なら現在時刻の線を引きます。Inspectorはtoolbarのbuttonで隠せ、表示状態は次回も保ちます。記録がない日は件数の代わりに記録がないことだけを示し、過去日で予定も記録もなければ一日の流れを出しません。記録がない日のtimelineは、縦線の位置に記録の始め方（今日）または記録がないこと（過去日）を一行で示します。検索と書き出しのbuttonもwindow toolbarに置きます。
- 通常起動時とmain windowのライフログを開いた時は今日を表示し、dataの読込後にtimeline最下部の最新項目へ一度だけscrollします。mini windowも開いた時に今日を表示して最下部へ一度だけscrollします。その後に新しい認識結果や予定が届いても利用者の閲覧位置を奪いません。
- timeline paneは時刻の予定、発話、音声入力、text memoを一列の時刻順で表示し、column headerは置きません。時刻の右に縦の線を通し、各行はその線上の印で種類を示します（発話は小さな点、メモと音声入力は記号、予定は輪）。予定の開始から終了までに入る区間は線を予定の色で塗り、予定の行は件名と長さ・calendar名を表示します。前の項目から1時間以上空いた所には空いた時間を示します。日付を選ぶとその日の予定を読み直し、inspectorとtimelineの両方へ反映します。
- toolbarの検索buttonまたは`Command-F`で横断検索を開きます。検索結果は種類をtimelineと同じ印と色で示し、一致した語を強調し、日付と時刻を添えます。入力欄から手を離さずに↑↓で結果を選び、Returnで開けます。検索結果の発話、音声入力、memoを選ぶと対象日を開いてその項目へ移動します。
- mini windowは予定、発話、音声入力、memoを一列の時刻順で表示し、今日進行中の予定をtimeline上部に固定します。OS標準のtitle barは表示せず、Space切替やfull-screen appの利用中も明示的に閉じるまで手前に残ります。Mini windowのtoggle hotkeyは、設定された修飾キーを含む押下と離上が対になった場合だけ切り替え、同じ文字keyだけの通常入力では開閉しません。
- Main windowとmini windowの最下部には、timelineの上に浮かぶ一本のcapsule barがあります。左端に記録の開始・停止buttonと記録状態、続いてchat形式のmemo入力欄、音声memo button、送信buttonを並べ、送信したmemoを今日のtimelineへ即時追加します。送信ボタンと音声入力ボタンは同じ直径の円形controlに揃えます。Timelineはbarの下までscrollでき、最後の行もbarに隠れません。過去日の履歴へ現在のmemoを混入させないため、main windowの入力欄は今日を選択中だけ表示し、過去日のbarは記録操作と状態だけを持ちます。
- ボイスメモも手入力と同じmemoとして今日のtimelineへ追加します。
- Loreのmemoは声や短い入力で素早く残す下書きです。本格的な清書や別のメモアプリ・タスク管理への転記は、MCPやCLIで読み出した外部AIが行います。Lore側は誤字直し程度の編集だけを提供します。
- Main windowとmini windowのmemoは、hover時の編集buttonまたは本文のdouble-clickでその場で編集できます。Returnで保存、Option-Returnで改行、Escで取り消します。空の本文は保存せず、memoの作成時刻は変わりません。削除はmain windowのhover時の削除buttonで行います。
- Main windowのtimelineは本文を読みやすい幅（約800 pt）に抑え、window幅を広げても行を伸ばしすぎません。
- ライフログの記録意図が続いている間、状態文言は実装内部の文字起こし開始・終了に追従して切り替えず、記録、開始準備、一時停止、再接続の利用者向け状態を安定して表示します。
- 発話と予定の関連は前後2分のずれを許容します。
- 日付をまたぐ記録は実時刻の日へ分配され、表示が今日を追従中なら新しい日へ切り替わります。

### 4.3 Calendar

- 選択したcalendarの予定を読み取り、時刻、件名、calendar名、終日、参加statusのsnapshotを保存します。
- 既定では参加済み、またはRSVPのない予定だけを表示・書き出しに含めます。このfilterは変更できます。
- Calendar設定の「予定を再取得」から、現在timelineで選択している日の予定を明示的に読み直せます。処理中は連打できず、完了後にtimelineと月間activityを更新します。
- LoreからRSVPを変更せず、Calendar appへの操作導線も提供しません。
- 月間activity calendarではtimelineで表示中の日をprimary colorの円で塗り、それ以外の今日はprimary colorの数字で示します。

### 4.4 AIへの受け渡し

Loreはライフログから要約、話題、TODOを生成しません。振り返りや作業の整理は、利用者が選んだ汎用AIへCLIまたはMCPで日別の記録を渡して行います。ライフログの発話、memo、予定はLoreからLLMやcloudへ送信しません。

### 4.5 検索と書き出し

連続する発話は90秒未満の間隔で途中に別の表示項目がなければ時刻範囲付きの段落へまとめます。プレビューは先頭4,000文字、書き出しは全文です。Day領域は縦スクロールでき、タイムラインの予定は塗りを使わず細い線と文字の強弱で区別します。

- ライフログ発話、通常の音声入力、memoを日本語部分一致で横断検索します。
- 日別書き出しはcalendar、ライフログ発話、通常の音声入力、memoを個別選択できます。ボイスメモは手入力と同じmemoに含めます。
- 書き出しは日付を見出しにした人間向けMarkdownで、予定、発話、音声入力、memoを読みやすい時系列の箇条書きで表します。機械用の英大文字tagやraw metadataは出力しません。
- 書き出し画面は開いた時点のdataをsnapshotとして扱い、previewをUI thread外で組み立てます。準備中はprogressを表示し、選択変更、画面を閉じる操作、ほかの音声処理をblockしません。
- UIではclipboardまたはfile、CLIでは標準出力、clipboard、fileを利用できます。

## 5. 画面と設定

Loreの配色はapp iconと同じ墨・白・roseの3色に固定し、利用者がcolor themeを切り替える設定は持ちません。主操作は墨色（dark modeでは白に近い色）、sidebarの選択やswitchなど広い面は墨より明るい灰色、roseは録音中・今日・現在時刻など「いま」を示す所だけ、予定は色を持たない灰色で示します。成功、警告、失敗だけが別の色を持ち、全画面で同じ意味に使います。Main windowと設定のsidebarでは、機能ごとの落ち着いた色（ライフログは藍、音声入力は青、一般は灰、同期・連携は青緑）の角丸tileに記号を載せます。

表示言語は「システム設定」「English」「日本語」「简体中文」から選べ、選択は再起動後も保持します。「システム設定」はmacOSの優先言語から最初の対応言語を使い、対応言語がない場合は英語へfallbackします。繁体字中国語を簡体字中国語へ暗黙に置き換えません。変更はmenu bar、各windowの内容、onboarding、settings、HUD、dialog、noticeへ直ちに反映します。ライフログの認識言語で「表示言語に合わせる」を明示的に選んだ場合だけSTT hintへ使い、通常の音声入力、ボイスメモ、mode、prompt、保存済みtext、検索、書き出し内容、CLI/MCPの機械向けinterfaceは変更しません。

| 場所 | 公開機能 |
|---|---|
| Menu bar | ライフログ/音声入力の用途別quick action。ライフログは記録切替、今日の画面、mini window、音声入力は録音、mode、直前結果、履歴を各tab内にまとめ、共通footerは設定と終了だけを置く。「今日を開く」「ミニウィンドウ」はsystem fontを直接描画するcompact buttonとする |
| Main window | 通常起動時に前面のkey windowとして1680×960 ptで開き、全高のsidebar（navigation、calendar）、中央のtimeline、右のinspector「概要」の三列を表示する。ライフログの今日を選択してtimelineの最新位置を表示。onboarding、ライフログ、最下部の浮いたbarからの手入力・音声memo追加と記録操作、音声入力履歴（一覧と詳細）。inspectorの表示切替・検索・書き出しはwindow toolbarに置く。音声入力履歴の詳細は中央の読みやすい幅に置く |
| Mini window | ライフログ状態、今日のtimelineへの手入力・音声memo追加。一度開いたら明示的に閉じるまで、ほかのapp、desktop Space、full-screen Spaceより手前に表示し続ける。記録操作は最下部の浮いたbarに置く。窓全体を半透明の素材で描く |
| Settings: 共通 | 一般（表示言語を含む）、語彙、privacy（保存場所、このMacの使用量、削除）、同期、連携 |
| Settings: 音声入力 | hotkey、文字起こしengine・whisper.cpp model、feedback、履歴、AI整形、mode |
| Settings: ライフログ | 記録・mini window・ボイスメモhotkey、自動記録の曜日と時間帯、入力device、STT engine・認識言語・whisper.cpp model、audio保持、calendar再取得 |

Privacy設定には、履歴、ライフログ、保存audio、whisper.cpp modelを含むLore dataのこのMac上の合計使用量を表示します。

Main window、mini window、menu barのライフログ状態表示は同じ記録操作を共有します。停止中の開始操作は墨色の丸にroseの点を置いた録音記号と「録音を開始」、記録開始意図がある間の停止操作はroseの停止記号と「録音を停止」を表示します。再接続中やボイスメモによる一時停止中も、停止操作は同じroseの外観を保ちます。

音声構成変更や処理失敗など、継続操作を妨げないmessageはdismiss可能なbannerとして表示し、右端の`×`で閉じられます。閉じる操作はmessageだけを消し、記録開始意図、自動再接続、保存済みdataには影響しません。

## 6. 保存、backup、削除

| Data | 保存先 | 既定保持 |
|---|---|---|
| 履歴、mode、語彙、ライフログ | `~/Library/Application Support/Lore/lore.sqlite` | 履歴は無期限、各設定に従う |
| ライフログaudio | Application Support配下 | 文字起こしの成功後に削除。7日または30日へ変更可能 |
| whisper.cpp model | `~/Library/Application Support/Lore/Models/WhisperCpp/` | 利用者が個別に削除、または全データ削除まで |
| 一般設定（表示言語を含む） | app UserDefaults | app data削除まで |
| API key | macOS Keychain | 個別削除まで |
| 同期の鍵 | macOS Keychain（このMacだけ。iCloud Keychainへは同期しない） | 同期の解除または全データ削除まで |
| 同期の変更file | 利用者が選んだfolderの`Lore Sync/` | Loreは削除しない。利用者がfolderごと管理する |
| DB backup | `~/Library/Application Support/Lore/Backups/` | 最新7file |

- 既存DBは未適用migrationの直前にbackupします。通常起動でも同日重複なしで1日1回backupします。
- backupに失敗した場合はmigrationを開始しません。
- 「全データを削除」は履歴、mode、語彙、ライフログ、保存audio、download済みwhisper.cpp model、途中のdownload file、旧WhisperKit model、DB backupを削除します。設定とKeychainは画面で示す個別範囲に従います。
- TODO、日次要約、話題、cloud AIのtoken集計を保存していた旧版DBは、更新時のmigration直前backupを作ってからそれらのtableを削除します。発話、memo、予定、音声入力履歴は変更しません。旧版でライフログ用に登録したAPI keyは読み出さず、「全データを削除」でKeychainから消します。

### 6.1 Mac間の同期

- 設定の「同期」から、複数のMacで同じ文字dataを使えます。既定は無効です。
- 同期するのは、ライフログの発話text、memo（追加・編集・削除）、音声入力履歴（生text、整形結果、status、mode snapshot、対象app名・bundle ID、provider/model、error、時間）、語彙です。
- 録音audio、API key、設定、予定の控え（各Macが自分のcalendarから読む）、whisper.cpp model、DB backup、modeは同期しません。他のMacから届いた発話は保存audioを持たず、予定との関連付けも持ちません。
- Loreは利用者が選んだfolder（iCloud Drive、Dropbox、Syncthingなど）の中の`Lore Sync/`へ、暗号化した変更fileだけを書きます。Lore自身はnetwork通信をせず、fileの運搬はfolderの提供元に任せます。
- 暗号化はMac内でAES-GCM（256-bit鍵）を使って行います。鍵は最初のMacで生成して「同期コード」として表示し、ほかのMacではそのコードを入力して参加します。鍵は各MacのKeychainだけに保存し、folderの提供元は中身を読めません。同期コードは参加済みのMacの設定から確認操作のあと再表示できます。参加済みのMacをすべて失い同期コードも控えていない場合、folderの内容は誰も読めません。
- 違う同期コードはfolder内の確認fileで検出し、参加を拒否します。読めない、改ざんされた、途中までしか届いていない、新しい形式の変更fileは取り込まず、理由を設定画面とlogに出して次回の同期で再試行します。そのfileより後の同じMacの変更も、順序を保つため取り込みを待ちます。
- 変更は数秒後にまとめて書き出します。取り込みは起動時、Loreが前面に来た時、2分ごと、「今すぐ同期」で行います。iCloud Driveでまだ手元に無いfileはdownloadを要求し、届いた後の同期で取り込みます。
- 同じ項目を複数のMacで変更した場合は、変更時刻が新しい方を採用します。削除も時刻付きで記録し、それより古い変更で復活しません。
- 利用者が個別に行った削除（memo、音声入力履歴1件、語彙）はほかのMacにも反映します。履歴とaudioの保持期間による自動削除、「音声入力履歴をすべて削除」「ライフログを削除」「Loreを初期化」は、このMacのdataだけを消します。
- 同期を有効にした時点でこのMacにある対象dataはすべて書き出します。
- 「同期を解除」と「Loreを初期化」は、このMacの同期鍵と同期状態を消し、変更の書き出しと取り込みを止めます。folder内のfileは削除しません。

## 7. macOS Shortcuts / App Intents

Loreは下記のApp Intent ActionをShortcutsへ公開します。各ActionはLoreの起動とDB初期化完了を待ってから実行します。「ライフログを開始」はマイクを扱うためLoreをforegroundで起動し、「ライフログを終了」はbackgroundで実行します。

| Action | Input / Output |
|---|---|
| ライフログを開始 | 冪等に開始。audio保存同意がなければerror |
| ライフログを終了 | 停止し、進行中の文字起こしと保存を待つ |

日別の書き出しはCLIまたはMCPから行います。

## 8. CLI

実行名はbuild productでは`lore-cli`、配布・link後の利用名は`lore`です。成功時は標準出力、失敗時はstderrへ`lore: ...`を出してexit status 1を返します。

```text
lore export day [--date YYYY-MM-DD] [--include calendar,speech,voice-input,memos] [--clipboard|--output PATH]
lore search "検索語" [--limit N]
lore days [--from YYYY-MM-DD] [--to YYYY-MM-DD]
lore range --from YYYY-MM-DD [--to YYYY-MM-DD] [--include calendar,speech,voice-input,memos]
```

`--clipboard`と`--output`は同時指定できません。`--output .`は既定filenameを現在directoryへ書きます。検索結果はtab区切りです。`days`と`range`はMCPの`life_log_days`、`life_log_range`と同じJSONを出します。CLIは読み取り専用です。

## 9. MCP

`lore-mcp`は1行1JSONのstdio JSON-RPC serverです。MCP protocol versionは`2025-03-26`、server versionは`1.0.0`です。notificationには応答しません。tool errorはJSON-RPC成功response内の`isError: true`とtextで返します。

| Tool | Arguments | 結果 |
|---|---|---|
| `life_log_days` | `from?: YYYY-MM-DD`, `to?: YYYY-MM-DD`。省略時は今日までの30日間。最大366日 | 記録がある日だけの配列。`day`、`utterances`、`dictations`、`memos`、`events`の件数と、timelineに残る発話の秒数`spokenSeconds` |
| `life_log_range` | `from: YYYY-MM-DD`, `to?: YYYY-MM-DD`（両端を含む。省略時は`from`の1日だけ。最大31日）, `include?: [calendar,speech,voice-input,memos]`（省略時はすべて） | 時刻順の項目配列。各項目は`id`、`kind`（`event`、`utterance`、`dictation`、`memo`）、`day`、`start`、任意の`end`、`text`。予定は`title`、`calendar`、`allDay`も持つ |
| `life_log_export` | `date?: YYYY-MM-DD`, `include?: [calendar,speech,voice-input,memos]` | 人間向けMarkdown |
| `life_log_search` | `query: string`, `limit?: integer` | `day`、`kind`、本文のtab区切り行 |

- 時刻はISO8601のlocal時差付き文字列です。予定はライフログ設定の参加中filterに従い、成功した音声入力と重なるライフログ発話は画面・書き出しと同じく除きます。
- MCPは読み取り専用です。Loreへの書き戻しは提供せず、読み出した発話やmemoを別のアプリへ清書・転記するのはMCP client側のAIの役割です。serverはMac内のDBを読むだけで、外部へ通信しません。

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
9. ライフログの実録音中だけmenu barのmonochrome Lore icon右下にrose色badgeが表示され、停止または再接続待ちではbadgeなしへ戻る。
10. ライフログ記録中に成功した音声入力は一件だけ表示・検索・書き出しへ現れる。cancelまたは失敗した音声入力の時間帯はライフログ発話が失われない。
11. ライフログの発話、memo、予定はLoreからLLMやcloudへ送信されず、要約・話題・TODOは生成されない。
12. Calendar設定から予定を再取得すると、現在選択日のsnapshot、timeline、月間activityが更新される。
13. マイク切替などの音声構成変更後も、記録開始意図が残る限りライフログcaptureが自動再開する。
14. ボイスメモ一回につきmemoだけが一件作られ、通常の音声入力履歴とライフログutteranceには同じ内容が追加されない。
15. 通常起動時にmain windowのライフログ画面が前面のkey windowとして開き、memo入力欄の音声ボタンは専用hotkeyと同じボイスメモを開始・停止する。
16. 「処理後削除」でも未処理・失敗chunkは残り、文字起こしが成功したaudioだけが削除される。
17. 通常起動時、main windowでライフログを開いた時、mini windowを開いた時は、今日のtimelineの最新項目が表示される。
18. Timelineはheaderなしの一列で予定・発話・音声入力・memoを時刻順に表示する。日付選択時に予定一覧とtimelineが更新され、検索は`Command-F`でも開く。
19. Mini windowはtitle barなしの一列timelineで予定と記録を時刻順に表示し、進行中の予定を上部へ固定する。明示的に閉じるまでSpace切替やfull-screen appの利用中も手前に残り、通常の文字入力ではtoggleされない。
20. Main window、mini window、menu barの記録状態は実際のaudio writerの稼働状態から同期され、同じ色、symbol、文言を使う。Main/mini windowでは開始・停止をmemo入力欄と同じ浮いたbarの左端に配置する。
21. 継続可能なmessageは`×`で閉じられ、dismissしても自動再接続や記録開始意図は変わらない。
22. 月間calendarは表示中の日をprimary colorの円で塗り、それ以外の今日をprimary colorの数字で示す。
23. TODO・要約・token集計を持つ旧版DBを開くと、migration直前backupを残してそれらを削除し、発話、memo、検索は引き続き使える。
24. App起動時に前回processの記録開始意図を復元しない。自動記録が有効なら、時間帯の中での起動・復帰・時間帯の開始で記録を始め、時間帯の終了では自動記録が始めた記録だけを止める。時間帯の途中で手動停止した場合は次の時間帯まで再開しない。
25. 音声入力・ボイスメモとライフログは、それぞれSpeechAnalyzerまたはdownload済みwhisper.cpp modelを選べる。音声入力でwhisper.cppを選ぶと停止後に録音全体を一括認識し、modelは両用途で共有する。Download・cancel・再試行・削除の状態と容量が設定に表示され、audioはMac外へ送信されない。
26. Life Logは起動直後に線形RMSの背景noise floorを校正し、その後も非発話中の入力から更新する。約-50 dBFSの絶対下限と直近のnoise floorに対する十分な上昇を短時間継続した場合だけ発話burstを開始し、微小noiseや持続する空調音では認識jobを作らない。Whisper.cppでは前のpreviewが完了している場合に限り、発話中に1.5秒cadence・直近5秒の暫定textを表示し、30秒未満の発話は1.5秒、30秒以上は1秒の無音でflushする。Burst確定時にaudioをcommitし、timestampは保存audio offsetに一致する。暫定textは永続化せず、語彙は録音session開始時のsnapshotで固定される。
27. 累積有声時間0.5秒未満または有声比率20%未満の候補はpreview、最終STT、burst checkpointを開始せず、保存audioの再処理でも除外する。Main/mini timelineは末尾表示中だけ新しい項目へ追従し、過去へscrollまたはsource移動した場合は追従を止め、末尾へ戻ると再開する。
28. whisper.cppの既知の定型hallucination「ご視聴ありがとうございました」は独立した文だけをengine境界で除外し、同じsegmentの実発話は保持する。
29. 同期を有効にした2台のMacは、folderに暗号化した変更fileだけを置いて発話text、memo、音声入力履歴、語彙を共有する。違う同期コードは拒否され、読めない変更fileは取り込まずに理由を表示し、後で届けば取り込む。個別削除は他のMacへ反映し、保持期間による削除と一括削除は反映しない。
