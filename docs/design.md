# Koe 設計文書

> [docs/spec.md](spec.md) の要件を実現するアーキテクチャ設計。AI エージェント向けの正本。
> 人間向け圧縮版は [docs/overview/index.html](overview/index.html)。

- ステータス: Draft v1（spec.md Draft v1 に対応）

---

## 1. 設計の中心的な考え方

1. **ドメイン = 「口述セッション」のライフサイクル**。録音 → 認識 → 整形 → 挿入という状態遷移を `DictationSession` として明示的にモデル化し、失敗・キャンセル・フォールバックを正規の遷移として扱う。UI やシステム連携はこの状態機械の観測者に徹する。
2. **変動点は 2 つのエンジン抽象（STT / LLM）とモード設定に閉じ込める**。エンジンの追加・差し替え、整形挙動の変更が、パイプライン本体に波及しない。
3. **「発話を失わない」不変条件を構造で保証する**。STT 確定 → 永続化 → 整形、の順序をパイプラインが強制する。整形・挿入のいかなる失敗も生テキストの喪失に繋がらない。
4. **再現性のための記録**。セッションには適用したモード・プロンプト・モデルをスナップショットで残す。設定をあとから変えても過去の説明可能性は壊れない。

## 2. モジュール構成

```
Koe.app
├── Domain            … 純粋なドメイン層。AppKit/AVFoundation 非依存
│   ├── DictationSession / SessionState   状態機械（§3）
│   ├── Mode / ModeResolver               モード定義とアプリ→モード解決
│   ├── Vocabulary                        語彙エントリと整形プロンプトへの注入
│   └── FormattingPolicy                  整形プロンプト組み立て・出力検証
├── Engines           … 差し替え可能な推論エンジン（§4）
│   ├── SttEngine (protocol)
│   │   ├── SpeechAnalyzerStt             macOS 26 標準・デフォルト
│   │   └── WhisperKitStt                 高精度系（large-v3-turbo, kotoba-whisper）
│   └── LlmEngine (protocol)
│       ├── MlxLlm                        アプリ内蔵・デフォルト（Qwen3-4B 4bit 等）
│       └── FoundationModelsLlm           macOS 標準・ゼロセットアップ
├── System            … macOS 統合アダプタ（§5）
│   ├── HotkeyMonitor                     CGEventTap。短押し/長押し判定
│   ├── AudioCapture                      AVAudioEngine。16kHz mono ストリーム
│   ├── FrontmostAppObserver              NSWorkspace。bundle ID 取得
│   ├── TextInserter                      ペーストボード退避→⌘V 送出→復元
│   └── ModelStore                        モデルのDL/削除/配置。唯一のネットワーク境界
├── Persistence       … GRDB (SQLite)（§7）
│   ├── HistoryStore / VocabularyStore / ModeStore / Settings
├── Analysis          … 語彙自動提案のバックグラウンドジョブ（§6）
└── UI                … SwiftUI + AppKit
    ├── MenuBarExtra / HUD (NSPanel) / SettingsWindow / HistoryWindow
```

依存方向: `UI → Domain ← Engines/System/Persistence`（Domain は protocol を定義し、外側が実装を注入）。

## 3. セッション状態機械

```
                 hotkey(start)
  idle ────────────────────────▶ recording ──Esc──▶ cancelled ✦
                                    │ hotkey(stop)
                                    ▼
                              finalizingStt ──error──▶ failed ✦
                                    │ 確定テキストを永続化 ★
                                    ▼
                                formatting ──error/timeout/検証NG──▶ fallbackInsert
                                    │                                    │
                                    ▼                                    ▼
                                 inserting ◀─────────────────────────────┘
                                    │ 成功                │ 挿入失敗
                                    ▼                     ▼
                                 completed ✦       clipboardOnly ✦（通知）
```

- ★ が「発話を失わない」の要。`finalizingStt` 完了時点で raw transcript を DB に書いてから `formatting` に進む。
- ✦ は終端。すべての終端で履歴レコードのステータスを確定する（completed / cancelled / failed / fallback / clipboardOnly）。
- `recording` 中はストリーミング STT が並行動作し、暫定テキストを HUD に流す。停止時は未確定 tail のみを `finalizingStt` で処理する。
- キャンセル時も確定済みテキストがあれば履歴に残す（spec FR-1.4）。
- 同時実行は 1 セッションのみ。録音中のホットキー再押下は停止として扱う。

### 3.1 セッション開始時に確定するコンテキスト

録音開始の瞬間に以下をスナップショットする（処理中にユーザーがアプリを切り替えても影響しない）:

- 挿入先: 前面アプリの bundle ID とアプリ名
- モード: `ModeResolver` が bundle ID から解決（手動固定があればそれを優先）
- 適用プロンプト: モードのプロンプト + 語彙注入を合成した最終文字列
- 使用エンジン・モデル名

## 4. エンジン抽象

### 4.1 SttEngine

```swift
protocol SttEngine {
    /// 録音ストリームを受け取り、暫定・確定テキストを流す。
    /// finish() 後に最終確定テキストを返して完了する。
    func transcribe(audio: AsyncStream<AudioChunk>, hints: SttHints) -> AsyncThrowingStream<SttEvent, Error>
}

enum SttEvent {
    case partial(text: String)                 // HUD 表示用の暫定
    case final(text: String, language: Language) // 確定（言語判定込み）
}

struct SttHints {
    let vocabularyPrompt: String?   // Whisper initial prompt 等へのバイアス（対応エンジンのみ）
    let languagePreference: LanguagePreference // .auto（デフォルト） / .fixed(ja|en)
}
```

- **SpeechAnalyzerStt（デフォルト）**: macOS 26 の `SpeechAnalyzer` + `SpeechTranscriber`。ストリーミングで volatile/final 結果が得られ、停止後レイテンシが最小。言語はロケール指定型のため、自動判定は §4.3 の方式で補う。
- **WhisperKitStt**: CoreML。日本語品質重視の選択肢（whisper-large-v3-turbo / kotoba-whisper）。言語自動判定を内蔵。`vocabularyPrompt` を initial prompt として使える。

### 4.2 LlmEngine

```swift
protocol LlmEngine {
    /// 1 回で渡せる入力(system + user)の目安。コンテキスト窓はエンジンごとに桁が違う。
    var inputCharacterBudget: Int { get }
    func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String
}
```

`FormattingPrompt` は期待する出力長（`expectedOutputCharacters`）を申告する。整形は「出力 ≒ 入力」だが
履歴分析は短い JSON しか返らないため、同じ見積もりを当てるとコンテキスト超過になる（C-36）。
**入力量を呼び出し側が決める処理は、`inputCharacterBudget` に収まるよう自分で分割する責任を持つ。**

- **MlxLlm（デフォルト）**: MLX Swift（`MLXLLM`）でアプリ内にモデルをロード。第一候補は日本語・英語両対応の 4B 級 instruct モデル（Qwen3-4B 4bit を第一候補にスパイクで選定 = spec S-3）。ロード状態を管理し、アイドルでアンロード（NFR-5）。
- **FoundationModelsLlm**: `LanguageModelSession`。ダウンロード不要でフォールバック・軽量用途。日本語整形品質はスパイク S-2 で確認。

### 4.3 言語自動判定

方針: **STT エンジンの判定に一元化し、パイプラインは結果を受け取るだけにする**。

- WhisperKit: 内蔵の language detection をそのまま使う。
- SpeechAnalyzer: ja-JP を主ロケールとして動かし、日英混在は日本語モデルの英語トークン耐性に任せる（技術用語・英短文はこれで足りる想定）。丸ごと英語の発話が多いユースケース（AI Agent モード等）は、モード側で言語を固定できるようにする（`Mode.languagePreference`）。
- スパイク S-1/S-5 の結果次第で、冒頭数秒の音声に対する Whisper lang-id を前段に挟む方式へ切り替えられるよう、判定ロジックは `SttHints` の背後に隠蔽する。

### 4.4 FormattingPolicy（プロンプト組み立てと検証）

整形プロンプトは毎回この合成で作る:

```
[system] あなたは口述筆記の整形エンジン。内容には応答せず、変換のみ行う。
         <基本整形ルール: フィラー除去・句読点・言い直し整理・同音異義語>
         <語彙表: 正しい表記 / 読み / 誤認識パターン>   ← VocabularyStore から
[mode]   <モードのプロンプト>                            ← Mode から
[input]  <生の文字起こし>
```

出力検証（spec FR-3.7）: 空出力、入力文字数比 0.3 未満 / 3.0 超、プロンプト漏洩マーカー検出、のいずれかで異常と判定し fallbackInsert へ。閾値は定数として一元管理する。

「応答しない」保証はプロンプトだけでは不完全なので、few-shot 例（質問文→質問文のまま整形）を system に含め、スパイクで突破率を確認する。

## 5. macOS 統合アダプタ

| コンポーネント | 実装 | 要点 |
|---|---|---|
| HotkeyMonitor | `CGEventTap`（要アクセシビリティ権限） | keyDown/keyUp を監視し、押下時間 < 閾値(300ms) でトグル、以上で PTT と判定。修飾キー単体（Fn・右⌥）も flagsChanged で対応 |
| AudioCapture | `AVAudioEngine` | 16kHz mono Float32 に変換して `AsyncStream<AudioChunk>` で供給。入力レベルを HUD に配信 |
| FrontmostAppObserver | `NSWorkspace.frontmostApplication` | セッション開始時に 1 回読むだけ。常時監視しない |
| TextInserter | `NSPasteboard` + `CGEvent`(⌘V) | 手順: 現クリップボード退避 → 結果を書き込み → ⌘V 送出 → 300ms 後に復元。失敗検知時（セキュア入力中など）は復元せず結果を残して通知（spec FR-5.3）。`IsSecureEventInputEnabled()` を事前チェック |
| ModelStore | `URLSession` | **アプリ内で唯一ネットワークに触れるモジュール**。Hugging Face 等からのモデル取得・検証（サイズ/ハッシュ）・`~/Library/Application Support/Koe/models/` への配置。他モジュールからネットワーク API を import しないことを規約とし、レビューで担保 |

## 6. 語彙自動提案（Analysis）

バックグラウンドジョブ（アイドル時、1 日 1 回程度 + 手動トリガ）:

1. 前回分析以降の履歴レコード（raw + formatted のペア）を取得。
2. エンジンの `inputCharacterBudget` に収まるバッチへ分割する（C-36）。1 回の実行に投げるバッチ数には上限を置き、
   溢れた履歴は透かしを進めないことで次回の実行へ引き継ぐ。
3. 各バッチについてローカル LLM に以下を抽出させる:
   - 頻出する固有名詞・専門用語（未登録のもの）
   - raw → formatted で繰り返し矯正されているパターン（誤認識候補）
   - 同一概念の表記ゆれ
4. バッチを跨いで候補をマージし、既存語彙・却下済み候補と突き合わせ、新規のみ `vocab_suggestions` に
   出現回数・出現例（evidence）付きで保存。根拠の数え直しは分析対象の全セッションを跨いで行う（バッチ境界は根拠に無関係）。
5. 設定画面の「語彙 > 提案」タブに表示。承認 → `vocabulary` へ昇格、却下 → `rejected` として記録し再提案を抑止。

設計上の割り切り: 提案の再現性は問わない（LLM 抽出は確率的で良い）。ただし**登録は必ず人間の承認を経る**ため、辞書自体の品質は決定的に保たれる。

## 7. データモデル（SQLite / GRDB）

```sql
-- 口述セッション（履歴 + 監査記録を兼ねる）
CREATE TABLE sessions (
  id                TEXT PRIMARY KEY,           -- UUID
  started_at        TEXT NOT NULL,              -- ISO8601
  ended_at          TEXT,
  status            TEXT NOT NULL,              -- completed|cancelled|failed|fallback|clipboard_only
  app_bundle_id     TEXT,
  app_name          TEXT,
  mode_id           TEXT,                       -- 参照用（モードは後から変更されうる）
  mode_snapshot     TEXT NOT NULL,              -- JSON: 適用時のモード名・最終プロンプト全文
  stt_engine        TEXT NOT NULL,              -- speech_analyzer|whisper_kit
  stt_model         TEXT,
  llm_engine        TEXT,                       -- mlx|foundation_models|none(整形スキップ)
  llm_model         TEXT,
  language          TEXT,                       -- ja|en|mixed
  raw_transcript    TEXT NOT NULL,              -- ★ finalizingStt 完了時に必ず書く
  formatted_text    TEXT,
  error             TEXT,
  audio_duration_ms INTEGER,
  stt_latency_ms    INTEGER,                    -- 停止→STT確定
  llm_latency_ms    INTEGER,                    -- 整形所要
  insert_latency_ms INTEGER                     -- 停止→挿入完了（体感指標）
);
CREATE VIRTUAL TABLE sessions_fts USING fts5(raw_transcript, formatted_text, content=sessions);

CREATE TABLE modes (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  bundle_ids    TEXT NOT NULL,   -- JSON array。空 = デフォルトモード
  prompt        TEXT NOT NULL,
  llm_model     TEXT,            -- NULL = グローバル設定に従う
  language_pref TEXT NOT NULL DEFAULT 'auto',  -- auto|ja|en
  sort_order    INTEGER NOT NULL,
  is_builtin    INTEGER NOT NULL DEFAULT 0,
  updated_at    TEXT NOT NULL
);

CREATE TABLE vocabulary (
  id              TEXT PRIMARY KEY,
  surface         TEXT NOT NULL,     -- 正しい表記
  reading         TEXT,
  misrecognitions TEXT,              -- JSON array
  note            TEXT,
  source          TEXT NOT NULL,     -- manual|suggested
  enabled         INTEGER NOT NULL DEFAULT 1,
  created_at      TEXT NOT NULL
);

CREATE TABLE vocab_suggestions (
  id           TEXT PRIMARY KEY,
  surface      TEXT NOT NULL,
  evidence     TEXT NOT NULL,        -- JSON: {count, examples:[{session_id, excerpt}], kind}
  status       TEXT NOT NULL,        -- pending|accepted|rejected
  created_at   TEXT NOT NULL,
  UNIQUE(surface)
);
```

- `mode_snapshot` に最終プロンプト全文を含めるのが再現性（NFR-4）の実装。ストレージは食うがテキストなので許容。
- 履歴削除（個別・全件・保持期間超過）は sessions と FTS を同時に消す。語彙提案の evidence 内 excerpt は独立コピーなので、履歴を消しても提案の根拠表示は壊れない（session_id リンクは切れる。許容する）。

## 8. 主要設計判断（ADR 要約）

| # | 判断 | 理由 / 却下した代替案 |
|---|---|---|
| D-1 | ~~完全ローカル専用。BYOK も無し~~ → **C-62 で部分的に撤回**（仕上げだけ BYOK を選べるようにした） | プライバシーが製品価値の核。クラウド分岐を残すと NFR-2 の検証可能性（ネットワーク境界の一元化）が壊れる |
| D-2 | Swift ネイティブ | ホットキー・アクセシビリティ・音声・MLX/FoundationModels すべて macOS API 直結。Rust+Tauri はブリッジが二重になるだけ |
| D-3 | macOS 26+ / Apple Silicon 専用 | SpeechAnalyzer と FoundationModels で「追加 DL なしで即使える」初期体験を作れる。自分専用ツールなので互換性負債を負わない |
| D-4 | 整形完了後の一括挿入 | 即挿入→置換は挿入先アプリ（Electron・ターミナル）との相性問題が既知。シンプルさ優先。レイテンシはストリーミング STT + 小型 LLM で吸収 |
| D-5 | ~~STT/LLM とも 2 エンジン構成~~ → **C-52 で撤回**（OS 内蔵モデル専用にした） | 「ゼロセットアップで動く」と「品質の天井を上げられる」の両立。protocol 境界が明確なら 2 実装のコストは低い |
| D-6 | 語彙矯正は LLM 整形段が主、STT バイアスは従 | STT レベルの語彙注入はエンジン依存が強く効果が不安定。LLM 段なら全エンジン共通に効く |
| D-7 | 挿入はペーストボード方式 | キーストローク合成（1 文字ずつ）は日本語で IME と衝突する。ペーストが最も互換性が高い。クリップボード汚染は退避→復元で緩和 |
| D-8 | 履歴は永続 + 検索、監査記録を兼ねる | 語彙自動提案の学習データ・レイテンシ観測・再現性の 3 つがここに乗る。単なる便利機能ではなく基盤 |
| D-9 | 語彙自動登録はしない（提案 + 人間承認） | 辞書は整形品質を直接左右する。LLM の確率的な抽出を無審査で反映すると劣化がサイレントに混入する |

## 9. マイルストーン

| M | 内容 | 完了条件 |
|---|---|---|
| M0 | スパイク S-1〜S-5（spec §7） | エンジン既定値（デフォルト STT/LLM モデル）の確定 |
| M1 | 歩くスケルトン | ホットキー(PTT のみ) → SpeechAnalyzer → FoundationModels 固定プロンプト整形 → ペースト挿入。メニューバー常駐。履歴 DB へ記録 |
| M2 | セッション状態機械の完成 | トグル/長押しハイブリッド、HUD（レベル・逐次表示・キャンセル）、フォールバック全経路、効果音 |
| M3 | モード | アプリ別自動切替、ビルトインモード、モード編集 UI、手動固定 |
| M4 | 語彙 + 履歴 UI | 手動語彙 CRUD と整形への注入、履歴ウィンドウ（検索・再コピー） |
| M5 | エンジン拡充 | WhisperKit / MLX バックエンド、モデル管理 UI（DL/削除/切替） |
| M6 | 語彙自動提案 | Analysis ジョブ、提案 UI、承認フロー |

M1 の時点で毎日自分で使い始め（ドッグフーディング）、以降の優先順位を実使用の不満で並べ替える。

## 10. リスクと備え

| リスク | 影響 | 備え |
|---|---|---|
| SpeechAnalyzer の日本語品質不足 | デフォルト体験が崩れる | S-1 で早期判定。WhisperKit デフォルト化に切替可能な構造（D-5） |
| 4B 級 LLM で整形品質が不足（特に同音異義語・文体変換） | 最重要機能の価値毀損 | S-2/S-3 でモデル比較。プロンプト側の few-shot 強化。最悪 8B 級 + アンロード戦略 |
| ⌘V 挿入が効かないアプリ | 主要シーン（ターミナル等）で使えない | S-4 で主要アプリ実測。AXUIElement 経由の挿入をフォールバックとして追加検討 |
| 整形 LLM が「応答」してしまう | 挿入テキストの信頼喪失 | few-shot + 出力検証（FR-3.7）。HUD で整形前後を確認できる履歴導線 |
| モデルロードでメモリ圧迫 | 常駐アプリとして失格 | アイドルアンロード + ロード状態のメニューバー表示（NFR-5） |

## 11. 実装で入れた設計変更（v1 実装時に判明した事情）

実装した結果、本書の当初案から変えた点。理由とともに残す。

| # | 変更 | 理由 |
|---|---|---|
| C-1 | セッションのステータスに `interrupted` を追加（§7 の状態一覧に対する追加） | ★ の「STT 確定を永続化したが最後まで進めていない」状態に名前が必要だった。クラッシュ後にこのステータスの行を見れば、回収すべき発話が特定できる（NFR-3 の可観測性） |
| C-2 | 「発話を失わない」順序を型で強制 | `SessionDraft.finalizeTranscript` を通るまで `SessionRecord` が存在しない構造にした。永続化・整形・挿入を STT 確定より先に呼ぶことが構造的に不可能になる |
| C-3 | `sessions_fts` の tokenize を `trigram` に | FTS5 の既定 unicode61 は日本語を分割しないため、部分一致検索が効かない。trigram で日本語の部分一致が成立する |
| C-4 | `SttEngine.prepare(hints:)` が希望する音声フォーマットを返す | AudioCapture 側で 1 回だけ変換すれば済み、エンジン内での二重リサンプリングを避けられる。SpeechAnalyzer は `bestAvailableAudioFormat`、WhisperKit は 16kHz mono を返す |
| C-5 | `FrontmostAppObserver` はアプリ活性化通知を購読する（当初は「開始時に 1 回読むだけ」） | 設定・履歴ウィンドウを開くと前面アプリが Koe 自身になり、挿入先を失う。直近の「Koe 以外の前面アプリ」を覚える必要があった。取得するのは bundle ID とアプリ名だけで、NFR-2 は維持 |
| C-6 | ~~WhisperKit の暫定表示は「一定間隔での再認識」で実現~~ → **C-34 で撤回** | Whisper はバッチ処理でストリーミング API を持たない。溜まった音声を 3 秒間隔で再認識して HUD に流す（重いときは自動的に間隔が空く）。停止後レイテンシの差は D-5 で受け入れたトレードオフのまま |
| C-7 | ~~MLX を使うビルドは `xcodebuild` 経由~~ → **C-52 で解消**（MLX 削除により `swift build` のみ） | mlx-swift の Metal シェーダは SwiftPM の CLI ビルドではコンパイルできない（上流の既知制約）。Metal ツールチェーン（`xcodebuild -downloadComponent MetalToolchain`）が入っていれば Makefile が自動で xcodebuild を使う。無い場合は MLX エンジンを `unavailable` として理由付きで表示し、呼び出す前に弾く（metallib 欠落のまま MLX を呼ぶとプロセスが落ちるため） |
| C-8 | 語彙提案は「LLM が候補を挙げ、根拠はコードが数え直す」 | LLM の出す出現回数・例は当てにならない。候補の surface だけを使い、出現回数と抜粋は履歴から機械的に数える。1 回も出てこない候補（幻覚）はここで落ちる |
| C-9 | ~~語彙の誤認識置換は LLM の前にコードで決定的に行う~~ → **C-43 で撤回** | Foundation Models での実測で、語彙表を最優先と書いても小型モデルは従わなかった（「レセ困」がそのまま出る）。文字列一致で確実に直せるものを確率的なモデルに任せる理由はない。LLM 段には「読みが同じで表記が違う」等の文脈判断だけを残す。整形が失敗しても語彙矯正だけは効いた状態で挿入される |
| C-10 | 整形プロンプトは入力を区切り、命令を入力の**後ろ**にも置く | 同じ実測で、長い入力を渡すと小型モデルが system の指示を忘れて「応答」しはじめた（工程を勝手に分解し、コードブロックで手順書を出力した）。命令を末尾に置き直すと解消した |
| C-11 | 出力検証を厳しくした: 入力比の上限を 3.0 → 2.0、コードフェンス（```）を漏洩マーカーに追加 | 上記の暴走出力は 3.0 以内に収まり検証を通過してしまった。発話にコードフェンスは含まれ得ないので、出現は構造を作り始めた兆候として扱う |
| C-12 | オーディオタップのブロックは **nonisolated な文脈で生成する**（`AudioCapture.makeTapBlock`） | `@MainActor` のメソッド内で作ったクロージャは MainActor 隔離を継承する。`installTap` のブロックはオーディオのリアルタイムスレッドから同期的に呼ばれるため、隔離チェック（`swift_task_isCurrentExecutor`）で即クラッシュした（実機で再現、逆アセンブルで前後を確認）。キャプチャは Sendable なものだけに限定する |
| C-13 | 署名 identity を固定できる構成にした（`make dev-cert`） | ad-hoc 署名は identity が cdhash 自身なので、リビルドごとに別アプリ扱いになりアクセシビリティの許可が毎回無効になる。固定の自己署名証明書で署名すれば designated requirement が安定し、許可が残る。同じ bundle ID のコピーが複数あると TCC が混乱するため、`make install` は build/ のコピーを消す |
| C-14 | ウィンドウを開いている間だけ activation policy を `.regular` にする | `LSUIElement` のアクセサリアプリは ⌘Tab の切替対象に入らないため、設定・履歴ウィンドウにフォーカスを戻せなかった。開閉に合わせて出し入れする（`WindowActivation`） |
| C-15 | SpeechAnalyzer を使う前に `AssetInventory.reserve(locale:)` を呼び、`status` が `.installed` であることを確認する | 予約前は `SpeechTranscriber.installedLocales` に ja-JP が入っていても `AssetInventory.status` は `.supported` のままで、その状態で `SpeechAnalyzer.start` を呼ぶと framework 内部（`prepareModulesIfNeeded` → `setWorkers`）で **trap してプロセスごと落ちる**（実機で 2 回再現）。予約と状態確認を通ったものだけを解析に渡し、未取得なら理由付きの通常の失敗にする。回帰は `SpeechAnalyzerSmokeTests` で検出する |
| C-15b | 「予約済み」をアプリ側でキャッシュせず、`status` を見る前に毎回 `reserve(locale:)` を呼ぶ。`unload()` では予約に触らない | `AssetInventory.status` が返すのは「インストール済みか」ではなく「**予約済み、かつ**インストール済みか」で、未予約ならアセットがディスクにあっても `.supported`（＝未取得）を返す。そして予約は**プロセスに紐づく**（別プロセスから見ると `reservedLocales` は空、実機で確認）ので、こちらが握っているつもりでも失われうる。予約済みを覚えていると失われたときに再予約を飛ばし、`readyTranscriber` が「音声モデル（日本語）が未取得です」で録音を弾き続ける（間欠的に再現）。予約済みの `reserve` は冪等で実測 0.2ms なので、毎回呼んで損はない。あわせて、`release(reservedLocale:)` は識別子が正規形（`ja_JP`）でないと**黙って false を返して何もしない**ため、`identifier(.bcp47)`（`ja-JP`）から作り直した `Locale` で解放してはいけない |
| C-15c | 「未取得」と言い切るのは `SpeechTranscriber.installedLocales` に無いときだけにする。予約が効いているかは `AssetInventory.reservedLocales` を見て判断し、**`reserve` の戻り値は使わない** | `.supported` は「ディスクに無い」と「予約が効いていない」の**両方が潰れた値**なので、そのまま「設定 > モデル から取得してください」に翻訳すると、取得済みのモデルに対してダウンロードを促してしまう。押しても直らないので利用者は自力で戻せない。`installedLocales` は予約と独立に答える（予約ゼロでも `ja_JP` を返す）ので、こちらを「取得済みか」の根拠にする。`reserve` の戻り値は「**新たに**予約したか」で、予約済みのときも在庫 API が死んでいて何も起きなかったときも等しく `false` を返すため、成否の判定には使えない |
| C-15d | 予約が取れないと分かったらアプリを起動し直す（`AppRelauncher`）。取得も再試行も促さない | `AssetInventory` は**プロセス内で一度死ぬと戻らない**。Speech の XPC サービス（`localspeechrecognition.xpc`）が落ちると、そのプロセスでは `reservedLocales` が空のまま `reserve` が何も起こさなくなり、`release` も `SpeechModels.endRetention()` も `assetInstallationRequest().downloadAndInstall()` も効かず、**ja 以外のロケールも一切予約できなくなる**（サービスを kill して 10 回サンプリング、いずれも `status=supported` / `reserved=[]`。同じ状態で新しいプロセスを起こすと即座に `installed`）。実機では 3 日 11 時間動き続けた Koe で発生し、設定画面の「取得」を押しても直らない。回復手段はプロセスの作り直ししかないので、`EngineError.needsAppRestart` として状態機械の外まで運び、アプリ側で起動し直す。起動から `AppRelauncher.minimumUptime`（5 分）以内の失敗では起動し直さない — 在庫 API が死ぬのは長寿命プロセスであり、この下限が再起動ループの唯一の歯止めになる |
| C-16 | `SpeechTranscriber` はセッションごとに作り直す（キャッシュしない） | 同じインスタンスを 2 つ目の `SpeechAnalyzer` に渡すと `setWorkers(for:reusingFrom:)` で trap し、**2 回目の録音で必ず落ちた**（実機で再現）。`results` も 1 回しか列挙できない。モデル自体は `modelRetention: .lingering` で温存されるので作り直しのコストは実用上問題にならない。回帰は連続 2 セッションを回すスモークテストで検出する |
| C-17 | 入力ノードを音量 0 の mainMixerNode に接続し、ステレオ→モノラルは `AVAudioConverter.downmix` を明示する | タップだけではグラフが駆動されない環境があり、また downmix 未指定だと片チャンネルしか拾わず無音になり得る（波形が動かない・認識できない症状につながる）。診断のため、セッションごとにチャンク数と入力ピークをログに出す（発話内容は出さない） |
| C-18 | 効果音は自前で合成する（`ToneSynth`） | システム標準音はどれも主張が強く、1 日に何十回も鳴らす用途に向かない。40〜160ms の正弦波に両端フェードを付けた WAV を生成し、既定音量も 0.35 → 0.18 に下げた |
| C-19 | HUD から色付きの枠線と大きなオーブを外した | 枠線が主張して安っぽく見えていた。ガラスの面と余白だけで浮かせ、状態は小さな点と短い語で示し、波形を主役にした（バー数 44 → 64、静的な減衰カーブを廃止して声の大小がそのまま形に出るようにした） |
| C-20 | 入力レベルは Float32 以外(Int16 / Int32)のバッファも扱う | `SpeechAnalyzer.bestAvailableAudioFormat` は **Int16** を返す。`floatChannelData` だけを見ていたため常に 0 になり、HUD の波形が動かなかった（音声自体は Int16 のまま STT に渡るので認識だけは正常、という分かりにくい症状になった）。`WhisperKitStt.floats(from:)` も同じ理由で Int16 対応が必要。回帰は `AudioLevelTests` で各フォーマットを検証する |
| C-21 | Default モードの整形方針を「構造化まで含む」に変更 | フィラー除去と句読点だけでは物足りず、話が複数項目に分かれていれば箇条書きに、話題が変われば段落に分ける。ただし丁寧さは足さない（元の口調を保ち、過剰な敬語に言い換えない）。項目を勝手に増やさないという基本ルールは維持する |
| C-22 | 同梱プロンプトを更新したとき、**未編集のビルトインモードだけ**追従させる | 投入時に「同梱プロンプトの写し」を `meta` に記録し、DB の内容がそれと一致していれば未編集と判定して更新する。編集済みは触らない。写しを持たない世代の DB は一度だけ同梱内容に揃える |
| C-23 | 履歴と設定を 1 ウィンドウに統合し、起動直後は履歴を開く | 別ウィンドウだと行き来が面倒で、どちらを見ているか分からなくなる。サイドバーの「履歴」＋「設定」各セクションで切り替える形にし、権限未設定はサイドバー下部に常に出す。起動時に開くかは設定で切り替えられる |
| C-24 | 出力検証に「入力との一致度」を追加した | 長さ比と漏洩マーカーだけでは、**長さが妥当なまま中身が別の文にすり替わる**ケースを通してしまう（実測で語彙の few-shot 例文がそのまま出力され、検証を通過して挿入されかけた）。入力と出力の文字バイグラムの共有率を測り、0.15 を割ったら整形結果を捨てて生テキストにフォールバックする。日英の翻訳では素材が共有されないため、入出力の判定言語が異なる場合はこの検証を外す |
| C-25 | ~~語彙の機械置換は形態素境界に一致する出現だけにする~~ → **C-43 で撤回**（機械置換そのものをやめた） | 日本語には語の区切りが無いため、素朴な `replacingOccurrences` は過剰置換になる（「アイ」→「AI」が「アイデア」を壊す）。`NLTokenizer`（オンデバイス）で語境界を取り、開始と終了が境界に乗る出現だけ置換する。乗らないものと 1 文字パターンは触らず、LLM 段の語彙表に委ねる。つまり**決定的に安全なものだけコードで処理し、判断が要るものはモデルに残す**という分担になる |
| C-26 | 語彙は STT 段にも渡す（D-6 の「従」を実装で明示） | SpeechAnalyzer は `AnalysisContext.contextualStrings[.general]`（表記と読み、重複除去して最大 200 件）、WhisperKit は initial prompt の `promptTokens`。認識段でバイアスをかけ、取りこぼしを LLM 段の語彙表で拾う二段構え（C-43 で機械置換の段を外した） |
| C-27 | 履歴の一覧/詳細の分割は `HSplitView` を使わず、`HStack` + 自作の可変仕切りで組む | `HSplitView` は子の縦幅を伸ばしてくれず、一覧がコンテンツの高さのままペイン中央に浮いて枠付きカードのように見えていた（`.listStyle(.inset)` の枠も重なった）。AppKit の暗黙のサイズ決定に依存すると、レイアウトが検証もできない（`ImageRenderer` で描画できないため目視確認が不可能）。純 SwiftUI にすればオフスクリーンで検証でき、リサイズもドラッグで維持できる。一覧は `.listStyle(.plain)` にして枠を消した |
| C-27 | 履歴の一覧/詳細の分割は `HSplitView` を使わず `HStack` + 自作の可変仕切りで組む | `HSplitView` は子の縦幅を伸ばさず、一覧がコンテンツの高さのままペイン中央に浮いて枠付きカードのように見えていた（`.listStyle(.inset)` の枠も重なった）。AppKit の暗黙のサイズ決定に依存するとオフスクリーン描画もできず目視検証が不可能。純 SwiftUI にすれば検証でき、リサイズもドラッグで維持できる |
| C-28 | ~~WhisperKit の暫定認識は音声取り込みと別タスクにし、確定前に走り切るのを待つ~~ → **C-34 で撤回**（暫定認識そのものを廃止した） | 取り込みループの中で認識していたため、認識中は取り込みが止まり、停止後もバッファ消化に認識が挟まって「認識中」から進まなくなった（かつ毎回全区間を再認識するので O(n²)）。取り込みは止めず、暫定認識は best-effort の別タスクにする。WhisperKit は直列利用前提なので、確定前に `await partials.value` で走り切りを待つ。`chunkingStrategy` は既定(nil)に戻し（短い音声で `.vad` は不安定）、`usePrefillPrompt` は常に有効にした |
| C-29 | 停止後の確定に watchdog を入れた | STT にタイムアウトが無く、エンジンが応答しないと「認識中」から永久に戻らず、次の録音も開始できなかった。60 秒で打ち切り、暫定テキストがあればそれで整形・挿入まで進める（発話を失わない）。二重実行は `finalizationHandled` で防ぐ |
| C-30 | 長押し判定の既定値を 300ms → 500ms に上げ、押下の解釈をログに出す | 「軽く叩いたつもり」の押下は 300ms を超えることが多く、トグルのはずが push-to-talk と判定されて即停止していた。旧既定値(300ms)のままの設定だけ新既定値へ寄せる（自分で変えた値は触らない）。判定のずれを切り分けられるよう、押下・離上の実測時間と決定した意図を `KoeLog.hotkey` に出す。また処理中で開始できなかった押下が押下状態を残して次の離上判定を狂わせていたのを、`start` の戻り値で判定するように直した |
| C-31 | UI の文言から開発者視点の語を排除した | p50/p95・レイテンシ目標・STT/LLM・エンジン・プロンプト・bundle ID といった語は実装の都合であって利用者の関心ではない。「聞き取り」「文章の仕上げ」「話し終わってから挿入まで」「ふだん 1.2 秒で入ります」「このとき使われた指示文」のように、その人が判断に使える言葉へ置き換えた |
| C-32 | モデル選択を 1 段のフラットなリストにした | 「エンジンを選ぶ → その中のモデルを選ぶ」の二段構えは実装の構造がそのまま出ていた。`ModelChoice` として「Apple 標準」「Whisper large-v3-turbo」…を並べ、選ぶと裏でエンジンとモデル ID の両方が設定される |
| C-33 | 選択肢ごとに正確さ・速さの目安と**実測時間**を表示する | 目安だけでは選べず、数字を作ると嘘になる。5 段階の帯は「目安」と明示し、それとは別に履歴から集計した実測の中央値（エンジン・モデル別）を出す。実測は Koe が元々記録している情報なので、追加のベンチマークは要らない（`HistoryStore.measuredLatencies`） |
| C-34 | WhisperKit の**録音中の暫定認識を廃止した**（C-6 と C-28 を撤回） | 数秒おきの再認識が GPU/ANE を占有し、**HUD の波形が目に見えて遅れた**。波形は「喋っている今」が出ることに価値があり、遅れた波形は情報ではなく違和感になる。加えて毎回全区間を引き直すので暫定テキストが安定せず（前に出た語が消える・語順が変わる）、逐次表示としても役に立っていなかった。「リアルタイムな波形」と「不安定な逐次テキスト」の二択なら前者を採る。録音中は音声を溜めるだけにし、認識は停止後の 1 回だけにする。SpeechAnalyzer は本来のストリーミング API を持つので逐次表示のまま |
| C-35 | 確定 watchdog を録音長に比例させる（C-29 の補正） | C-34 で WhisperKit は暫定テキストを持たなくなったため、打ち切り = 発話の喪失になった。固定 60 秒だと長い口述で**正常に進んでいる認識を殺す**。下限 30 秒 + 録音 1 秒あたり 2 秒に変え、`audio.capturedDurationMs` から停止時に算出する |
| C-36 | プロンプトが期待出力長を申告し、`LlmEngine` が入力予算を公開し、履歴分析はバッチ分割する | 語彙自動提案が **Context Exceeded で一度も成功していなかった**。原因は 2 つ。(1) 最大 60 セッション×400 字×2 を 1 プロンプトに詰めており、Foundation Models の 4,096 トークン窓を大幅に超えていた。(2) 応答枠を「入力の 2 倍」で見積もる整形向けの式を分析にも当てており、入力と応答が同じ窓を共有する事実を無視していた（入力 2,000 字 + 応答枠 4,000 で確実に超える）。出力の規模を知っているのは呼び出し側なので `FormattingPrompt.expectedOutputCharacters` で申告させ、コンテキスト窓の制約はエンジンが `inputCharacterBudget` として公開する。分析側はその予算に収まるバッチへ分割して複数回問い合わせ、候補をマージする。根拠の数え直しはバッチ境界に関係なく全セッションを跨いで行う（C-8 のまま）。1 バッチの失敗は全体を捨てず、ただし**透かしを進めない**ので次回が再試行する。全滅だけは throw して理由を出す |
| C-37 | 実測の速さは「音声の長さに対する倍率」で見せる（C-33 の補正） | 「3.2 秒」だけではモデルを比較できない。20 秒の発話で 3.2 秒なのか 5 分の発話で 3.2 秒なのかで意味が正反対になる。セッションごとに `latency ÷ audio_duration_ms` を取り、その**中央値**を主表示にする（合計の比だと長い 1 回に引っ張られる）。倍率だけでは体感が湧かないので「音声 10 秒 → 3.5 秒」を添える。立ち上がりコストが支配する 1 秒未満の録音と、音声長が未記録の行は倍率の母数から外す（秒数の母数とは別に数える） |
| C-38 | MLX の依存を `mlx-swift-examples` → `mlx-swift-lm` に移し、WhisperKit も 0.18 へ上げた | Qwen3(2025)は世代が古いが、Qwen3.5 を使うには依存を 3 段まとめて動かす必要があった。(1) LLM ライブラリは `mlx-swift-examples` から **`mlx-swift-lm`** に分離され、`model_type = qwen3_5` を持つのは後者だけ。(2) mlx-swift-lm 3.x は provider 非依存になり、取得(`Downloader`)とトークナイザ(`TokenizerLoader`)を利用側が渡す設計に変わった。上流の `#hubDownloader()` マクロは swift-transformers 1.x 前提。(3) Qwen3.5 の `tokenizer_class` は `TokenizersBackend` で、これを解釈できるのも swift-transformers 1.x だけ。ところが WhisperKit 0.14 が swift-transformers を `.upToNextMinor(from: 0.1.8)` で固定していた。**WhisperKit 0.15 以降は自ら swift-transformers 1.1.x を要求する**ので、0.18 へ上げることで 1.x が解決でき、鎖がほどけた。マクロは使わず 2 つのプロトコルを自分で満たす（`MlxHubBridge` + `ModelStore.mlxDownloader`）ことで、ネットワーク経路を ModelStore に閉じ込める規約（NFR-2）も維持した |
| C-39 | Qwen3.5 は VLM 配布のものをテキスト専用として読む | `mlx-community/Qwen3.5-*-4bit` は vision/video の前処理設定を含む VLM だが、`model_type = qwen3_5` は mlx-swift-lm の **LLM** レジストリにも登録されており、`Qwen35Model.sanitize` が `vision_tower` / `model.visual` の重みを落として `language_model` に寄せる。つまり整形用途にそのまま使える。テキスト専用の別リポジトリを探す必要はない |
| C-40 | カタログから消えたモデル ID は起動時に既定へ寄せる | モデルの世代交代のたびに、設定に保存された旧 ID（例: `Qwen3-4B-Instruct-2507-4bit`）が宙に浮き、選択が「どれでもない」状態になって存在しないモデルを取得しようとする。`AppSettings` のデコード時にカタログと突き合わせ、無ければ既定へ戻す |
| C-41 | `make build` は xcodebuild の失敗を必ず伝播させる | 出力を `grep ... \|\| true` で絞っていたため、**ビルドが失敗しても `app` ターゲットが古いバイナリを固めて起動していた**（mlx-swift 0.31 の `CudaBuild` プラグイン検証で実際に踏んだ）。`set -o pipefail` にして grep だけを `|| true` で包む。あわせて非対話ビルドのために `-skipPackagePluginValidation -skipMacroValidation` を渡す（mlx-swift のビルドプラグインと swift-syntax のマクロが対話的な信頼確認を要求する） |
| C-42 | 設定画面の「へこんだ面」を `sunkenSurface` に一元化した | モード設定の一覧が `.listStyle(.sidebar)` のままだったため、コンテンツペインの中でサイドバーの素材（ガラス）を継承し、**一部だけリキッドグラスが乗った中途半端な見た目**になっていた。面の出し方を各画面が独自に書いていたのが原因なので、一覧・入力欄の面を 1 つの modifier に集約した。あわせてモード編集側の入れ子 `ScrollView`（ペイン側と二重）を外した |
| C-43 | 語彙の**機械置換をやめた**（C-9 と C-25 を撤回）。語彙はモデルへのヒントに限る | 日本語には語の区切りが無く、表記の正しさは文脈で決まる。形態素境界に一致する出現だけ置換するところまで作っても（C-25）、決定的アルゴリズムで「ここは直すべきか」を判断しきれない。同音異義・活用・複合語のたびに例外が増え、辞書を足すほど誤爆の面積が広がる構造だった。語彙の使い道を **STT のバイアス**（`contextualStrings` / initial prompt）と**整形プロンプトの語彙表**の 2 つに絞り、Koe 自身は文字起こしに一切手を入れない。判断はモデルに寄せる。副作用として、整形をスキップしたときに挿入されるのは常に `rawTranscript` そのものになり（`markFormattingSkipped` の `fallbackText` を削除）、「挿入された文字列がどこから来たか」が 2 通りだけになって追いやすくなった。1 文字パターンの特別扱いも不要になった |
| C-44 | 語彙エントリの「メモ」欄を廃止した | 整形プロンプトに載せる以外の使い道が無く、載せてもモデルの出力を安定させる効果が見込めない。辞書が持つべきなのは「正しい表記・読み・よくある誤認識」だけ。DB は `v2-drop-vocabulary-note` で列を落とす |
| C-45 | リソースバンドル内のファイルは `Bundle(url:)` に解決させる | `Bundle.main.url(forResource:withExtension:subdirectory:)` にリソースバンドル名を渡す書き方は、macOS の `.bundle/Contents/Resources/` 階層を辿れない（iOS はこの階層が無いので同じコードが通る）。`default.metallib` が同梱されているのに `isMetalLibraryBundled` が false になり、MLX が常に「この Koe では使えません」と表示される状態になっていた。**バンドル内のパスを文字列で組まない**のが規則 |
| C-46 | WhisperKit を 1.0.0 へ、swift-transformers を 1.3 系へ上げた（C-38 の続き） | WhisperKit 1.0.0 は `argmax-oss-swift` に再編され、swift-transformers 依存を自前の `HubApiWrapper` に置き換えた。これで **swift-transformers の版を Koe 側の都合で選べる**ようになり、C-38 で作った「WhisperKit がトークナイザの版を縛る」という制約自体が消えた。Koe 側のコード変更は 0 行（`WhisperKitConfig` / `download` / `DecodingOptions` は互換）。なお WhisperKit の版を上げた直後の初回認識は CoreML の再コンパイルで数分かかる（実測 223 秒 → 2 回目以降 4 秒）ので、ハングと区別できるようにしておく |
| C-47 | 設定ペインの横幅上限をセクションごとに持たせた | 1 カラムの設定は行が長いと読みにくいので 660pt で絞るのが正しいが、モード設定は「一覧 + 編集」の 2 カラムなので同じ上限だと編集側が 400pt 弱しか残らず、プロンプト欄が数語で折り返して極端に窮屈になる。段組みの数が違う画面に同じ幅を当てない。`MainSection.contentMaxWidth` で表現し、モードだけウィンドウ幅を使う |
| C-48 | 設定ペインは `LazyVStack` で組み、`SMAppService` の問い合わせを描画経路から外した | 「一般」を開くまでの体感遅延を実測で切り分けた結果（`ImageRenderer` でペインを描画して計測）: プライバシー 3.9ms / モデル 22.7ms に対し**一般は 30ms（プロセス初回は 137ms）**で、内訳は segmented Picker×3 で 11ms、Toggle×4 で 8.8ms と、AppKit 由来コントロールの生成コストの積み上げだった。`VStack` は画面外のカードまで先に組むため、**見えないコントロールの生成を全部払ってから初回描画が始まる**。`LazyVStack` にすると 49.2ms → 30.8ms（-37%）。あわせて `Toggle` を `.switch` に統一（8.8ms → 4.2ms、macOS の設定として見た目も標準）。Picker は segmented が既に最速で、menu(12.2ms)・radioGroup(27.2ms) は悪化するので変えない。`LoginItem.needsApproval` を `body` から呼んでいたのも直したが、**これは主因ではなかった**（BTM デーモンへの同期 XPC は 1 表示 1 回・約 3ms＝描画時間の 7%）。ただし描画中に同期 XPC を置くのは筋が悪く、ログイン項目として登録済みの環境では待ちが伸びるため、状態は `AppEnvironment` にキャッシュして起動時に非同期で取る |
| C-49 | 共通ルールの言いよどみ指示を「閉じた列挙」から判断基準に変え、失敗パターンの例を先頭に置いた | 実機の Foundation Models で計測して切り分けた。旧ルールは `フィラー(えーと / あのー / まあ / そのー / um / uh …)` という**列挙**で、実際の発話に出る「その」が列挙の「そのー」と一致しないため残り続けていた。語句の連続反復（「その処理その処理は」）も、ルール文が「重複は後の表現だけを残す」と抽象的で例が無く、まったく効いていなかった。短い入力 3 件で **素通し 2/3・繋ぎ語残存 8** → ルールを具体語＋反復の例に書き換えて **素通し 0/3・繋ぎ語残存 2**。手書きの最小プロンプト(295 文字)と同水準になった。**原因は指示量ではなく中身**で、新ルールは 1,777 文字と旧 1,287 文字より長いのに結果は良い（途中「指示が多すぎて薄まっている」と疑ったが、量を変えた比較で否定された）。回帰は `promptComposition` で、個別の語が名指しされていることを固定して防ぐ |
| C-50 | 「共通の処理」は概念として維持する。ただし UI から「自動で行われます」という表現を外した | モード指示を足しても共通ルールの効きは落ちないことを計測で確認した(芯だけ／芯+モード指示 = どちらも素通し 0/3)。したがって共通/モードの二層構造そのものは無罪で、廃止する理由が無い。一方 UI の「共通の処理は自動で行われます」は、決定的な前処理が走ると読めてしまう。実体は同じ system プロンプトに載る**モデルへの依頼**でしかなく、効かないこともある。「共通の指示が先に入ります」に改めた |
| C-51 | **長い一文の口述では、言いよどみ除去がまだ効かない**（未解決の制約） | 267 文字の句読点なし一文では、新ルールでも句読点が付くだけで繋ぎ語 10 個・反復もそのまま残る。短文では同じルールが完璧に効くので、入力長で性能が落ちる現象（C-10 と同種）。「句読点だけ入れる → 文ごとに整形」の 2 段処理も試したが、区切り位置が的外れで改善しなかった。オンデバイスモデルの能力上限と判断している。回避するなら口述を短く切るか、より大きいモデル（MLX 系）に投げる必要がある。**MLX を削るかどうかの判断では、この制約が唯一の実測された反対材料になる** |
| C-52 | **MLX と WhisperKit のサポートを完全に削除し、OS 内蔵モデル専用にした**（D-5 を撤回） | 実使用の実績が判断材料になった。履歴 26 件で STT は SpeechAnalyzer 24 / WhisperKit 2、整形は Foundation Models 25 / **MLX 0**。ダウンロード済みモデルも 0 件で、実質すでに OS 標準だけで足りていた。一方コストは大きく、1 セッションで入れた設計変更 9 件のうち 8 件が非 OS エンジン起因だった（C-7 / C-34 / C-35 / C-38 / C-39 / C-40 / C-41 / C-45 / C-46）。mlx 系はリポジトリの分離・改名を含めて動きが速く、追従が年に何度も来る。削除の結果: **依存 18 パッケージ → GRDB 1 つ**、xcodebuild と Metal ツールチェーンが不要になり `swift build` だけでビルドできる（フルビルド 17 秒）、`ModelChoice` / ダウンロード進捗 / ディスク使用量 / モデル選択 UI / エンジン選択設定という概念ごと消えて約 1,150 行減。`SttEngine` / `LlmEngine` の protocol 境界だけは残す（パイプラインを具体型から切り離してテストで差し替えられるため）。受け入れたリスクは 2 つ: Apple Intelligence が無効だと整形できない（D-3 の前提と整合）、コンテキスト窓 4,096 と C-51 の長文制約が固定される |
| C-53 | 共通ルールを**編集可能にして UI に出した** | モードごとの指示だけを見せていると、共通側で既に何が指示されているか分からず、モード側に重複や**逆向きの指示**を書いてしまう（実際に起きていた、C-54）。`BuiltinSharedRules` として同梱し、`meta` に現在値と同梱内容の写しを持たせて、モードのプロンプトと同じ規則で扱う（C-22 と同じ: 未編集なら新しい同梱内容へ追従、編集済みは触らない、標準に戻せる）。UI はモード一覧の先頭に「共通ルール」を固定し、モードを書きながら同じ画面で読めるようにした。`FormattingPolicy.systemPrompt` は共通ルールを引数で受け取る |
| C-54 | 共通ルールとモード指示の逆向きの指示を解消した | 洗い出した衝突: (1) 共通「発話に含まれない情報を足さない」vs Default / AI Agent / Mail の「主語や助詞の欠けを補って」——**補完と加筆の線引きを共通側で決め**（「主語・助詞・接続詞の欠けは補う。これは情報を足すことには当たらない」）、モード側の重複表現を削除した。(2) Memo「言い切れていない部分もそのまま残す」vs 共通の言いよどみ除去・言い直し整理——「結論が出ていない話を無理にまとめない」に言い換えて、除去対象と混ざらないようにした。(3) AI Agent「推測できないならそのまま残す」は指示語の話だが言いよどみ保持と読めるため「言い換えない」に変更。(4) Default から「文字起こし特有のエラー訂正」を削除（共通の同音異義語ルールと重複）。回帰は `PromptConsistencyTests` で、モード側に「補って」「そのまま残す」が現れないことを固定して防ぐ。整理後も実機で 素通し 0/3・繋ぎ語残存 2 を維持（Default / AI Agent / Memo で確認） |
| C-55 | 語彙表を置換命令から**判断材料**に書き換え、モード指示の見出しを外した | 「入力に次の表記が出てきたら、**必ず**右側に置き換えてください」「語彙表(**最優先**)」は誤り。同じ読みで表記が分かれる語は文脈で決まり、「維持」は正しい語でもある。機械置換を捨てた C-43 の判断がプロンプト側に反映されていなかった。「この人がよく使う表記。文脈に合うほうを選ぶ。一覧にあるからといって機械的に置き換えない」に変更し、共通ルール 9 の「他のどのルールよりも優先する」も削除。あわせてモード指示に被せていた `# このモード(名前)固有の指示` の見出しを外して素で連結する（枠を増やしても情報は増えない） |
| C-56 | **LLM 段の語彙表は実測で効果ゼロ**（未解決の問題） | 上記の書き換えの前後で実機計測した結果、**強い命令でも柔らかい表現でも結果が変わらなかった**。同音語 6 件で「語彙表なし 3/6・system 内 3/6・user 内(入力の直前)3/6」と完全に同一。誤認識形が日本語として成立しない語（「レセ困」→「レセコン」、「変理」→「Henry」）でも **あり 0/3・なし 0/3** で、1 件も直らない。つまり Foundation Models の整形段は、渡された語彙に基づく表記の差し替えを**行わない**。これは C-9 が最初に観測した現象と同じで、C-9 はそれを機械置換で埋めていた。C-43 でその機械置換を外したため、**誤認識の矯正は STT のバイアス（`contextualStrings`）だけが担っている状態**になっている。STT 側が効いているかは未検証（合成音声を流す検証ハーネスが未完成）。ここが効いていないなら、語彙機能は誤認識に対して実質無力なので、機械置換の再導入か別の手段を検討する必要がある |
| C-57 | イベントタップのコールバックから重い処理を追い出した | ⌥D をホットキーにすると **∂ が前面アプリに入力される**症状の原因。消費判定(`return nil`)自体は正しかったが、コールバックの中で `onEvent` を**同期実行**しており、その先で `SoundPlayer.play` が走っていた。実測で初回 **184ms**（`NSSound.play` の CoreAudio 初期化。WAV 合成は 9ms で無関係）。イベントタップは規定時間内に返らないと OS が `tapDisabledByTimeout` でタップを無効化し、**その間のキーは前面アプリへ素通しする**。既定が右⌥（修飾キー単体＝素通ししても文字が出ない）だったため、この欠陥は今まで露見していなかった。**印字されるキーを割り当てて初めて見える**種類のバグ。対処: 押下・離上の通知を `DispatchQueue.main.async` で次のターンへ回す（FIFO が保証されるので押下と離上の順序が壊れない）。Esc だけは消費判定を同期で返す必要があるため、`shouldSwallowEscape` として安価な状態参照だけに絞り、実際の中止処理は呼び出し側が次のターンへ回す。タップ無効化はログに残して追えるようにした |
| C-58 | 効果音の出力経路を起動時に温める | 上記の 184ms は `NSSound.play()` の初回だけに出る CoreAudio 初期化。波形をキャッシュしても消えないので、起動時に音量 0 で一度鳴らして払う（`SoundPlayer.prewarm()`）。押下時は 12ms になる。これが無いと**最初の録音の立ち上がりだけ 180ms 遅れる**（FR-1.1 の ≤100ms を単独で超える） |
| C-59 | ホットキー記録は修飾キーを**保留**して通常キーを待つ | 修飾キー + 文字キーの組み合わせが**一度も設定できていなかった**。⌥D を押すと ⌥ の `flagsChanged`(keyCode 58)が先に届き、記録側がそれを即座に `.modifier(.leftOption)` として確定して記録を終了していたため、D の `keyDown` に到達できない。同じ操作列から「⌥ 単体」と「⌥D」を見分ける必要があるので、修飾キーは押下時に確定せず保留し、通常キーが続けばそちらを採る／押して離されただけなら単体割り当てとして確定する、という規則にした。判定は純粋ドメイン(`HotkeyRecorder`)に切り出してテストで固定（`HotkeyGestureInterpreter` と同じ扱い）。あわせて **修飾キー無しの文字キーを拒否**する（イベントタップが消費するので、割り当てるとそのキーが二度と打てなくなる。ファンクションキーだけ例外）。記録中はローカルモニタで `nil` を返してキーをアプリへ渡さない |
| C-60 | ホットキー記録中はグローバル監視を一時停止する | 記録のためにキーを押すと、それが**いま設定されているホットキーに一致して録音が始まって**いた（記録用のローカルモニタとは別に、イベントタップが動き続けているため）。`HotkeyMonitor.setSuspended(_:)` を追加し、記録中は解釈も消費もせず素通しにする。タップ自体は生かすので権限の再取得は起きない。素通ししたキーは、記録中は前面(Koe 自身)のローカルモニタが受け取って消費するので前面アプリにも漏れない。停止の解除は `stop()` の 1 箇所に集約する（ここを通らない経路を作るとホットキーが死ぬ）。一時停止中は Esc も飲み込まない — 記録の取り消しはローカルモニタの仕事なので、二重に扱わない |
| C-61 | 語彙表を圧縮し、モード指示より**後ろ**（入力の直前）へ移した | 判断の基準を語ごとに文章で書いていたため、同じ説明が語数ぶん繰り返されていた（3 件で 338 → 130 文字。語が増えるほど差が開く）。基準は見出しに 1 回だけ書き、語ごとは `- 医事(いじ) ← 「維持」` の記法に寄せる。あわせて並び順を「共通ルール → モード指示 → 語彙表」に変更した。従来は語彙表がモード指示より前にあり、コード中の「語彙は入力の直前に置く」というコメントと実装が食い違っていた。実機で整形品質は不変（素通し 0/3・繋ぎ語残存 2） |
| C-62 | **文章の仕上げに限り、Groq API を選べるようにした**（D-1 を部分的に撤回） | Foundation Models の整形品質が実使用に耐えないという判断。C-51（長い一文で言いよどみ除去が効かない）と C-56（語彙表が実測で効果ゼロ）は、どちらもオンデバイスモデルの能力上限として未解決のまま残っていた。より大きいモデルに投げる以外の手が無い。**譲らなかった線**: (1) 聞き取りは SpeechAnalyzer のままで、**音声そのものは絶対に外に出ない**。出るのは文字起こしと指示文だけ。(2) 既定は `onDevice` で、明示的に選ばない限り挙動は変わらない。(3) 選択肢は `FormattingBackend` の 1 箇所に閉じ込め、外に出るかどうかは `sendsTranscriptOffDevice` から引く。プライバシー画面・モデル画面がここを唯一の出どころにするので、設定と説明がずれない。(4) API キーは Keychain（`SecretStore`）だけに置き、設定 JSON・履歴 DB・ログのどこにも書かない。(5) 履歴の `llmEngine` / `llmModel` にどのモデルで整形したかが残るので、後から「この結果はどこで作られたか」を追える。(6) 整形の失敗は従来どおり生テキストへのフォールバック（C-43）なので、通信が落ちても発話は失われない。整形結果の検証（`FormattingPolicy.validate`）もエンジン非依存のまま通る |
| C-63 | HUD の居残り時間を**終わり方で変える** | 挿入まで通ったときは結果が挿入先アプリに出ているので、HUD に確認の役目が無い。一律 2 秒は長すぎて視界に居座っていた。成功は 120ms（フェードのきっかけを作るだけ）、読ませたい終わり方（失敗・クリップボード退避・整形スキップの注記あり）は 2 秒。判断は `DictationCoordinator.lingerDuration(for:detail:)` 1 箇所 |
| C-64 | 面の素材を「浮いている＝ガラス（`raisedGlass`）／へこんでいる＝塗り（`sunkenSurface`）」の 2 つだけに固定した | Liquid Glass を強めるにあたり、画面ごとに `.glassEffect` を直接書くと素材が食い違う（実際 HUD だけがガラスで他は `.quaternary` の塗りだった）。役割で決まる 2 つの modifier に集約し、カード・バナー・ピル・メニュー行はすべてそちらを通す。メニューパネルは `GlassEffectContainer` でまとめて境目を減らし、HUD はフェーズ色を `Glass.tint` で透かす（文字を増やさずに状態が伝わる） |
| C-65 | 録音中の HUD に入力デバイス名を小さく出す | 「どのマイクで録れているか」は精度の当たり外れに直結するのに、録り終わるまで気づけなかった（外部マイクを繋いだつもりで内蔵で録れている等）。名前は **システム既定の入力デバイス**（`kAudioHardwarePropertyDefaultInputDevice`）から引く（`AudioDevices`）。当初 `AVAudioEngine` の入力ノード（`kAudioOutputUnitProperty_CurrentDevice`）から引いていたが、macOS では入力ノードは `CADefaultDeviceAggregate-<pid>-<n>` という private な集約デバイスに束ねられており、**その内部名がそのまま UI に出た**。集約が追っているのはシステム既定の入力なので、既定を直接読むのが実体に一致する。表示は録音中だけ・`.tertiary`・中央省略で、主役（波形と逐次テキスト）を邪魔しない |
| C-66 | ~~**聞き取りにダウンロード型のモデル（Whisper large-v3-turbo）を選べるようにした**（C-52 を部分的に撤回）~~ →**C-74 で撤回** | 仕上げを Groq に替えて品質が上がったので、聞き取り側も上を試せるようにする。**譲らなかった線**: 既定は SpeechAnalyzer のままで、選ばない限り依存もダウンロードも発生しない。音声は外に出ない（クラウド STT は非目標のまま）。調査で分かった重要な事実を 2 つ記録する。(1) **Parakeet TDT 0.6b v3（最新の多言語版）は日本語に対応していない**（25 欧州言語のみ。NVIDIA のモデルカード・FluidInference の CoreML 版カード・FluidAudio のベンチマークいずれも一致。FluidAudio の README にある「and Japanese」は誤り）。日本語対応の Parakeet は日本語専用の別モデルしか無く、多言語を要件にすると Parakeet は選外になる。(2) **両モデルともバッチ**で、`AsyncStream` を食べながら確定する API が無い（`StreamingASR.transcribeStream` も入力は完成済みの `[Float]`）。したがって録音中の逐次テキストは出ず、停止後の待ちが録音長に比例する。この差は `TranscriptionBackend.finalizesWhileRecording` として型に持たせ、UI の説明と確定待ちの上限（C-67）がそこから決まる |
| C-67 | ~~確定待ちの上限を**エンジンの確定の仕方**で変える~~ →**C-74 で撤回** | バッチのモデルは停止してから録音全体を処理するので、上限を 30 秒固定のままにすると長い口述ほど打ち切られる。しかもバッチには暫定テキストが無いため、打ち切り時の救済（`salvageStalledRecognition`）が拾えるものがゼロで、**発話がまるごと消える**（NFR-3 違反）。`finalizationTimeout(recordedMs:finalizesWhileRecording:)` で、逐次確定なら 30 秒固定、バッチなら 30 秒 + 実時間 ×3 にする |
| C-68 | ~~依存は `soniqo/speech-swift` 1 本に絞った~~ →**C-74 で撤回** | Whisper large-v3-turbo と Qwen3-ASR を**同じパッケージで賄える**のがここだけだったため（WhisperKit + FluidAudio の 2 本立てを避けられる）。ただし代償は小さくない: 推移依存が **36 パッケージ**に増え（MLX・swift-transformers・WhisperKit に加えて hummingbird / SwiftNIO / async-http-client などの Web サーバ一式が `speech-server` CLI 経由で入る）、公開の C++ 実装をビルドしたバイナリ xcframework（`soniqo/speech-core` v0.0.6、checksum 固定）を 1 つ取り込む。パッケージ自体も v0.0.23 と若い。C-52 で「依存 18 → 1」に畳んだ判断を、聞き取りを選んだ人だけに限って戻す形になる。ビルド時間は 17 秒から数分規模に伸びる |
| C-69 | ~~**起動経路からモデルの取得とロードを完全に締め出す**（実際に起動不能にした事故の再発防止）~~ →**C-74 で撤回** | Qwen3-ASR を選んだ瞬間にアプリが応答しなくなり、以後**二度と起動できなくなった**。原因は `prewarm` → `prepare` → `fromPretrained` で、起動時とバックエンド切り替え時に **1.7GB のダウンロードとモデルロードが走っていた**こと。設定は永続化されるので、次の起動でも同じ経路に入り、抜け出せない。痕跡は `~/Library/Caches/qwen3-speech/models` が空のまま残っていたこと（今日のクラッシュレポートは 0 件で、クラッシュか無応答かは断定できていない）。対処は 2 段: (1) `prepare` は「取得済みか」を確かめて音声フォーマットを答えるだけにし、**取得は `install`（明示操作）だけ、ロードは最初の録音まで遅延**させる。`transcribe` も未取得なら通常の失敗にして、録音の裏で勝手に落とし始めない。(2) それでも起動経路で失敗しうるので、`beginBootGuard`/`endBootGuard` で「起動処理に入ったが完走していない」を記録し、次の起動で検出したら聞き取りを OS 内蔵へ自動的に戻す。**設定 UI に辿り着けない状態からは、アプリが自力で安全側へ戻るしかない**。教訓として: 永続設定から重い処理が起動経路で走る構造は、それ自体がクラッシュループの部品になる |
| C-70 | ~~**MLX 系のモデルは載せられない。CoreML のモデルだけにする**（Qwen3-ASR を撤回）~~ →**C-74 で撤回** | 「取得」を押した瞬間にプロセスが落ちた。単体で再現したところ原因は `MLX error: Failed to load the default metallib. library not found`。mlx-swift の Metal シェーダは **xcodebuild でしかコンパイルされず**、`swift build` では `.metallib` が 1 つも生成されない（実測: `.build` 配下に `*.metallib` がゼロ）。しかもこれは Swift のエラーではなく **MLX が abort する**ので `try` では捕まえられず、ログも残らずプロセスごと消える（今日のクラッシュレポートが 0 件だったのはこのため）。C-52 で「xcodebuild と Metal ツールチェーンが不要になった」と書いた構成の、そのままの裏返し。したがって MLX を使うには C-52 のビルド簡素化を丸ごと巻き戻す必要があり、モデル 1 つのために払う額ではない。**`WhisperASR` は依存が `AudioCommon` だけで MLX を含まない純 CoreML** なので、そちらだけを残す。実機で取得→ロード→日本語推論まで通ることを確認済み |
| C-71 | キーチェーンの読み出しを**プロセス内で 1 回**に絞る | API キーの照会ダイアログが何度も出て、利用者が不安を訴えた。`SecretStore.read` を `GroqLlm.availability()`（設定を触るたび・起動時）と `complete()`（整形のたび）から生で叩いていたため。キーチェーンは照会ごとに OS が許可を訊きうるので、読み出し回数がそのままダイアログ回数になる。`SecretStore` にプロセス内キャッシュを置き、書き込みは必ず同じ入口を通るのでキャッシュはずれない。**秘密の取り扱いは「安全か」だけでなく「利用者を不安にさせないか」まで含めて設計する** |
| C-72 | 設定の enum は**未知の値で全体を巻き添えにしない**ように読む | C-70 で選択肢を 1 つ消したとき、その値が保存済みだと `Storage.init(from:)` が throw し、`AppSettings.init` の `try?` が**設定ファイルを丸ごと初期値へ倒す**（ホットキー・モード・タイムアウトが全部消える）ことに気づいた。enum のデコードは `(try? decodeIfPresent(...)).flatMap { $0 } ?? fallback` で受け、知らない値だけを既定へ落とす。回帰は `SettingsForwardCompatTests` で固定 |
| C-73 | ~~重いモデルの「初回準備」は**取得ボタンの中で払わせる**。ダウンロード済み ≠ 使える~~ →**C-74 で撤回** | Whisper を選んで録音すると「認識中」から数分戻らなかった。実測すると **推論は 0.8 秒だが `fromPretrained` に 166 秒**かかっていた。内訳は CoreML → ANE のコンパイルで、**マシンごとに 1 度だけ**発生する（2 回目以降は同じ処理が 0.9 秒。プロセスを跨いでも速いので、コンパイル結果は OS 側に残る）。C-69 でロードを「最初の録音まで遅延」させた結果、この 1 回を**録音の直後**に払う形になっていたのが原因で、C-69 の修正が別の問題を作っていた。対処: (1) `install`（取得ボタン）が `fromPretrained` まで完走させ、終わったら `.koe-ready` マーカーを書く。(2) `isDownloaded`（落ちている）と `isReady`（使える）を**別の概念として分ける**。ディレクトリの有無だけ見ると、コンパイル未了を「使える」と誤判定して同じ穴に落ちる。(3) `availability` / `prepare` / `transcribe` はすべて `isReady` で判定し、未準備なら通常の失敗にする。(4) 進捗に**段階の文言**を持たせる（`install(progress:)` を `(Double, String)` に変更）。割合だけだと 8 割で数分止まって見え、壊れたと受け取られる。教訓: **「ダウンロード済み」を準備完了と同一視しない**。重いモデルには取得の後に無視できない初期化が続くことがある |
| C-74 | **ダウンロード型 STT（Whisper large-v3-turbo）を丸ごと削除し、聞き取りは SpeechAnalyzer 専用に戻した**（C-66〜C-70 / C-73 を撤回） | 実際に使ってみて「SpeechAnalyzer で十分」という判断。得られたはずの精度に対して、払ったコストと事故が釣り合わなかった。この試行で 3 回続けて実害を出している: (1) 起動経路に 1.7GB のダウンロードが入って**二度と起動できなくなった**（C-69）、(2) MLX が metallib 不在で **abort**（C-70）、(3) 初回の ANE コンパイル 166 秒を録音後に払わせて「認識中」から数分戻らなくなった（C-73）。いずれも実機で一度通していれば初回に分かったもので、**重いモデルを扱う機能は「コンパイルが通った」を完成と見なしてはいけない**という教訓が残った。削除で戻ったもの: 依存 37 パッケージ → **GRDB 1 つ**、`Package.swift` からバイナリ xcframework とプリビルド依存が消え、`swift build` に `--disable-keychain` が要らなくなり、ビルド時間も元に戻った。`TranscriptionBackend` / `LocalModelStt` / 聞き取りのモデル選択 UI / 取得の進捗という概念ごと消えている。**残したもの**: C-71（キーチェーン読み出しのキャッシュ）と C-72（未知の enum 値で設定を巻き添えにしない）は Groq 側で現役の防御なので維持する |
