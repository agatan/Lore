# Day export

From the life-log window the user opens 書き出す for the selected day. A sheet shows five include toggles (予定, 発話, 音声入力, メモ, AIノート) with counts and a live Markdown preview. AIノート is off by default. The user can copy the Markdown or save it to a file.

## Sub-features

- `export-open` opens and closes the sheet.
- `export-preview` preview lists the selected kinds in time order under `## タイムライン` (utterances less than 90 s apart merge into one 発話 line), then the AI notes in their own `## AIが生成したノート` section. The preview stops after 4,000 characters; copy and save use the full text.
- `export-toggle` toggling a kind removes or restores its lines in the preview.
- `export-copy` copies Markdown to the clipboard.
- `export-save` saves the Markdown through a save panel.

## How to get to it (user POV)

- Toolbar share button on ライフログ (`life-log.export-day`).

## Driving it with lore-verify

Preconditions: `$V launch --demo`.

- **Open.** Run `$V press life-log.export-day && $V wait export.sheet && $V expect export.preview "予定** プロダクト朝会" && $V shot export`. Match the `予定**` prefix: the demo AI note's heading also contains プロダクト朝会.
- **Toggle memo.** Run `$V expect export.preview "オンボーディングは3つの機能を順番に紹介する" && $V press export.include.memo && $V expect export.preview "オンボーディングは3つの機能を順番に紹介する" --not && $V expect export.preview "プロダクト朝会"`. Pressing again restores the line.
- **Toggle voice input.** Run `$V press export.include.voice-input && $V expect export.preview "レビューで確認したい観点" --not`.
- **AI notes.** Run `$V expect export.preview "## AIが生成したノート" --not && $V press export.include.ai-notes && $V expect export.preview "検索とエクスポートの次に何を見せるか"`. The demo seeds one note on プロダクト朝会.
- **Other toggles.** The ids are `export.include.calendar` and `export.include.speech`. Use `$V value export.include.memo` to read the toggle state (the value text is localized).
- **Close.** Run `$V press export.close && $V absent export.sheet`.

## Gotchas

- The copy button overwrites the user's real clipboard. Ask before you drive it, and read the result back with `pbpaste`.
- The copy and save buttons have no ids. The save button opens an NSSavePanel that has no stable ids, and a successful save closes the sheet. If you must prove it, save into `build/verify/evidence/<run>/` and verify that the file exists. Otherwise report it as unverified.
- The sheet's own labels are Japanese even when the rest of the UI follows another persisted language. Report this mismatch if the work is about localization.
- `shot` captures the sheet as its own window (`<name>-0.png`).
