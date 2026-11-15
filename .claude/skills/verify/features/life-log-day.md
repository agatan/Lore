# Life-log day view

The main window opens on ライフログ. It shows one timeline for the selected day that mixes calendar events, utterances, dictations and memos, an inspector with the day's insights and an hour map, and a search sheet that jumps to a matching item.

## Sub-features

- `day-timeline` renders today's events, utterances, dictations and memos in time order.
- `day-inspector` shows insights (speech minutes and counts) and the hour map with event blocks.
- `day-event-jump` pressing an event block in the inspector scrolls to and highlights that event in the timeline.
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
- **Event jump.** Run `$V press life-log.calendar-event-demo-event-2 && $V wait life-log.timeline-event-demo-event-2 && $V shot event-jump`. The screenshot shows the デザインレビュー row highlighted in the timeline.
- **Search.** Run `$V press life-log.search && $V set life-log.search-input "オンボーディング" && $V wait life-log.search-result-memo-demo-memo-1 && $V shot search && $V press life-log.search-result-memo-demo-memo-1 && $V absent life-log.search-input && $V shot search-jump`. The sheet closes and the memo row is highlighted.
- **Empty day.** Run `$V launch --empty && $V wait life-log.capture-toggle && $V press life-log.export-day && $V wait export.sheet && $V press export.close`.

## Gotchas

- `life-log.capture-toggle` must never be pressed. It records the microphone into the real `LifeLog/` folder.
- Highlighting has no AX attribute. The proof of a jump is the screenshot plus the closed sheet.
- `life-log.search` is a toolbar item. AX lists extra toolbar-customization actions on it, and `press` still works.
- Search results are ids of the form `life-log.search-result-<kind>-<id>`. Use `$V tree search-result` to list them.
