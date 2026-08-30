# バックアップと復旧

Koeは構造化データを `~/Library/Application Support/Koe/Backups/` に保存します。`pre-migration-*.sqlite` はDB変更直前、`daily-*.sqlite` はその日の初回起動時のスナップショットです。直近7世代を保持します。ライフログ音声とKeychainのAPIキーはバックアップに含みません。

## 復旧手順

1. Koeを終了します。起動中のDBへ復元しないでください。
2. `~/Library/Application Support/Koe/` 全体を別の場所へコピーし、障害時点のデータを保全します。
3. `Backups/` から、障害直前のスナップショットを一つ選びます。バージョン更新直後の障害では `pre-migration-*.sqlite` を優先します。
4. 現在の `koe.sqlite`、`koe.sqlite-wal`、`koe.sqlite-shm` を削除せず別フォルダへ移動します。
5. 選んだスナップショットを `koe.sqlite` という名前でコピーします。
6. Koeを起動し、履歴、TODO、要約、設定済みモードを確認します。

復元したDBより後に作られた構造化データは戻りません。ライフログ音声は元の `LifeLog/` に残るため、DBとの対応が不明な場合は手順2のコピーを保持したまま原因を調査します。復旧確認前に「全データ削除」を実行するとバックアップも削除されます。
