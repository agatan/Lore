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
    func complete(prompt: FormattingPrompt, timeout: Duration) async throws -> String
}
```

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
2. ローカル LLM に対し、以下を抽出させる:
   - 頻出する固有名詞・専門用語（未登録のもの）
   - raw → formatted で繰り返し矯正されているパターン（誤認識候補）
   - 同一概念の表記ゆれ
3. 抽出結果を既存語彙・却下済み候補と突き合わせ、新規のみ `vocab_suggestions` に出現回数・出現例（evidence）付きで保存。
4. 設定画面の「語彙 > 提案」タブに表示。承認 → `vocabulary` へ昇格、却下 → `rejected` として記録し再提案を抑止。

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
| D-1 | 完全ローカル専用。BYOK も無し | プライバシーが製品価値の核。クラウド分岐を残すと NFR-2 の検証可能性（ネットワーク境界の一元化）が壊れる |
| D-2 | Swift ネイティブ | ホットキー・アクセシビリティ・音声・MLX/FoundationModels すべて macOS API 直結。Rust+Tauri はブリッジが二重になるだけ |
| D-3 | macOS 26+ / Apple Silicon 専用 | SpeechAnalyzer と FoundationModels で「追加 DL なしで即使える」初期体験を作れる。自分専用ツールなので互換性負債を負わない |
| D-4 | 整形完了後の一括挿入 | 即挿入→置換は挿入先アプリ（Electron・ターミナル）との相性問題が既知。シンプルさ優先。レイテンシはストリーミング STT + 小型 LLM で吸収 |
| D-5 | STT/LLM とも 2 エンジン構成（標準 API + 内蔵モデル） | 「ゼロセットアップで動く」と「品質の天井を上げられる」の両立。protocol 境界が明確なら 2 実装のコストは低い |
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
