# Day export

From the life-log window the user opens 書き出す for the selected day. A sheet shows four include toggles (予定, 発話, 音声入力, メモ) with counts and a live Markdown preview. The user can copy the Markdown or save it to a file.

## Sub-features

- `export-open` opens and closes the sheet.
- `export-preview` preview lists the selected kinds in time order.
- `export-toggle` toggling a kind removes or restores its lines in the preview.
- `export-copy` copies Markdown to the clipboard.
- `export-save` saves the Markdown through a save panel.

## How to get to it (user POV)

- Toolbar share button on ライフログ (`life-log.export-day`).

## Driving it with lore-verify

Preconditions: `$V launch --demo`.

- **Open.** Run `$V press life-log.export-day && $V wait export.sheet && $V expect export.preview "プロダクト朝会" && $V shot export`.
- **Toggle memo.** Run `$V expect export.preview "オンボーディングは3つの機能を順番に紹介する" && $V press export.include.memo && $V expect export.preview "オンボーディングは3つの機能を順番に紹介する" --not && $V expect export.preview "プロダクト朝会"`. Pressing again restores the line.
- **Toggle voice input.** Run `$V press export.include.voice-input && $V expect export.preview "レビューで確認したい観点" --not`.
- **Other toggles.** The ids are `export.include.calendar` and `export.include.speech`. Use `$V value export.include.memo` to read the toggle state (the value text is localized).
- **Close.** Run `$V press export.close && $V absent export.sheet`.

## Gotchas

- The copy button overwrites the user's real clipboard. Ask before you drive it, and read the result back with `pbpaste`.
- The save button opens an NSSavePanel that has no stable ids. If you must prove it, save into `build/verify/evidence/<run>/` and verify that the file exists. Otherwise report it as unverified.
- The sheet's own labels are Japanese even when the rest of the UI follows another persisted language. Report this mismatch if the work is about localization.
- `shot` captures the sheet as its own window (`<name>-0.png`).
