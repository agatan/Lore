# Settings

The Settings window (`lore.settings`) has a sidebar of eleven sections in four groups: 一般, プライバシー, AIプロバイダ | ライフログ, カレンダー, ライフログAI | 音声入力, モード, 語彙 | 同期, 連携. Users pick the color theme and language, check storage use, calendar access and never-record calendars, life-log hotkeys and schedule, Life Log AI, and modes there.

## Sub-features

- `settings-open` opens Settings from the app menu (⌘,) on 一般.
- `settings-nav` switches sections in the sidebar.
- `settings-privacy` shows storage use and the three deletion buttons.
- `settings-general` shows the color theme picker (`general.color-theme`) and the language picker (no id).
- `settings-calendar` shows the participation filter switch (`calendar.participating-only`, an AXCheckBox without a value), the refresh control for calendar events, and the 記録しないカレンダー toggles (`calendar.never-record.<title>`, value オン/オフ).
- `settings-life-log` shows the voice-memo hotkey and the schedule. Pausing life-log is not here: it is a menu on the capture control that appears only while recording.
- `settings-life-log-ai` shows Life Log AI: `life-log-ai.enabled`, `life-log-ai.provider` (read-only provider and model, with a button to AIプロバイダ), `life-log-ai.sent-fields`, `life-log-ai.requests-today`, `life-log-ai.trigger`, and the AIに送らないカレンダー toggles.
- `settings-modes` lists the built-in modes Default and Chat and no AI Agent mode.

## How to get to it (user POV)

- Menu bar: Lore > 設定… (⌘,) opens 一般. The gear in the menu-bar panel opens ライフログ (not drivable here).
- Sidebar rows `settings.section.<common|privacy|lifeLog|calendar|lifeLogAI|dictation|models|modes|vocabulary|sync|automation>`.

## Driving it with lore-verify

Preconditions: `$V launch --demo`.

- **Open from the menu.** Run `$V menu "設定…" && $V wait general.color-theme && $V shot settings`. `general.color-theme` proves the window opened on 一般.
- **Navigate.** Run `$V select settings.section.privacy && $V wait privacy.storage && $V shot privacy`. In demo data, `privacy.storage` shows a fixed 197 MB.
- **Calendar.** Run `$V select settings.section.calendar && $V wait calendar.settings.root && $V wait calendar.refresh`.
- **Life-log.** Run `$V select settings.section.lifeLog && $V wait life-log.voice-memo-hotkey && $V wait life-log.schedule.enabled`. The weekday and time controls (`life-log.schedule.weekday-<1…7>`, `life-log.schedule.start`, `life-log.schedule.end`) exist only while the schedule is on.
- **Life Log AI.** Run `$V select settings.section.lifeLogAI && $V wait life-log-ai.settings.root && $V wait life-log-ai.trigger && $V shot life-log-ai`.
- **Modes.** Run `$V select settings.section.modes && $V wait mode.row.builtin.default && $V wait mode.row.builtin.chat && $V absent mode.row.builtin.ai-agent`.
- **Shortcut launch.** For a quick look, `$V launch --demo --settings <privacy|calendar|life-log|life-log-ai|modes|ai-providers>` opens the window directly. This skips the user entry point, so it does not prove `settings-open`.

## Gotchas

- `settings.section.*` rows are static text. `press` fails on them, so use `select`.
- `privacy.delete-life-log` and `privacy.reset` delete real files and Keychain items even in the test bundle. You may press one to show its confirmation dialog, but never confirm it. `privacy.delete-history` is DB-only.
- AIプロバイダ (`aiProviders`, root `ai-providers.settings.root`) chooses the provider and model for formatting (`ai-providers.formatting.provider.<backend>`, `.model`, `.active`) and Life Log AI (`ai-providers.life-log-ai.…`) with the same form, and stores API keys per cloud provider (`ai-providers.api-key.<backend>`) in the real Keychain service `dev.agatan.Lore`. Do not save one.
- Choosing a cloud provider in ライフログAI opens a 送信を許可 alert. Confirming it persists the provider into the test defaults; cancel it unless the run is about that alert.
- Toggling `life-log.schedule.enabled` and other settings persists into `dev.agatan.Lore.UIE2E` defaults. Restore the setting or run `defaults delete dev.agatan.Lore.UIE2E` afterwards.
- Changing 一般 > 表示言語 relabels open windows. Any assertion on a localized label then breaks.
