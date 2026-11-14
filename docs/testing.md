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

1. Koeを開くとライフログが表示され、TODOと要約の表示はない。
2. 予定一覧と検索から該当項目へ移動できる。
3. 音声入力へ切り替え、履歴画面が表示される。
4. ライフログへ戻り、「この日を書き出す」を開く。
5. 予定・メモが日別の書き出しプレビューまで届く。
6. 含める項目を変更すると、選択状態とプレビューがともに更新される。

### CUJ 2: 記録がない状態で操作する

1. 空のデータで起動しても、記録の開始操作が表示される。
2. 「この日を書き出す」を開いて閉じられる。

### CUJ 3: 設定を確認する

1. プライバシー設定でこのMacの使用量を確認できる。
2. カレンダー設定で予定の再取得操作を確認できる。
3. ライフログ設定でボイスメモのホットキーを確認できる。
4. モードではDefaultと通常モードが表示され、廃止したAI Agentは存在しない。

今後リファクタリング前に追加する優先CUJは、ライフログ開始・停止と復旧、ミニウィンドウからのメモ、設定からの語彙更新です。マイクやOS権限を伴うものは、決定論的なUI E2Eと実機耐久試験を分けます。

## 実行

```sh
make test
make ui-test
```

`make ui-test`には実行元ターミナルのアクセシビリティ許可が必要です。失敗時は、システム設定の「プライバシーとセキュリティ > アクセシビリティ」で許可してから再実行します。

## 見た目の確認

Debug buildの`KoeUITests.app`を`--koe-screenshot-demo --koe-snapshot <dir>`で起動すると、main（ライフログ・音声入力）、全設定section、mini windowを順に開き、各windowを`<dir>`へPNGで保存します。続けて、壁紙を模した背景の上に置いたHUDの各段階（録音開始、逐次text、整形中、完了、整形skip）とmenu bar panel、明暗のmenu barに並べた全状態のmenu barアイコン（`menu-bar-icons.png`）を保存して終了します。自process内のwindowだけをScreenCaptureKitで撮るため、画面収録の許可は不要です。`--koe-snapshot-appearance dark`（または`light`）を足すと外観を固定して撮ります。Release buildには含めません。

```sh
make ui-test-app
open -n -W build/KoeUITests.app --args --koe-screenshot-demo --koe-snapshot /tmp/koe-shots --koe-snapshot-appearance dark
```
