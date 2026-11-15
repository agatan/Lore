# Lore verification map

This directory is the maintained source for verifying Lore's user-facing behavior. Read the index, then use the matching feature file as the recipe. The harness is `.claude/skills/verify/scripts/lore-verify` (`V` below). Its commands are documented in `../SKILL.md`.

## Baseline preconditions

- `$V build` succeeded after your last source change and `$V doctor` prints no `FAIL`.
- No other `LoreUITests` instance is running. `launch` refuses to start when one is.
- Start each journey from a fresh `$V launch --demo` (demo day = today, Japanese demo data) unless the file says `--empty`.
- The demo day contains these items. Events: `demo-event-1` プロダクト朝会 09:30, `demo-event-2` デザインレビュー 13:00, `demo-event-3` 次のリリース計画 16:00. One AI note `demo-note-1` on `demo-event-1`. Memos: `demo-memo-1` "オンボーディングは3つの機能を順番に紹介する" 11:06, `demo-memo-2` "マニュアルに日別の書き出し画面も載せる" 15:20. Five utterances. Dictation `demo-dictation-1`: raw "レビューで確認したい観点を三つに整理する", formatted "レビューで確認したい観点を3つに整理する。".
- The UI language comes from the test bundle's persisted defaults, not from `--lang`. Run `defaults delete dev.agatan.Lore.UIE2E` to return to the system language.

## Driving conventions

- Target elements by accessibility id. Use exact text only for demo data and `menu` titles.
- Chain the steps with `&&`. Use `expect`/`text`/`wait` instead of `sleep`.
- Never press the capture toggle, never confirm a privacy deletion, and never save API keys. These actions reach the real `~/Library/Application Support/Lore` or the real Keychain (see SKILL.md).
- `$V stop` after every journey, pass or fail.

## Proof and skip reporting

- Capture `shot` before and after the action, plus `expect`/`value` on the resulting state. `transcript.log` in the run dir is the step record.
- The DB is in memory. Prove a write by reading it through a second surface (timeline → export preview, timeline → search).
- An entry point you could not reach is reported as unverified, with the attempted command and the reason. Do not substitute another entry point.

## Features

- [Life-log day view](./life-log-day.md): timeline, calendar events, AI notes, inspector, search, day navigation.
- [Memos](./memos.md): add from the main window and the mini window, edit, delete.
- [Day export](./day-export.md): export sheet, include toggles (including AI notes), preview.
- [Dictation history](./dictation-history.md): 音声入力 section listing formatted and raw text.
- [Settings](./settings.md): opening Settings, section navigation, general, privacy storage, calendar, life-log hotkeys, Life Log AI, modes.
- [Onboarding](./onboarding.md): first-run guide, permissions and the dictation trial.
- [MCP](./mcp.md): automation surface against the real DB; guard against pending migrations first.
