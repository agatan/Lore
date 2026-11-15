---
name: verify
description: Drive the real Lore macOS app (SwiftUI menu-bar app for dictation and life-log) through the macOS Accessibility API to prove a UI change works the way a user would see it. Launches the isolated LoreUITests.app on an in-memory demo database, presses/types by accessibility identifier, and captures screenshots, AX values and a transcript. Use after changing anything user-visible in Sources/LoreKit/UI or the flows behind it, when asked to "verify", "run the app", "screenshot", or to confirm a feature end to end. Also covers the read-only lore CLI.
---

# Verify Lore by driving the real app

Lore is a macOS 26 SwiftUI app (`Sources/LoreKit/UI`). You drive **`build/LoreUITests.app`**, a copy of the debug `Lore.app` with bundle ID `dev.agatan.Lore.UIE2E`. That bundle:

- always opens an **in-memory** database (seeded with Japanese demo data unless `--empty`), so the user's `lore.sqlite` is never opened;
- has its own process and UserDefaults domain (`dev.agatan.Lore.UIE2E`), so the user's running `Lore.app` is untouched;
- does not start the global hotkey monitor, the permission watcher, sync, or the life-log schedule.

Everything goes through one helper: `.claude/skills/verify/scripts/lore-verify` (zsh wrapper that compiles `scripts/LoreAX.swift` into `.build/verify/lore-ax` on first use or when the source changes). Run it from anywhere; it `cd`s to the repo root. Below, `V=.claude/skills/verify/scripts/lore-verify`.

## Isolation boundaries you must respect

The test bundle isolates the **database**, not the filesystem or Keychain. These paths still resolve to the real user's `~/Library/Application Support/Lore` and Keychain service `dev.agatan.Lore`:

| Never trigger in a verify run | What it really does |
|---|---|
| `life-log.capture-toggle` / `life-log-mini.capture-toggle` (start recording) | records the mic and writes audio chunks into the **real** `Lore/LifeLog/` folder, orphaned from the in-memory DB |
| `privacy.delete-life-log` then confirm | deletes the **real** `Lore/LifeLog/` audio folder |
| `privacy.reset` ("Loreを初期化…") then confirm | deletes real life-log audio, real Whisper models and **all Lore Keychain secrets (API keys)** |
| Saving an API key in Settings > AI整形 | writes into the real Keychain service |
| `onboarding.start-life-log` | starts life-log capture once the audio-storage question has been answered (same effect as the capture toggle) |
| Export sheet "コピー" | overwrites the user's clipboard (ask first) |

`privacy.delete-history` is DB-only and safe. Pressing these buttons only opens a confirmation dialog, which is safe to show. Do not confirm it. If a change needs one of the forbidden paths proven, cover it with `swift test` and tell the user that the live proof needs their own machine state.

The `lore` CLI and `lore-mcp` ignore `HOME` and always open the **real** `~/Library/Application Support/Lore/lore.sqlite`. They also may write that day's backup on open. Use only their read-only commands (see `features/cli.md`).

## Launch

```sh
V=.claude/skills/verify/scripts/lore-verify
$V build                 # make ui-test-app (swift build + bundle + sign) and compile the driver; ~5 s incremental
$V launch --demo         # demo data, main window on ライフログ; waits until life-log.capture-toggle exists
```

`launch` options (combine freely):

| Option | App argument | Effect |
|---|---|---|
| `--demo` | `--lore-screenshot-demo` | today's demo events, utterances, memos, one dictation (all Japanese copy by default) |
| `--empty` | `--lore-ui-test-empty` | in-memory DB with no records (still has built-in modes) |
| `--settings <privacy\|calendar\|life-log\|life-log-ai\|modes\|dictation>` | `--lore-ui-test-settings-<x>` | opens the Settings window on that section instead of the main window; `dictation` opens AI整形 (`models`), not 音声入力; ready = `settings.section.privacy` |
| `--lang <en\|ja\|zh-Hans>` | `--lore-demo-language <x>` | language of the demo **data** only; the UI language is the persisted setting (see Gotchas) |
| `--ready <id>` | — | override the ready identifier |
| any other argument | passed through | e.g. `--lore-screenshot-onboarding --ready onboarding.next` shows onboarding (see `features/onboarding.md`) |

Ready means the identifier became visible in the AX tree after boot. `launch` prints the run directory, which receives the evidence. It refuses to start when another `LoreUITests` instance is running (for example `make ui-test` or another agent). Wait for that run to finish instead of killing it.

Teardown: `$V stop` (see Cleanup).

## Doctor

```sh
$V doctor
```

This check is read-only. It checks that the test bundle exists, that the terminal has the Accessibility permission (required) and the Screen Recording permission (only for `shot`), that the screen is unlocked, and that the build is newer than every file in `Sources/`. With an instance recorded, it also checks that the instance is alive and is the only `LoreUITests` process, that its AX windows resolve as windows, and it lists the window ids. Run it first whenever a step times out or behaves strangely. When the build is stale, run `$V build` and relaunch. When the screen is locked, `launch` refuses to start: on the lock screen AX resolves every window to the application element (only the menu bar is visible), although `shot` still captures the windows. Nothing can be driven until the user unlocks the Mac.

## Drive

All targets are SwiftUI `.accessibilityIdentifier`s (grep `accessibilityIdentifier(` in `Sources/LoreKit/UI` for the full list). Default timeout is 8 s. Override it with `LORE_VERIFY_TIMEOUT=20 $V ...`. Every command exits non-zero on failure, so chain steps with `&&`.

| Command | Does |
|---|---|
| `$V tree [substring]` | dump AX elements (`role id title value actions`), optionally filtered; use it to discover ids |
| `$V wait <id>` | wait until an element with that id exists |
| `$V absent <id>` | assert it does not exist now |
| `$V press <id>` | AXPress a button/checkbox/segment; **fails** if the element has no AXPress (static text silently ignores presses) |
| `$V select <id>` | select the enclosing list row, used for sidebar rows such as `settings.section.<x>` |
| `$V menu "<title>"` | press a menu-bar item by its exact title, e.g. `設定…`, `ライフログ ミニウィンドウ` (titles are localized; ids are all `menuAction`) |
| `$V hover <id-or-exact-text> [--in <window id\|title>]` | move the **real pointer** to the element's center so hover-only controls appear (memo edit/delete). It fails when the text matches in several windows (main `lore.main`, mini `lore.life-log-mini`; pass `--in`) or when another window covers the point. It moves the user's cursor, so use it only when needed |
| `$V set <id> "<text>"` | set a text field/editor value (SwiftUI bindings update) |
| `$V text "<exact text>"` | wait until some element's title or value equals the text exactly |
| `$V expect <id> "<substring>" [--not]` | wait until the element's value contains (or lacks) the substring |
| `$V value <id>` | print the value and save it as `value-<id>.txt` in the run dir |
| `$V shot <name>` | screenshot every on-screen window of the instance into `<run>/<name>[-n].png` |

A minimal journey (memo reaches the day export):

```sh
$V launch --demo \
 && $V set life-log.memo-input "verify memo" && $V press life-log.memo-send \
 && $V text "verify memo" && $V shot memo-added \
 && $V press life-log.export-day && $V wait export.sheet \
 && $V expect export.preview "verify memo" && $V shot export \
 && $V press export.include.memo && $V expect export.preview "verify memo" --not
$V stop
```

The feature map in `features/` lists every journey with real ids. Read the matching file before driving a feature.

You cannot drive these in the test bundle: dictation recording (needs the right-⌥ global hotkey, which is disabled there, and a microphone), life-log capture (forbidden above), the menu-bar status item panel (it lives in SystemUIServer's menu extras), App Intents, and Sync (needs a shared folder and a second Mac). For appearance-only checks of the HUD, menu bar panel and mini window, use the built-in snapshotter. It captures its own windows and needs no Screen Recording permission:

```sh
open -n -W build/LoreUITests.app --args --lore-screenshot-demo --lore-snapshot build/verify/evidence/snapshots --lore-snapshot-appearance light
```

## Evidence

- Location: `build/verify/evidence/<yyyyMMdd-HHmmss>/` per `launch`. It holds `transcript.log` (every command with a timestamp and ok/FAIL), `*.png`, and `value-*.txt`. `$V stop` keeps it. `make clean` deletes it, so copy anything you need to keep.
- Proof standards:
  - Go through the user path: identifiers the user clicks or types into. Do not use launch flags that skip the UI. Prefer `menu "設定…"` + `select settings.section.<x>` over `--settings <x>` when the entry point itself is part of the proof.
  - Capture before and after: `shot` before the action, the action, then `shot` and `expect`/`value` on the resulting state.
  - Prove side effects through a second surface. The database is in memory, so show that a write persisted by finding it somewhere else: a new memo appears in the export preview, and a search finds it.
  - Report failures as failures, with the `FAIL` line from `transcript.log` and a `tree` excerpt. Never loosen a journey until it passes.
- Look at the PNGs (Read them) before claiming a visual result. The text in the window follows the persisted UI language, so check the language too.

## Cleanup

```sh
$V stop
```

This command terminates only the pid that `launch` recorded in `build/verify/pid`, after it confirms the pid still belongs to `dev.agatan.Lore.UIE2E`. Never `pkill Lore` or `make stop`, because both kill the user's real Lore. Run `stop` after every failed attempt as well. A stranded instance blocks the next `launch`.

The settings that a run changes persist in the `dev.agatan.Lore.UIE2E` defaults domain, which belongs only to the test bundle. If a run changed settings (language, modes, toggles) and you want the next run to start clean, run `defaults delete dev.agatan.Lore.UIE2E`. This command never touches the real `dev.agatan.Lore` domain.

## Gotchas

- **The UI language persists between runs and is not set by `--lang`.** `applicationLanguage` is stored in the test bundle's defaults. `make lp-media` (the snapshotter and recorder) and Settings > 一般 write it. After an lp-media run it is often `zh-Hans`: the sidebar, inspector and timeline durations render in Chinese, while the demo data, the export sheet and the menu bar stay Japanese. Run `defaults delete dev.agatan.Lore.UIE2E` before launching to return to the system language. Prefer assertions on ids and demo-data strings over chrome labels.
- `make ui-test` force-terminates every `LoreUITests` instance. Do not run it while you drive one.
- The main window opens at 1680×960 or larger. `shot` captures sheets as separate windows (`<name>-0.png` is the sheet with its parent behind it).
- The Settings sidebar rows (`settings.section.*`) are static text. Use `select`, not `press`.
- Timeline rows keep their edit and delete buttons at opacity 0 until hovered, and AX does not see them until then. `hover` the memo text first.

## Helpers

- `scripts/lore-verify` is the entry point that every section above uses (`build`, `launch`, `doctor`, `stop`, and all drive commands).
- `scripts/LoreAX.swift` is the driver source. Change it here; the wrapper recompiles it automatically.
- The repository's own CUJ suite, `Scripts/LoreUIE2E.swift` (`make ui-test`), is a fixed regression run. Use this skill for ad-hoc proofs and `make ui-test` for the AGENTS.md validation gate.
