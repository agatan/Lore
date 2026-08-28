# Koe

macOS 専用の音声入力アプリです。話した内容を文字にし、いま作業しているアプリに合う文章へ整えて挿入します。

音声認識と既定の文章整形は Mac 上で動作します。利用者が明示的に Groq を選んだ場合に限り、文章の仕上げのために文字起こしと指示文を Groq API へ送信します。録音した音声は保存・送信しません。詳しくは [データ取り扱い](PRIVACY.md) を参照してください。

- 要件: [docs/spec.md](docs/spec.md)
- 設計: [docs/design.md](docs/design.md)
- 概要: [docs/overview/index.html](docs/overview/index.html)

## 必要環境

- macOS 26 (Tahoe) 以降
- Apple Silicon
- Xcode 26 以降

## ビルドと起動

```bash
make run
```

権限は `.app` に対して付与されるため、開発中も実行ファイルを直接起動せず `make run` を使います。

| コマンド | 内容 |
|---|---|
| `make run` | ビルドして `Koe.app` を起動 |
| `make app` | `Koe.app` の組み立てまで実行 |
| `make test` | ユニットテストを実行 |
| `make install` | Release ビルドを `/Applications` へ配置 |
| `make stop` | 起動中の Koe を終了 |

### 初回に必要な許可

1. **マイク** — 音声認識に使用します。
2. **アクセシビリティ** — ホットキーの監視とテキスト挿入に使用します。

### アクセシビリティの許可が毎回外れるとき

ad-hoc 署名ではリビルドのたびに別アプリとして扱われます。固定の自己署名証明書を一度作ると、開発中の許可を維持できます。

```bash
make dev-cert
```

許可が壊れた場合は、次のコマンドでこのアプリの登録だけをリセットできます。

```bash
make reset-permissions
```

## 使い方

- **右 ⌥ を短く押す** — 録音を開始・停止します。
- **右 ⌥ を押し続ける** — push-to-talk として動作します。
- **録音中に Esc** — 挿入を取り消します。認識済みの文字があれば履歴に残します。

ホットキーと長押し閾値は設定画面で変更できます。

## 文章の仕上げ

- **この Mac の中で仕上げる** — 既定値です。Apple Foundation Models を使用し、文字起こしを外部送信しません。
- **Groq API で仕上げる** — 利用者が選んだ場合だけ、今回の文字起こし、共通ルール、モード指示、語彙を Groq API へ送ります。API キーは macOS Keychain に保存します。

どちらの方式でも、整形に失敗した場合は生の文字起こしを挿入します。語彙の自動提案は常にオンデバイスで実行し、過去の履歴を Groq へ送りません。

## 構成

```text
Sources/KoeKit/
├── Domain/        セッション状態、モード、整形ルール、語彙
├── Engines/       SpeechAnalyzer、Foundation Models、Groq
├── System/        ホットキー、録音、挿入、Keychain、macOS 統合
├── Persistence/   GRDB / SQLite による履歴・設定データ
├── Analysis/      オンデバイスの語彙候補分析
├── App/           状態機械の駆動と依存関係の組み立て
└── UI/            メニューバー、HUD、設定、履歴
```

中心となる不変条件は「発話を失わない」ことです。STT 確定後の文字起こしを先に永続化してから整形・挿入へ進み、整形失敗時は生テキストへ、挿入失敗時はクリップボードへ退避します。各履歴には適用したモード、指示文、エンジン、モデル、処理時間を記録します。

## License

[MIT License](LICENSE)
