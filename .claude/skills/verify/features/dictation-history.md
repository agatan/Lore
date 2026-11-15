# Dictation history

The 音声入力 section of the main window lists past dictations. Each list row shows the inserted text (formatted, or raw when formatting did not run). The detail pane for the selected entry, which starts on the first entry, shows the formatted text, the raw transcript, the engines, a time breakdown and the prompt used. Dictation itself (right-⌥ hotkey and microphone) is not drivable in the test bundle. This file covers the history the user reviews afterwards.

## Sub-features

- `history-open` switches the main window to 音声入力.
- `history-entry` shows the formatted text in the list and the raw text in the detail pane.
- `history-empty` with no records, the list shows 履歴がありません.
- `history-back` returns to ライフログ.

## How to get to it (user POV)

- Main window sidebar: 音声入力 (`main.section.history`).

## Driving it with lore-verify

Preconditions: `$V launch --demo`.

- **Open.** Run `$V press main.section.history && $V wait history.root && $V text "レビューで確認したい観点を3つに整理する。" && $V text "レビューで確認したい観点を三つに整理する" && $V shot history`. The raw text appears only in the detail pane, so that step proves the detail rendered.
- **Empty.** Run `$V launch --empty && $V press main.section.history && $V wait history.root && $V text "履歴がありません"` (chrome text follows the persisted UI language).
- **Back.** Run `$V press main.section.lifeLog && $V wait life-log.capture-toggle`.

## Gotchas

- Recording a dictation needs the global hotkey monitor, which the test bundle never starts, and a microphone. Prove dictation logic with `swift test` (DomainTests, FormattingBackendTests).
- History rows have no per-row ids. Assert on the demo text.
- The search field and the detail's コピー and この履歴を削除 buttons have no ids. コピー writes the user's clipboard. Delete runs without confirmation (DB-only).
