---
name: koe
description: Read, search, and export the user's Koe life log (speech, dictation, memos, calendar) through the local koe CLI, and append memos back — for example to review a day or week, summarize it, or extract tasks.
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

## Write back a memo

Append a memo to the life log (for example a review or decisions the user asked you to keep). `--at` takes ISO8601 and defaults to now. Prints the new memo id. Ask before writing unless the user requested it:

```sh
koe memo add "週次レビュー: ..." --at 2026-08-29T18:00:00+09:00
```

The CLI uses Koe's local database and settings, sends nothing over the network, and only ever adds memos. It does not require direct access to files under Koe's Application Support directory.
