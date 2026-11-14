---
name: koe
description: Read, search, and export the user's Koe life log (speech, dictation, memos, calendar) through the local koe CLI (read-only) — for example to review a day or week, summarize it, extract tasks, or turn rough voice memos into clean notes for another app.
---

# Koe

Use the `koe` CLI as the supported interface to the user's Koe life log. Run `koe help` for the authoritative command list. Koe only records; summaries, task lists, and reviews are your job, built from what these commands return.

## Find days with records

List days that have any speech, dictation, memo, or calendar event, with per-kind counts and spoken seconds (JSON). Defaults to the last 30 days:

```sh
koe days --from 2026-08-01 --to 2026-08-31
```

## Read a period as structured entries

Get time-ordered entries (JSON) for up to 31 days, inclusive. Each entry has `id`, `kind` (`event`, `utterance`, `dictation`, `memo`), `day`, `start`, optional `end`, and `text`; events also have `title`, `calendar`, and `allDay`. Select any of `calendar,speech,voice-input,memos` (default: all):

```sh
koe range --from 2026-08-25 --to 2026-08-29 --include speech,memos
```

## Search

Search Japanese text across life-log speech, dictation, and memos:

```sh
koe search "検索語" --limit 20
```

## Export one day as Markdown

Omit `--date` for today:

```sh
koe export day --date 2026-08-29 --include calendar,speech,voice-input,memos
```

Add `--clipboard` to copy, or `--output <path>` to create a file. Confirm the destination before creating or replacing a file.

## Rough memos → another app

Koe memos are quick, rough voice or text notes. To clean them up or move them into the user's note-taking or task app, read them with `koe range --from ... --include memos`, rewrite them, and write the result with that app's own tool. Koe has no write-back command.

The CLI uses Koe's local database and settings, sends nothing over the network, and never modifies Koe data. It does not require direct access to files under Koe's Application Support directory.
