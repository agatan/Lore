# Memos

The user types a quick text memo into the composer, either at the bottom of the main life-log window or in the floating mini window. The memo appears in the day timeline at the current time. A memo row can be edited or deleted in place.

## Sub-features

- `memo-add-main` adds a memo from the main window composer.
- `memo-add-mini` adds a memo from the mini window.
- `memo-edit` edits an existing memo in place.
- `memo-delete` deletes a memo from the main window timeline. The mini window can edit memos (`life-log-mini.memo-<id>.edit|.editor|.save|.cancel`) but has no delete.
- `memo-voice` records a voice memo (microphone, not drivable here).

## How to get to it (user POV)

- Main window: the composer bar at the bottom of ライフログ, shown only when today is selected. Type in the field (`life-log.memo-input`) and press send (`life-log.memo-send`), which is disabled while the field is blank. Return also sends.
- Mini window: Window menu > ライフログ ミニウィンドウ, or its global hotkey (disabled in the test bundle).
- Edit/delete: hover a memo row, then use the pencil (`life-log.memo-<id>.edit`) or the trash (`life-log.memo-<id>.delete`). Double-clicking the memo text also opens the editor.

## Driving it with lore-verify

Preconditions: `$V launch --demo`.

- **Add (main).** Run `$V shot before && $V set life-log.memo-input "verify memo" && $V press life-log.memo-send && $V expect life-log.memo-input "verify memo" --not && $V text "verify memo" && $V shot after`. Check that the field is cleared first: `text` also matches the field's own value. The memo is in the timeline and the field is cleared.
- **Persistence proof.** Run `$V press life-log.export-day && $V expect export.preview "verify memo" && $V press export.close`. This reads the memo back through the export query.
- **Add (mini).** Run `$V menu "ライフログ ミニウィンドウ" && $V wait life-log-mini.memo-input && $V set life-log-mini.memo-input "mini memo" && $V press life-log-mini.memo-send && $V expect life-log-mini.memo-input "mini memo" --not && $V text "mini memo" && $V shot mini && $V menu "ライフログ ミニウィンドウ" && $V absent life-log-mini.memo-input && $V hover "mini memo" --in lore.main`. The last step proves the memo also appears in the main window timeline. Opening the mini window switches the main window to today. The same menu item closes the mini window, which floats over the main timeline.
- **Edit.** Run `$V hover "オンボーディングは3つの機能を順番に紹介する" --in lore.main && $V press life-log.memo-demo-memo-1.edit && $V set life-log.memo-demo-memo-1.editor "edited memo" && $V press life-log.memo-demo-memo-1.save && $V absent life-log.memo-demo-memo-1.editor && $V text "edited memo" && $V shot edited`. The editor stays open when a save fails, so check that it closed before matching the text.
- **Delete.** Run `$V hover "マニュアルに日別の書き出し画面も載せる" --in lore.main && $V press life-log.memo-demo-memo-2.delete && $V absent life-log.memo-demo-memo-2.delete && $V shot deleted`. Then open export and `expect export.preview "マニュアルに日別の書き出し画面も載せる" --not`.

## Gotchas

- Edit and delete buttons stay invisible to AX (opacity 0) until the pointer hovers the row. `hover` moves the user's real cursor.
- The mini window lists the same memos and floats above the main window, covering the right part of the timeline. Close it before hovering main-window rows, and pass `--in lore.main` because the memo text exists in both windows.
- Delete runs immediately, without a confirmation dialog. That is safe here because the DB is in memory.
- `life-log.voice-memo` and `life-log-mini.voice-memo` start microphone capture. Do not press them.
- The mini window's title follows the persisted UI language, but `menu` matches the menu-bar title, which follows the system language (Japanese on this Mac).
