# MCP

`lore-mcp` (stdio MCP server) reads the same life-log DB as the app. It lists days with records, returns a range as JSON, exports a day as Markdown, searches, and returns Life Log AI notes. No tool changes the user's records, but opening the DB is not read-only (see Preconditions).

## Sub-features

- `mcp-initialize` answers `initialize` with the protocol version, the server info, and `instructions` for the AI client (read-only and local, list days first, summaries are the client's job, AI notes are AI output to check against their sources).
- `mcp-tools` exposes `life_log_days`, `life_log_range`, `life_log_export`, `life_log_ai_notes` and `life_log_search` over stdio.
- `mcp-days` runs `life_log_days {from?, to?}`, which returns JSON days with counts.
- `mcp-range` runs `life_log_range {from, to?, include?}`, which returns JSON entries (at most 31 days; rejects `ai-notes`).
- `mcp-export` runs `life_log_export {date?, include?}`, which returns Markdown. `date` defaults to today; `ai-notes` is off unless named.
- `mcp-notes` runs `life_log_ai_notes {from?, to?}`, which returns the AI-generated notes as JSON (at most 31 days).
- `mcp-search` runs `life_log_search {query, limit?}`, which returns tab-separated `day kind text`.
- `mcp-errors` handles unknown tools and bad arguments: a successful JSON-RPC response with `isError: true`, and `引数が不正です: <name>` for an unknown include.

## How to get to it (user POV)

- Settings > 連携 shows the `lore-mcp` path inside `Lore.app` and copies the path or the `claude mcp add` command.
- In development, `make tools` builds `build/tools/lore-mcp`.

## Driving it with lore-verify

Preconditions: `make tools`. There is no isolated DB: the binary ignores `HOME` and always opens the **real** `~/Library/Application Support/Lore/lore.sqlite`. Opening it happens at startup, so even `initialize` does it. It writes the day's backup if missing, seeds modes, and **runs any pending migration on the user's real DB**. Run this guard first and stop when it prints a migration name or the backup is missing:

```sh
LORE="$HOME/Library/Application Support/Lore"
sqlite3 -readonly "$LORE/lore.sqlite" 'select identifier from grdb_migrations' | sort > build/verify/applied.txt
grep -o 'registerMigration("[^"]*"' Sources/LoreKit/Persistence/LoreDatabase.swift | cut -d'"' -f2 | sort | comm -13 build/verify/applied.txt -
ls "$LORE/Backups/daily-$(date +%Y%m%d).sqlite"
```

A pending migration means the branch is ahead of the user's installed Lore. Report the MCP server as unverified live and fall back to `swift test --filter AutomationServiceTests`. Run only the requests below.

- **Handshake.** Pipe `{"jsonrpc":"2.0","id":1,"method":"initialize"}` then `{"jsonrpc":"2.0","id":2,"method":"tools/list"}` into `build/tools/lore-mcp`. Expect `instructions` in the first response and the five tool names in the second.
- **Days.** Send `tools/call` for `life_log_days` with `{"from":"<7 days ago>"}` and save the text to `build/verify/mcp-days.json`. The output is a JSON array. Compare it with what the user's app shows, without asserting specific content.
- **Errors.** Send `tools/call` for `life_log_export` with `{"include":["nope"]}`. Expect `isError: true` naming `include`.
- Treat every other call result as the user's private data: summarize counts and do not paste the content.

## Gotchas

- Output contains the user's real life-log. Keep it in `build/verify/` and do not quote it in reports.
- For deterministic behavior, prefer `swift test --filter AutomationServiceTests`. It runs on a temporary DB.
