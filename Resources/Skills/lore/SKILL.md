---
name: lore
description: Read, search, and export the user's Lore life log (speech, dictation, memos, calendar) through the local lore CLI (read-only) — for example to review a day or week, summarize it, extract tasks, or turn rough voice memos into clean notes for another app.
---

# Lore

Use the `lore` CLI as the supported interface to the user's Lore life log. Run `lore help` for the authoritative command list. Lore records, and when the user turns on Life Log AI it also writes short notes for calendar events. Other summaries, task lists, and reviews are your job, built from what these commands return.

## Find days with records

List days that have any speech, dictation, memo, or calendar event, with per-kind counts and spoken seconds (JSON). Defaults to the last 30 days:

```sh
lore days --from 2026-08-01 --to 2026-08-31
```

## Read a period as structured entries

Get time-ordered entries (JSON) for up to 31 days, inclusive. Each entry has `id`, `kind` (`event`, `utterance`, `dictation`, `memo`), `day`, `start`, optional `end`, and `text`; events also have `title`, `calendar`, and `allDay`. Select any of `calendar,speech,voice-input,memos` (default: all):

```sh
lore range --from 2026-08-25 --to 2026-08-29 --include speech,memos
```

## Search

Search Japanese text across life-log speech, dictation, and memos:

```sh
lore search "検索語" --limit 20
```

## Export one day as Markdown

Omit `--date` for today:

```sh
lore export day --date 2026-08-29 --include calendar,speech,voice-input,memos
```

Add `--clipboard` to copy, or `--output <path>` to create a file. Confirm the destination before creating or replacing a file.

## AI notes for events

If the user turned on Life Log AI, Lore stores notes for calendar events (decisions, action items, open questions). Read them as JSON for up to 31 days (default: today). Every note has `generated: true`, the `provider` and `model`, and `stale` (non-empty when the event changed or a source was deleted). Each item lists its `sources` (`u-<utterance id>`, `m-<memo id>`). Treat the notes as AI output, not as the user's words, and check them against the sources when it matters. Lore records only the user's microphone, so the notes never cover what other meeting participants said.

```sh
lore notes --from 2026-08-25 --to 2026-08-29
```

`lore export day --include ai-notes` adds the notes to a day export. They are left out unless named.

## Rough memos → another app

Lore memos are quick, rough voice or text notes. To clean them up or move them into the user's note-taking or task app, read them with `lore range --from ... --include memos`, rewrite them, and write the result with that app's own tool. Lore has no write-back command.

The CLI uses Lore's local database and settings, sends nothing over the network, and never modifies Lore data. It does not require direct access to files under Lore's Application Support directory.
