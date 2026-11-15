# Backup and recovery

Lore saves structured data in `~/Library/Application Support/Lore/Backups/`. `pre-migration-*.sqlite` is a snapshot taken immediately before a database change, and `daily-*.sqlite` is the snapshot of the first launch of a day. The 7 newest are kept. Life Log audio and the API keys in the Keychain are not part of a backup.

## Migration from the old name Koe

Lore is the app that was renamed from Koe. On first launch it moves `~/Library/Application Support/Koe/` to `~/Library/Application Support/Lore/` and renames `koe.sqlite` to `lore.sqlite`. Later backups continue in the same `Backups/` folder, and snapshots from the Koe period can still be restored. Copy one under the name `lore.sqlite`.

If `Lore/` already exists at launch, Lore leaves `Koe/` in place and shows its location in the menu bar panel. To use the Koe data, quit Lore, move `Lore/` somewhere else, and launch again. Lore then moves `Koe/`. The Koe settings are copied only once, so they are not copied again on that launch. If the move fails, Lore does not open the database and shows the reason, and `Koe/` stays as it was.

## Recovery steps

1. Quit Lore. Do not restore into a database that is in use.
2. Copy the whole `~/Library/Application Support/Lore/` folder somewhere else to preserve the data at the time of the failure.
3. In `Backups/`, choose one snapshot from just before the failure. For a failure right after a version update, prefer `pre-migration-*.sqlite`.
4. Move the current `lore.sqlite` to another folder without deleting it, together with any `lore.sqlite-journal`, `lore.sqlite-wal`, or `lore.sqlite-shm` file that exists.
5. Copy the chosen snapshot under the name `lore.sqlite`.
6. Launch Lore and check the history, the Life Log, and your modes.

Structured data created after the restored snapshot does not come back. Life Log audio stays in the original `LifeLog/` folder. If its relation to the database is unclear, keep the copy from step 2 while you investigate. Running "Reset Lore…" before you confirm the recovery also deletes the backups.

To-do items and daily summaries were removed from Lore, and launching the current Lore deletes them again in the migration. To read them, do not restore into Lore. Open `pre-migration-*.sqlite` directly, for example with `sqlite3`, and read `life_log_todos` and `daily_summaries`. Topics are stored inside `daily_summaries`.
