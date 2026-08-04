# Koe

macOS 専用・完全ローカルの音声入力アプリ。話した内容が、いま作業しているアプリにふさわしい完成文になって挿入される。

- 要件: [docs/spec.md](docs/spec.md)
- 設計: [docs/design.md](docs/design.md)
- 概要(人間向け): [docs/overview/index.html](docs/overview/index.html)

音声・文字起こし・整形テキスト・語彙・履歴は**一切ネットワークに出ない**。通信するのはモデルのダウンロードだけで、その処理は [ModelStore](Sources/KoeKit/System/ModelStore.swift) に隔離してある。

## 必要環境

- macOS 26 (Tahoe) 以降 / Apple Silicon
- Xcode 26 以降

## ビルドと起動

```bash
make run
```

`Koe.app` を組み立てて起動する。権限(マイク・アクセシビリティ)は .app に対して付与されるため、開発中も素の実行ファイルではなく必ず .app で起動する。

| コマンド | 内容 |
|---|---|
| `make run` | ビルド → `build/Koe.app` を組み立て → 起動 |
| `make app` | 組み立てまで |
| `make test` | ユニットテスト |
| `make install` | Release ビルドを `/Applications` へ配置 |
| `make stop` | 起動中の Koe を終了 |

### MLX を使う場合

整形エンジンに MLX(Qwen3-4B など)を選ぶには Metal シェーダのコンパイルが必要で、これは SwiftPM の CLI ビルドではできない(mlx-swift の上流制約)。Metal ツールチェーンを入れると `make` が自動的に `xcodebuild` 経由のビルドに切り替わる。

```bash
make metal-toolchain
```

入れていない場合、MLX は設定画面で理由付きの「使用不可」として表示され、選んでも呼び出される前に弾かれる(既定の Apple Foundation Models はそのまま使える)。

### 初回に必要な許可

1. **マイク** — 初回の録音時にダイアログが出る
2. **アクセシビリティ** — ホットキーの監視とテキスト挿入に必要。システム設定 > プライバシーとセキュリティ > アクセシビリティ で `Koe.app` を許可する

### アクセシビリティの許可が毎回外れるとき

ad-hoc 署名（`codesign -s -`）は identity が cdhash 自身なので、リビルドするたびに別アプリ扱いになり、許可が無効になる。固定の自己署名証明書を一度作れば解決する。

```bash
make dev-cert
```

以降 `make app` / `make install` はこの identity で署名するため、リビルドしても許可が残る。許可が壊れて有効にできなくなった場合は登録をリセットする。

```bash
make reset-permissions
```

同じ bundle ID のコピーが複数あると TCC が混乱するため、`make install` は `build/Koe.app` を残さない。開発中も `/Applications/Koe.app` の 1 つだけを使うのが安全。

## 使い方

- **右 ⌥ を短く押す** → 録音開始(トグル)。もう一度押すと停止して整形・挿入
- **右 ⌥ を押しっぱなし** → push-to-talk。離した瞬間に停止して整形・挿入
- **録音中に esc** → 破棄。挿入はしないが、認識済みテキストは履歴に残る

ホットキー・長押し閾値は設定画面で変更できる。

## 構成

```
Sources/KoeKit/
├── Domain/        純粋なドメイン層(AppKit/AVFoundation 非依存)
│                  セッション状態機械・モード解決・整形プロンプトと出力検証・語彙
├── Engines/       差し替え可能な推論エンジン
│                  SpeechAnalyzer / WhisperKit, Foundation Models / MLX
├── System/        macOS 統合(ホットキー・音声入力・テキスト挿入・モデル取得)
├── Persistence/   GRDB(SQLite)。履歴・モード・語彙・メタ情報
├── Analysis/      履歴からの語彙自動提案
├── App/           状態機械の駆動・設定・エンジン選択
└── UI/            SwiftUI(メニューバー・HUD・設定・履歴)
```

依存の向きは `UI → App → Domain ← Engines / System / Persistence`。Domain が protocol を定義し、外側が実装を注入する。

### 守っている不変条件

**発話を失わない。** STT 確定 → 永続化 → 整形 → 挿入の順序を [SessionDraft](Sources/KoeKit/Domain/Session.swift) が型で強制する。`finalizeTranscript` を通るまで永続化可能な `SessionRecord` は存在しないので、整形や挿入を先に実行することが構造的にできない。整形が失敗すれば生テキストを挿入し、挿入が失敗すればクリップボードに残す。

**後から説明できる。** 各セッションに、適用したモード・**プロンプト全文**・エンジン・モデル・各段のレイテンシを記録する。設定を変えても過去の履歴は当時の内容を保持する。
