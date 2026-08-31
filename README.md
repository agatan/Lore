# Koe

macOS 専用の音声入力アプリです。口述入力と、自分の発話・予定・TODOを一日の時間軸に残す **ライフログ** を提供します。

音声認識と既定の文章整形は Mac 上で動作します。口述音声は保存しません。ライフログを明示的に有効にした場合だけ、再処理可能な音声チャンクをMac内へ保存します。音声は外部へ送信しません。詳しくは [データ取り扱い](PRIVACY.md) を参照してください。

- 外部仕様: [Markdown](docs/spec.md) / [HTML](docs/spec.html)
- 内部設計: [Markdown](docs/design.md) / [HTML](docs/design.html)
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
| `make ui-test` | 主要CUJを実アプリで操作するUI E2Eを実行 |
| `make install` | Release ビルドを `/Applications` へ配置 |
| `make stop` | 起動中の Koe を終了 |

テスト対象のCUJと実行条件は [テスト方針](docs/testing.md) にまとめています。

### 初回に必要な許可

1. **マイク** — 音声認識に使用します。
2. **アクセシビリティ** — ホットキーの監視とテキスト挿入に使用します。

### アクセシビリティの許可が毎回外れるとき

有効なApple Development証明書がKeychainにあれば、buildはそれを優先して使います。macOS ShortcutsのApp Intentを実行するには、Apple DevelopmentまたはDeveloper IDによる検証可能な署名が必要です。

Apple Development証明書がない環境では、ad-hoc署名より許可を維持しやすい固定の自己署名証明書を作れます。自己署名ではShortcutsのApp Intentは実行できません。

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

音声入力のホットキーと長押し閾値に加え、ライフログの記録開始・停止とミニウィンドウ表示切り替えのホットキーも設定画面で変更できます。
macOSのショートカットAppには「ライフログを開始」「ライフログを終了」に加え、日別ライフログと未実施TODOをコピー／ファイル化するアクションを公開します。予定・発話・メモを時系列で区別できるテキストにし、LLMやRaycastなど次の処理へ渡せます。

日別の書き出しでは日付と、予定・発話・メモ・要約・その日に作成・完了したTODOを個別に選べます。日付を省略すると実行時点の今日を使います。「ライフログをファイルにする」では出力先フォルダとファイル名を指定でき、既定の `lifelog-{{date}}.md` は `lifelog-20260830.md` のように展開されます。同じ日に再実行した場合は同名ファイルを最新内容で置き換えます。「未実施TODOをすべてコピー／ファイルにする」は日別とは独立したアクションです。

平日17:30に自動保存する場合は、ショートカットAppのオートメーションで「ライフログを終了」→「ライフログをファイルにする」の順に並べます。終了アクションは最終文字起こしと要約の完了を待つため、追加の待機アクションは不要です。

出力先を空欄にして、後続の「ファイルを保存」アクションへ渡す構成も使えます。ただし日付入りの名前にはShortcuts側で日付の整形とファイル名設定が別途必要になるため、定期保存ではKoeの出力先フォルダと `{{date}}` を使う構成が最短です。

## CLI / MCP

より細かい自動化向けに、同じDB・エクスポート定義を使うCLIとstdio MCPサーバーがあります。

Koeの「設定 > 連携」からCLIとAgent Skillをインストールできます。CLIは`~/.local/bin/koe`からKoe.app内の実体へリンクするため、PATHやシェル設定を書き換えず、アプリの更新と同時に更新されます。Agent Skillは`~/.agents/skills/koe`へ配置し、Claudeからも同じ内容を参照します。

```sh
koe export day --date 2026-08-29 --include speech,memos,summary
koe todo list
koe search "レセコン"
koe prompt get summary
```

`/Applications/Koe.app/Contents/Helpers/koe-mcp` は標準入出力のMCPサーバーです。`life_log_export`、`life_log_search`、`todo_*`、`prompt_get`、`prompt_set`を公開します。TODOやプロンプトの変更は起動中のKoeにも通知されます。MCPクライアントにはこの実行ファイルの絶対パスをcommandとして登録してください。

開発中にCLIとMCPだけを組み立てる場合は`make tools`を使います。

## 文章の仕上げ

- **このMac内** — 既定のApple Foundation Modelsに加え、ローカルで起動したOllamaまたはLM Studioを選べます。文字データを外部サービスへ送りません。
- **クラウド** — OpenAI、Claude、Gemini、Groqを選べます。利用者が選んだ場合だけ、口述の文字起こしと指示、またはライフログ対象日の全発話・メモ・予定を選択先へ送ります。録音音声は送りません。APIキーはmacOS Keychainに保存します。

どの方式でも、整形に失敗した場合は生の文字起こしを挿入します。語彙の自動提案は常にオンデバイスで実行し、過去の履歴を外部LLMへ送りません。

## 構成

```text
Sources/KoeKit/
├── Domain/        セッション状態、モード、整形ルール、語彙
├── Engines/       SpeechAnalyzer、WhisperKit、Foundation Models、クラウド／ローカルLLM
├── System/        ホットキー、録音、挿入、Keychain、macOS 統合
├── Persistence/   GRDB / SQLite による履歴・設定データ
├── Analysis/      オンデバイスの語彙候補分析
├── App/           状態機械の駆動と依存関係の組み立て
└── UI/            メニューバー、HUD、設定、履歴
```

中心となる不変条件は「発話を失わない」ことです。STT 確定後の文字起こしを先に永続化してから整形・挿入へ進み、整形失敗時は生テキストへ、挿入失敗時はクリップボードへ退避します。ライフログでは30秒ごとの復旧用音声を保存しながら入力signalから発話区間を切り出し、適応的な無音境界で後追い認識します。入力障害時は保存済み音声から再開し、利用者が記録を有効にしている間は自動再接続します。TODOはLLMの提案をそのまま確定せず、利用者が編集して採用または棄却します。

構造化データは起動時に `~/Library/Application Support/Koe/Backups/` へSQLiteスナップショットとして保存します。未適用のDBマイグレーションがある場合は変更前に必ず作成し、通常時は1日1回、直近7世代を保持します。
復元が必要な場合は、Koeを停止して元DBを退避してから [バックアップと復旧](docs/recovery.md) の手順を実行します。

## License

[MIT License](LICENSE)
