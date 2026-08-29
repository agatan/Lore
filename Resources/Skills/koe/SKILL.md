---
name: koe
description: Search, export, and manage Koe life-log data and TODOs, or inspect and update Koe summary and TODO prompts through the local koe CLI.
---

# Koe

Use the `koe` CLI as the supported interface to the user's Koe life log. Run `koe help` for the authoritative command list.

## Read and export

Search Japanese text across utterances, memos, TODOs, and summaries:

```sh
koe search "検索語" --limit 20
```

Export one day as LLM-friendly text. Omit `--date` for today. Select any of `calendar,speech,memos,summary,todos`:

```sh
koe export day --date 2026-08-29 --include calendar,speech,memos,summary,todos
```

Export all confirmed open TODOs:

```sh
koe export todos
```

Add `--clipboard` to copy, or `--output <path>` to create a file. Confirm the destination before creating or replacing a file.

## TODOs

List operations are read-only:

```sh
koe todo list --status open
koe todo list --status all
```

Only mutate TODOs when the user asks for that change:

```sh
koe todo add "タイトル"
koe todo complete <id>
koe todo reopen <id>
koe todo delete <id>
```

Treat IDs as opaque values returned by `todo list`. Confirm immediately before deletion.

## Prompts

Read the current life-log prompts with `koe prompt get summary|todo`. Change them only when the user explicitly requests it:

```sh
koe prompt set summary "新しいプロンプト"
koe prompt set todo - < prompt.txt
```

The CLI uses Koe's local database and settings. It does not require direct access to files under Koe's Application Support directory.
