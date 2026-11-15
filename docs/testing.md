# Test policy and user journeys

Lore's automated tests have two layers.

- `make test` quickly verifies domain state transitions, persistence, the speech and LLM boundaries, sync, and the export format.
- `make ui-test` launches the signed `LoreUITests.app` on a test-only in-memory database and drives the real screens through the macOS Accessibility API.

The UI E2E depends only on operations that a user can perceive and on accessibility identifiers, not on the internal view structure. `LoreUITests.app` has a bundle ID, a process instance, and a UserDefaults domain different from production, and it always opens an in-memory database. It starts neither global hotkeys nor permission monitoring, so it does not interfere with the process, settings, or user database of a running production Lore. The E2E runner terminates only the test bundle ID and refuses to run when it is given the production `Lore.app`.

## How to make changes

A change to external behavior updates `spec.md` first. A change to module boundaries, the persisted model, data transmission, deletion paths, or the responsibilities of the main windows updates `design.md` first. Regenerate `spec.html` and `design.html` from the Markdown with `python3 Scripts/render-docs.py`. The updated documents count as approved, and implementation continues unless the user asks for a review pause, as [AGENTS.md](../AGENTS.md) states. For a refactoring that does not change behavior, pass `make test` first to set a baseline, then run the same tests and the affected UI E2E after the change.

The goal is neither the number of tests nor line coverage. Tests verify invariants: recovering speech, the audit history, consent to transmission, backups, and the scope of deletion. When an unreachable prototype feature is removed, the tests that only pinned that feature are removed with it.

## User journeys

### Journey 1: review a day and take it out

1. Opening Lore shows the Life Log in an active main window of at least 1680×960 pt, with the record button, the voice memo button, the inspector toggle, and the day map. No to-do or summary view exists.
2. Selecting an event in the day map moves the timeline to that event, and a search result moves to its memo.
3. Switching to Dictation shows the history screen.
4. Back in the Life Log, a memo typed in the main window appears in the timeline.
5. "Export" opens, and events and memos reach the day export preview.
6. Changing the included items updates both the selection state and the preview. Dictation is an independent item.

### Journey 2: operate with no records

1. With empty data, the record button is still shown.
2. "Export" opens and closes.

### Journey 3: check the settings

1. The Privacy settings show the storage used on this Mac.
2. The Calendar settings show the refresh action.
3. The Life Log settings show the voice memo hotkey.
4. Modes shows Default and Chat, and the removed AI Agent mode does not exist.
5. The Life Log AI settings show that it is off and that nothing is sent while it is off.

### Journey 4: read AI notes on an event

1. The demo data has one stored note for the first event. The timeline shows it under the event, marked as AI-generated with the provider. No request is made.
2. Selecting an item moves the timeline to its source utterance.
3. "Export" with "AI Notes" turned on shows the notes in the preview. It is off when the sheet opens.

### Journey 4: finish onboarding

1. With onboarding forced, "Next" leads to the try-dictation step, which shows the hotkey and the text field.
2. When the microphone or Accessibility permission is missing, the step names it, and the button goes back to the permissions.
3. Skipping and then choosing "Later" closes onboarding and shows the Life Log.
4. Skipping and then choosing "Start Life Log" closes onboarding and shows the audio storage consent.

The hotkey and microphone path of the try step needs a real machine with both permissions, so it stays out of the UI E2E.

The next journeys to add before a refactoring are Life Log start, stop, and recovery, a memo from the mini window, and a vocabulary update from Settings. For anything that involves the microphone or OS permissions, deterministic UI E2E and endurance tests on a real machine are kept separate.

## Running

```sh
make test
make ui-test
```

`make ui-test` needs the Accessibility permission for the terminal that runs it. On failure, allow it in System Settings under Privacy & Security > Accessibility and run again.

## Checking the look

Launching the debug build of `LoreUITests.app` with `--lore-screenshot-demo --lore-snapshot <dir>` opens the main window (Life Log and Dictation), every settings section, and the mini window in turn and saves each window to `<dir>` as PNG. It then saves each stage of the HUD on a wallpaper-like background (recording start, streaming text, formatting, done, formatting skipped), the menu bar panel, and the menu bar icon in every state on light and dark menu bars (`menu-bar-icons.png`), and quits. It captures only the windows of its own process with ScreenCaptureKit, so it needs no Screen Recording permission. Adding `--lore-screenshot-onboarding` shows onboarding as on a first launch instead and saves each step (`onboarding-welcome`, `onboarding-try`, `onboarding-try-done` with a sample recognized and formatted text, and `onboarding-ready`). The flag also marks onboarding as not done at launch, and with demo data also the Life Log audio consent, so the UI E2E can finish both from a first-launch state. Without `--lore-screenshot-demo`, a debug `Lore.app` launched with only `--lore-screenshot-onboarding` shows onboarding on the real database with the real hotkey, which is how to try the try-dictation step by hand. Adding `--lore-snapshot-appearance dark` (or `light`) fixes the appearance. The last capture is `main-life-log-paused`, the main window with the Life Log paused for 30 minutes. None of this is in release builds.

```sh
make ui-test-app
open -n -W build/LoreUITests.app --args --lore-screenshot-demo --lore-snapshot /tmp/lore-shots --lore-snapshot-appearance dark
```

Adding `--lore-demo-language en|ja|zh-Hans` switches the display language and the demo data text to that language (the default is Japanese). `--lore-record <dir>` records instead of taking screenshots. It plays a fixed script for dictation (until polished text lands in a message field) and for the Life Log (until spoken sentences line up on the timeline) and records only the windows of its own process as mp4. The script adds utterances to the demo database, so it launches only together with `--lore-screenshot-demo`.

`make lp-media` regenerates the landing page (`site/`) screenshots and videos per language into `site/assets/<language>/`. A recorded video contains the recording indicator that the system draws at the traffic light position, so `Scripts/patch-recording.swift` covers it with a still of the same window before downscaling. ScreenCaptureKit cannot start capturing while the screen is locked, so unlock the screen before running it. It also crops `event-notes.png` (the demo note under its event) and `paused.png` (the paused record bar) from the light main window captures.
