# Dictation history

The 音声入力 section of the main window lists past dictations. Each entry shows the formatted text that was inserted and the raw transcript. Dictation itself (right-⌥ hotkey and microphone) is not drivable in the test bundle. This file covers the history the user reviews afterwards.

## Sub-features

- `history-open` switches the main window to 音声入力.
- `history-entry` shows the formatted and raw text for each dictation.
- `history-back` returns to ライフログ.

## How to get to it (user POV)

- Main window sidebar: 音声入力 (`main.section.history`).

## Driving it with lore-verify

Preconditions: `$V launch --demo`.

- **Open.** Run `$V press main.section.history && $V wait history.root && $V text "レビューで確認したい観点を3つに整理する。" && $V text "レビューで確認したい観点を三つに整理する" && $V shot history`. Both the formatted and the raw text are visible.
- **Back.** Run `$V press main.section.lifeLog && $V wait life-log.capture-toggle`.

## Gotchas

- Recording a dictation needs the global hotkey monitor, which the test bundle never starts, and a microphone. Prove dictation logic with `swift test` (DomainTests, FormattingBackendTests).
- History rows have no per-row ids. Assert on the demo text.
