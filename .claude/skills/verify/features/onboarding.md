# Onboarding

On first run, the main window shows a three-step guide instead of ライフログ: permissions (welcome), a dictation trial, then a ready screen that offers to start life-log or finish later. The trial shows the raw and formatted text of the user's first dictation next to each other.

## Sub-features

- `onboarding-welcome` lists the microphone and Accessibility permissions and continues with 次へ (`onboarding.next`).
- `onboarding-try` shows the hotkey (`onboarding.try.hotkey`) and a practice field (`onboarding.try.field`). A missing permission shows a blocker (`onboarding.try.blocker.microphone`, `onboarding.try.blocker.accessibility`) with a way back (`onboarding.try.back-to-permissions`). After a dictation, `onboarding.try.raw` and `onboarding.try.formatted` show both texts and `onboarding.try.next` continues. スキップ (`onboarding.try.skip`) skips the trial.
- `onboarding-ready` offers ライフログを始める (`onboarding.start-life-log`) and あとで (`onboarding.finish`).

## How to get to it (user POV)

- The first launch of Lore, before onboarding is completed. The test bundle never shows it on its own, even with `--empty`.

## Driving it with lore-verify

Preconditions: `$V launch --demo --lore-screenshot-onboarding --ready onboarding.next`. The extra argument passes through `launch` unchanged.

- **Skip path.** Run `$V shot welcome && $V press onboarding.next && $V wait onboarding.try.field && $V shot try`. If `onboarding.try.blocker.microphone` or `onboarding.try.blocker.accessibility` exists, press `onboarding.try.back-to-permissions` and then `onboarding.next`. Then run `$V press onboarding.try.skip && $V press onboarding.finish && $V wait life-log.capture-toggle && $V absent onboarding.next`.

## Gotchas

- The trial itself needs the right-⌥ global hotkey, which the test bundle never starts. `onboarding.try.raw` and `onboarding.try.formatted` cannot be reached here. `make ui-test` CUJ 4 covers the same skip path.
- Never press `onboarding.start-life-log`. It asks the audio-storage question only if it was never answered in the test defaults; otherwise it starts real life-log capture into the real `LifeLog/` folder.
