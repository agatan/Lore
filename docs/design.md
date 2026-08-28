# Koe 設計文書

本書は [spec.md](spec.md) の要件を実現する現在の設計を示します。利用者データの境界は [PRIVACY.md](../PRIVACY.md) にまとめています。

## 1. 中心となるドメイン

Koe の中心概念は「口述セッション」です。録音、認識、永続化、整形、挿入を一つの状態遷移として扱います。

重要な不変条件は次のとおりです。

1. STT が確定するまで、永続化可能な `SessionRecord` は作らない。
2. STT 確定後は、整形より先に生の文字起こしを保存する。
3. 整形失敗時は生の文字起こしを使う。
4. 挿入失敗時は結果をクリップボードへ残す。
5. 録音開始時の対象アプリ、モード、指示、エンジンをスナップショットし、途中の設定変更で意味を変えない。

これらは `SessionDraft` と `SessionRecord` の境界に置き、UIや永続化アダプタの都合で迂回できないようにします。

## 2. モジュール構成

```text
Koe.app
├── Domain
│   ├── SessionDraft / SessionRecord       セッション状態と監査記録
│   ├── Mode / ModeResolver                アプリごとの整形ルール
│   ├── SharedRules / Vocabulary           共通指示と語彙
│   └── FormattingPolicy                   プロンプト構築と出力検証
├── Engines
│   ├── SpeechAnalyzerStt                  オンデバイス音声認識
│   ├── FoundationModelsLlm                既定のオンデバイス整形
│   ├── GroqLlm                            利用者が選んだ場合の外部整形
│   └── EngineRegistry                     エンジン選択と準備
├── System
│   ├── AudioCapture / AudioDevices        録音と入力デバイス
│   ├── HotkeyMonitor / HotkeyBinding      グローバル操作
│   ├── TextInserter                       ペーストによる挿入
│   ├── FrontmostAppObserver               対象アプリの確定
│   ├── SecretStore                        Groq API キーの Keychain 保存
│   └── Permissions / LoginItem            macOS 権限と常駐設定
├── Persistence
│   └── KoeDatabase と各 Store             GRDB / SQLite
├── Analysis
│   └── VocabularySuggestionJob            オンデバイス語彙分析
├── App
│   ├── DictationCoordinator               セッション状態機械の駆動
│   ├── AppEnvironment                     UI 状態とユースケース境界
│   └── AppSettings                        UserDefaults 設定
└── UI
    └── メニューバー、HUD、設定、履歴
```

依存の中心は Domain です。OS API、ネットワーク、DB、UI は外側のアダプタとして扱います。

## 3. セッション状態

```text
idle
  └─ start → recording
                ├─ cancel → cancelled
                └─ stop → recognizing
                              ├─ STT failure → failed
                              └─ transcript finalized
                                   ↓ SessionRecord(status: interrupted) を保存
                                formatting
                                  ├─ success → inserting
                                  └─ failure → raw transcript → inserting
                                                   ├─ success → completed / fallback
                                                   └─ failure → clipboard_only
```

`interrupted` は終端状態ではありません。生の文字起こしは保存できたものの、その後の処理が完了しなかったことを表し、クラッシュやプロセス終了後の回収根拠になります。

キャンセル時に確定結果がない場合は、録音中の暫定テキストを使って履歴を残します。何も認識していない場合だけ記録を作りません。

## 4. 変動点の置き場所

### 4.1 モード

用途やアプリによる違いは `Mode` に閉じ込めます。モードは bundle ID のパターン、整形指示、言語設定、任意のモデル指定を持ちます。手動固定、完全一致、ワイルドカード、フォールバックの優先順位は `ModeResolver` が一元的に決めます。

全用途に共通する指示は `SharedRules`、固有名詞や表記は `Vocabulary` に置きます。アプリ名を見てパイプライン内で分岐する実装は作りません。

### 4.2 整形バックエンド

文章整形の違いは `FormattingBackend` と `EngineRegistry` に閉じ込めます。

- `onDevice`: Apple Foundation Models。既定値。
- `groq`: Groq Chat Completions API。利用者が明示的に選択した場合だけ使用。

セッションは開始時のエンジンを最後まで使い、処理中の設定変更を反映しません。出力検証と生テキストへのフォールバックはエンジン共通です。

語彙分析は過去の履歴を読むため、整形バックエンドとは別の `analysisLlm` を使います。`analysisLlm` は常にオンデバイスであり、Groq 選択時も切り替わりません。

## 5. プライバシー境界

### 5.1 録音と音声認識

`AudioCapture` が扱う録音データは処理中のメモリにだけ存在します。ファイルやDBへ保存せず、外部APIへ送信しません。SpeechAnalyzer が必要とする音声アセットは macOS が管理します。

### 5.2 外部送信

アプリが直接通信する実装は `GroqLlm` に限定します。Groq 整形を選んだ場合、次をリクエストへ含めます。

- 今回の文字起こし
- 共通ルール
- 選択されたモードの指示
- 有効な語彙

録音音声、保存済みの過去履歴、前面アプリ名と bundle ID は含めません。モデル一覧取得と接続確認も `GroqLlm` が担います。

外部送信の有無は `FormattingBackend.sendsTranscriptOffDevice` を唯一の判定元とし、設定画面とプライバシー画面はこの値から表示を決めます。

### 5.3 API キー

`SecretStore` が macOS Keychain の generic password として保存します。値は `AppSettings`、履歴DB、ログ、UI状態へ複製しません。読み出しはプロセス内でキャッシュし、保存・削除時に同じ入口から更新します。

## 6. プロンプトと出力検証

`FormattingPolicy` は次の順で指示を組み立てます。

```text
共通ルール
モード固有の指示
語彙
今回の文字起こし
```

整形は入力への応答ではなく変換です。次の場合は結果を採用せず、生の文字起こしへフォールバックします。

- 空の出力
- 入力に対して極端に短い、または長い出力
- コードフェンスやプロンプト例など、指示漏洩の兆候
- タイムアウトまたはエンジンエラー

## 7. 永続化と監査

`KoeDatabase` は GRDB の `DatabaseQueue` を使い、起動時に名前付きマイグレーションを適用します。

### 7.1 セッション

履歴は次を保存します。

- セッションID、開始・終了日時、状態
- 対象アプリ名と bundle ID
- モードIDと、モード・最終プロンプトのスナップショット
- STT / LLM のエンジンとモデル
- 生の文字起こしと整形結果
- エラー、音声長、各段の処理時間

全文検索は FTS5 の trigram tokenizer を使い、日本語の部分一致を扱います。挿入結果だけでなく生の文字起こしも検索対象です。

### 7.2 モード、共通ルール、語彙

ビルトインの初期値と利用者の編集を区別し、同梱内容の更新で利用者の変更を上書きしません。語彙候補は候補本体と根拠を保存し、承認時に語彙へ昇格します。

履歴と語彙候補は別に保存します。履歴を削除しても、候補に複製済みの短い根拠抜粋は残ります。この差をUIとプライバシー文書で明示します。

## 8. 運用上の例外

次は通常の運用状態として扱います。

- 音声アセットが未取得、予約不能、またはプロセス内で回復不能
- マイク・アクセシビリティ権限が未付与
- 整形エンジンが利用不可、タイムアウト、異常出力
- 挿入対象が消えた、またはセキュア入力中
- DBの初期化・保存・検索失敗
- 一部の語彙分析バッチだけが失敗
- 古い設定に現在は存在しない enum 値が残っている

失敗は状態、履歴、ログ、またはUIへ理由を出します。語彙分析の部分失敗は成功として丸めず、透かしを進めないことで次回に再試行します。未知の設定値は該当項目だけ既定値へ戻し、他の設定を巻き込みません。

## 9. 可観測性

ログは `KoeLog` のカテゴリへ集約します。発話内容、整形結果、語彙、APIキーはログに出しません。診断に必要な状態、件数、時間、エンジン名、失敗理由だけを記録します。

履歴は利用者向けの監査記録でもあります。設定を変更した後も、過去の結果がどの入力、モード、指示、エンジンから作られたかを再構成できます。

## 10. 現在の設計判断

| 判断 | 理由 |
|---|---|
| macOS 26 / Apple Silicon 専用 | SpeechAnalyzer と Foundation Models を直接利用し、互換層を持たない |
| STT は SpeechAnalyzer に固定 | ダウンロード型モデルの依存・初期化・障害面を持ち込まない |
| 整形はオンデバイスを既定にする | 外部送信なしで使い始められる強い既定を保つ |
| Groq は明示選択時だけ使う | オンデバイス品質を補う選択肢と送信境界を明確に分離する |
| 語彙分析は常にオンデバイス | 過去履歴の黙示的な外部送信を構造的に防ぐ |
| 整形前に生テキストを保存する | 後段の失敗で発話を失わない |
| 挿入はペースト方式 | 日本語IMEを経由したキー入力より互換性が高い |
| 語彙は提案後に人が承認する | 確率的な分析結果を自動でドメイン設定へ混入させない |
| 履歴にプロンプトを保存する | 結果の説明可能性と再現性を保つ |

## 11. 依存関係

外部Swift Packageは GRDB.swift のみです。ライセンスは [THIRD_PARTY_NOTICES](../THIRD_PARTY_NOTICES) に記載し、アプリのResourcesにも同梱します。
