# Life-log day view

The main window opens on ライフログ. It shows one timeline for the selected day that mixes calendar events, utterances, dictations and memos, an inspector with the day's insights, AI notes and an hour map, and a search sheet that jumps to a matching item. An event that has AI notes shows the note card under its row.

## Sub-features

- `day-timeline` renders today's events, utterances, dictations and memos in time order.
- `day-inspector` shows insights (speech minutes and counts) and the hour map with event blocks.
- `day-event-jump` pressing an event block in the inspector scrolls the timeline to the item nearest that start time. Event rows are never highlighted; only utterance, dictation and memo rows are.
- `day-ai-notes` an event's AI note card (`life-log.event-notes-<event id>`) lists decisions, action items and open questions; pressing an item (`.item-<decisions|action_items|open_questions>-<n>`) jumps to and highlights its source row. The inspector lists the day's notes (`life-log.inspector-ai-note-<event id>`). ノートを作成 (`.generate`) appears only when Life Log AI is on and the event has ended, so the demo shows none.
- `day-last-time` a repeating event that has not ended shows 前回 (`life-log.event-last-time-<event id>`) with the date of its latest earlier recorded occurrence and up to three follow-ups (`.item-<n>`), in the main timeline and the mini window's pinned event. Pressing the date opens that day with its first utterance highlighted. The plain demo has no event in progress, so launch with `--demo --lore-demo-recurring-now`, which seeds 週次1on1 (`demo-event-weekly`) from 10 minutes ago with last week's utterance and note.
- `day-search` searches across days and opens a result in the timeline.
- `day-empty` an empty day still offers the capture control and export.

## How to get to it (user POV)

- Open Lore. The main window shows ライフログ. In the sidebar, choose ライフログ (`main.section.lifeLog`) when another section is active.
- Search: the toolbar magnifier (`life-log.search`).
- Inspector: toolbar toggle (`life-log.inspector-toggle`).

## Driving it with lore-verify

Preconditions: `$V launch --demo` (or `--empty` for `day-empty`).

- **Timeline.** Run `$V wait life-log.timeline-event-demo-event-1 && $V text "オンボーディングは3つの機能を順番に紹介する" && $V shot day`. The event row and the demo memo are visible.
- **Inspector.** Run `$V wait life-log.day-insights && $V wait life-log.day-map`. Run `$V press life-log.inspector-toggle && $V absent life-log.day-map` to hide the inspector, and press the toggle again to show it.
- **Event jump.** Run `$V press life-log.calendar-event-demo-event-2 && $V shot event-jump`. The screenshot shows the デザインレビュー row scrolled into view, not highlighted.
- **AI notes.** Run `$V wait life-log.event-notes-demo-event-1 && $V wait life-log.inspector-ai-note-demo-event-1 && $V absent life-log.event-notes-demo-event-1.generate && $V press life-log.event-notes-demo-event-1.item-decisions-0 && $V shot note-source-jump`. The first utterance (検索とエクスポートが揃ったので…) is highlighted.
- **Last time.** Run `$V launch --demo --lore-demo-recurring-now && $V wait life-log.event-last-time-demo-event-weekly && $V wait life-log.event-last-time-demo-event-weekly.item-2 && $V shot last-time && $V press life-log.event-last-time-demo-event-weekly && $V text "評価面談の資料は金曜までに共有します。" && $V shot last-time-jump`. Without AX (locked screen), `open -n -W build/LoreUITests.app --args --lore-screenshot-demo --lore-demo-recurring-now --lore-record-last-time --lore-record <dir>` records the jump to `<dir>/last-time.mp4`.
- **Search.** Run `$V press life-log.search && $V set life-log.search-input "オンボーディング" && $V wait life-log.search-result-memo-demo-memo-1 && $V shot search && $V press life-log.search-result-memo-demo-memo-1 && $V absent life-log.search-input && $V shot search-jump`. The sheet closes and the memo row is highlighted.
- **Cross-day search.** Search `日々の記録`, the utterance seeded on past days, then `$V tree search-result` and press one. The header no longer says 今日 and the memo composer is gone, because it shows only on today.
- **Empty day.** Run `$V launch --empty && $V wait life-log.capture-toggle && $V press life-log.export-day && $V wait export.sheet && $V press export.close`.

## Gotchas

- `life-log.capture-toggle` must never be pressed. It records the microphone into the real `LifeLog/` folder.
- Highlighting has no AX attribute. The proof of a jump is the screenshot plus the closed sheet.
- Inspector visibility persists in the `dev.agatan.Lore.UIE2E` defaults (`lifeLog.showsInspector`). A run that ends with it hidden makes the next `wait life-log.day-map` fail.
- Event rows have right-click items (`life-log.event.do-not-record`, `life-log.event.record`, `life-log.event.ai-exclusion`) that the harness cannot open. The pause menu (`life-log.pause`) appears only while recording, so it is not drivable either. Prove those with `swift test`.
- The note card's copy button writes the clipboard, and its delete removes the note. Do not press them unless the run is about them.
- `life-log.search` is a toolbar item. AX lists extra toolbar-customization actions on it, and `press` still works.
- Search results are ids of the form `life-log.search-result-<kind>-<id>`. Use `$V tree search-result` to list them.
