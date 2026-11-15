# CLI and MCP

`lore` (CLI) and `lore-mcp` (stdio MCP server) read the same life-log DB as the app. They export a day as Markdown, search, list days with records, return a range as JSON, and return Life Log AI notes. No command changes the user's records, but opening the DB is not read-only (see Preconditions).

## Sub-features

- `cli-days` runs `lore days [--from] [--to]`, which prints JSON days with counts.
- `cli-export` runs `lore export day [--date YYYY-MM-DD] --include calendar,speech,voice-input,memos,ai-notes`, which prints Markdown or writes it with `--output`. `--date` defaults to today; `ai-notes` is off unless named.
- `cli-search` runs `lore search <query> [--limit]`, which prints tab-separated `day kind text`.
- `cli-range` runs `lore range --from … --to … --include …`, which prints JSON (at most 31 days; rejects `ai-notes`).
- `cli-notes` runs `lore notes [--from] [--to]`, which prints the AI-generated notes as JSON (at most 31 days).
- `cli-errors` handles unknown commands and include names: exit 1, usage on stderr for an unknown command, `--include の値が不正です: <name>` for an unknown include.
- `mcp-tools` exposes `life_log_days`, `life_log_range`, `life_log_export`, `life_log_ai_notes` and `life_log_search` over stdio.

## How to get to it (user POV)

- Settings > 連携 installs `~/.local/bin/lore` → `Lore.app/Contents/Helpers/lore`.
- In development, `make tools` builds `build/tools/lore` and `build/tools/lore-mcp`.

## Driving it with lore-verify

Preconditions: `make tools`. There is no isolated DB: these binaries ignore `HOME` and always open the **real** `~/Library/Application Support/Lore/lore.sqlite`. Opening it happens before argument parsing, so even `lore help` does it. It writes the day's backup if missing, seeds modes, and **runs any pending migration on the user's real DB**. Run this guard first and stop when it prints a migration name or the backup is missing:

```sh
LORE="$HOME/Library/Application Support/Lore"
sqlite3 -readonly "$LORE/lore.sqlite" 'select identifier from grdb_migrations' | sort > build/verify/applied.txt
grep -o 'registerMigration("[^"]*"' Sources/LoreKit/Persistence/LoreDatabase.swift | cut -d'"' -f2 | sort | comm -13 build/verify/applied.txt -
ls "$LORE/Backups/daily-$(date +%Y%m%d).sqlite"
```

A pending migration means the branch is ahead of the user's installed Lore. Report the CLI as unverified live and fall back to `swift test --filter AutomationServiceTests`. Run only the commands below. Never pass `--output` to a path outside `build/verify/`.

- **Usage and errors.** Run `build/tools/lore help; echo "exit=$?"` (expect 0). Then run `build/tools/lore bogus; echo "exit=$?"` (expect exit 1 and `不明なコマンド` on stderr). Then run `build/tools/lore export day --include nope; echo "exit=$?"` (expect exit 1 naming `nope`).
- **Days.** Run `build/tools/lore days --from $(date -v-7d +%F) | tee build/verify/cli-days.json`. The output is a JSON array. Compare it with what the user's app shows, without asserting specific content.
- **Export to evidence.** Run `build/tools/lore export day --date $(date +%F) --include memos --output build/verify/cli-export.md`. The file exists and starts with `# `.
- **MCP.** Pipe an `initialize` request, then a `tools/list` request, into `build/tools/lore-mcp` and expect the five tool names. Treat the call results as the user's private data: summarize counts and do not paste the content.

## Gotchas

- Output contains the user's real life-log. Keep it in `build/verify/` and do not quote it in reports.
- For deterministic CLI behavior, prefer `swift test --filter AutomationServiceTests`. It runs on a temporary DB.
- `--clipboard` overwrites the user's clipboard.
