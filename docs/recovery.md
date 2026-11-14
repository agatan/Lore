# バックアップと復旧

Loreは構造化データを `~/Library/Application Support/Lore/Backups/` に保存します。`pre-migration-*.sqlite` はDB変更直前、`daily-*.sqlite` はその日の初回起動時のスナップショットです。直近7世代を保持します。ライフログ音声とKeychainのAPIキーはバックアップに含みません。

## 旧名Koeからの移行

LoreはKoeから改名したアプリです。初回起動時に `~/Library/Application Support/Koe/` を `~/Library/Application Support/Lore/` へ移し、`koe.sqlite` を `lore.sqlite` へ改名します。移した後のバックアップも同じ `Backups/` に続けて保存され、Koe時代のスナップショットもそのまま復元に使えます（`lore.sqlite` という名前でコピーします）。

`Lore/` がすでにある状態で起動すると、Loreは `Koe/` を移さずに残し、menu barにその場所を表示します。Koe側のデータを使う場合は、Loreを終了し、`Lore/` を別の場所へ退避してから起動し直すと `Koe/` が移されます。移動に失敗した場合、LoreはDBを開かずに理由を表示し、`Koe/` はそのまま残ります。

## 復旧手順

1. Loreを終了します。起動中のDBへ復元しないでください。
2. `~/Library/Application Support/Lore/` 全体を別の場所へコピーし、障害時点のデータを保全します。
3. `Backups/` から、障害直前のスナップショットを一つ選びます。バージョン更新直後の障害では `pre-migration-*.sqlite` を優先します。
4. 現在の `lore.sqlite`、`lore.sqlite-wal`、`lore.sqlite-shm` を削除せず別フォルダへ移動します。
5. 選んだスナップショットを `lore.sqlite` という名前でコピーします。
6. Loreを起動し、履歴、ライフログ、設定済みモードを確認します。

復元したDBより後に作られた構造化データは戻りません。ライフログ音声は元の `LifeLog/` に残るため、DBとの対応が不明な場合は手順2のコピーを保持したまま原因を調査します。復旧確認前に「全データ削除」を実行するとバックアップも削除されます。

廃止したTODOと日次要約は、現在のLoreで起動するとmigrationで再び削除されます。それらを読み返す場合は、Loreへ復元せず `pre-migration-*.sqlite` を `sqlite3` などで直接開き、`life_log_todos` と `daily_summaries` を参照します。
