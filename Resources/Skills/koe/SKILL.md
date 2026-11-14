---
name: koe
description: Search and export the user's Koe life log (speech, dictation, memos, calendar) through the local koe CLI, for example to review a day, summarize it, or extract tasks.
---

# Koe

Use the `koe` CLI as the supported interface to the user's Koe life log. Run `koe help` for the authoritative command list. Koe only records; summaries, task lists, and reviews are your job, built from what these commands return.

## Read and export

Search Japanese text across life-log speech, dictation, and memos:

```sh
koe search "検索語" --limit 20
```

Export one day as readable Markdown. Omit `--date` for today. Select any of `calendar,speech,voice-input,memos`:

```sh
koe export day --date 2026-08-29 --include calendar,speech,voice-input,memos
```

Add `--clipboard` to copy, or `--output <path>` to create a file. Confirm the destination before creating or replacing a file.

The CLI uses Koe's local database and settings. It does not require direct access to files under Koe's Application Support directory.
