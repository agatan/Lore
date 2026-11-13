# テスト方針とCUJ

Koeの自動テストは二層に分けます。

- `make test`: ドメイン状態遷移、永続化、音声・LLM境界、書き出し形式を高速に検証する。
- `make ui-test`: 署名済みのKoeUITests.appをテスト専用インモリDBで起動し、macOS Accessibility APIで実画面を操作する。

UI E2Eは内部のView構造ではなく、利用者が認識する操作とアクセシビリティ識別子だけに依存します。`KoeUITests.app`は本番と別のbundle ID、process instance、UserDefaultsドメインを持ち、常にインメモリDBを開きます。global hotkeyと権限監視を起動しないため、起動中の本番Koeのプロセス、設定、利用者DBに干渉しません。E2E runnerが終了するのはテスト用bundle IDだけで、本番の`Koe.app`を渡すと実行を拒否します。

## 変更の進め方

外部挙動を変える開発は先に `spec.md` と `spec.html`、module境界・永続model・外部送信・削除経路・主要windowの責務を変える開発は先に `design.md` と `design.html` を更新してペアレビューします。合意前は実装へ進みません。挙動を変えないリファクタリングでは、作業前に `make test` を通して基準線を作り、変更後に同じテストと影響するUI E2Eを実行します。

テスト数や行カバレッジを目的にせず、発話回収、監査履歴、送信同意、バックアップ、削除範囲などの不変条件を検証します。到達不能な試作機能を削除するときは、その機能だけを固定していたテストも一緒に削除します。

## CUJ

### CUJ 1: 一日の記録を確認して持ち出す

1. Koeを開くとライフログが表示される。
2. 音声入力へ切り替え、履歴画面が表示される。
3. ライフログへ戻り、「この日を書き出す」を開く。
4. 予定・メモ・要約が日別の書き出しプレビューまで届く。
5. 含める項目を変更すると、選択状態とプレビューがともに更新される。

### CUJ 2: TODOを見直す

1. ライフログから「すべてのTODO」を開く。
2. TODOがない場合も、管理画面がウィンドウ全体へ自然に配置される。
3. 空状態が明示され、フィルター操作を妨げない。

### CUJ 3: AIの利用状況とモードを確認する

1. 設定の利用状況を開き、録音時間・API・ストレージの概要を確認できる。
2. 録音時間とAPI利用量は、音声入力とライフログを分けて日別に確認できる。
3. モードではDefaultと通常モードが表示され、廃止したAI Agentは存在しない。

今後リファクタリング前に追加する優先CUJは、ライフログ開始・停止と復旧、ミニウィンドウからのメモ、TODO案の確定・完了・復元、設定からの語彙更新です。マイクやOS権限を伴うものは、決定論的なUI E2Eと実機耐久試験を分けます。

## 実行

```sh
make test
make ui-test
```

`make ui-test`には実行元ターミナルのアクセシビリティ許可が必要です。失敗時は、システム設定の「プライバシーとセキュリティ > アクセシビリティ」で許可してから再実行します。

## 見た目の確認

Debug buildの`KoeUITests.app`を`--koe-screenshot-demo --koe-snapshot <dir>`で起動すると、main（ライフログ・音声入力）、全設定section、mini window、TODO管理windowを順に開き、各windowを`<dir>`へPNGで保存して終了します。自process内のwindowだけをScreenCaptureKitで撮るため、画面収録の許可は不要です。Release buildには含めません。

```sh
make ui-test-app
open -n -W build/KoeUITests.app --args --koe-screenshot-demo --koe-snapshot /tmp/koe-shots
```
