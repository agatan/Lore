# Settings

The Settings window has a sidebar of sections: 一般, プライバシー, ライフログ, カレンダー, 音声入力, AI 整理, モード, 語彙, 同期, 連携. Users check storage use, calendar access, life-log hotkeys and schedule, and modes there.

## Sub-features

- `settings-open` opens Settings from the app menu (⌘,).
- `settings-nav` switches sections in the sidebar.
- `settings-privacy` shows storage use and the three deletion buttons.
- `settings-calendar` shows the refresh control for calendar events.
- `settings-life-log` shows the voice-memo hotkey and the schedule.
- `settings-modes` lists the built-in modes Default and Chat and no AI Agent mode.

## How to get to it (user POV)

- Menu bar: Lore > 設定… (⌘,), or the gear in the menu-bar panel.
- Sidebar rows `settings.section.<common|privacy|lifeLog|calendar|dictation|models|modes|vocabulary|sync|automation>`.

## Driving it with lore-verify

Preconditions: `$V launch --demo`.

- **Open from the menu.** Run `$V menu "設定…" && $V wait settings.section.privacy && $V shot settings`.
- **Navigate.** Run `$V select settings.section.privacy && $V wait privacy.storage && $V shot privacy`. In demo data, `privacy.storage` shows a fixed 197 MB.
- **Calendar.** Run `$V select settings.section.calendar && $V wait calendar.settings.root && $V wait calendar.refresh`.
- **Life-log.** Run `$V select settings.section.lifeLog && $V wait life-log.voice-memo-hotkey && $V wait life-log.schedule.enabled`.
- **Modes.** Run `$V select settings.section.modes && $V wait mode.row.builtin.default && $V wait mode.row.builtin.chat && $V absent mode.row.builtin.ai-agent`.
- **Shortcut launch.** For a quick look, `$V launch --demo --settings <privacy|calendar|life-log|modes|dictation>` opens the window directly. This skips the user entry point, so it does not prove `settings-open`.

## Gotchas

- `settings.section.*` rows are static text. `press` fails on them, so use `select`.
- `privacy.delete-life-log` and `privacy.reset` delete real files and Keychain items even in the test bundle. You may press one to show its confirmation dialog, but never confirm it. `privacy.delete-history` is DB-only.
- AI 整理 (`models`) can store API keys in the real Keychain service `dev.agatan.Lore`. Do not save one.
- Toggling `life-log.schedule.enabled` and other settings persists into `dev.agatan.Lore.UIE2E` defaults. Restore the setting or run `defaults delete dev.agatan.Lore.UIE2E` afterwards.
- Changing 一般 > 表示言語 relabels open windows. Any assertion on a localized label then breaks.
