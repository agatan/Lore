# Lore

Lore is a voice app for macOS. It provides dictation, and a **Life Log** that keeps what you say, your calendar events, and your memos on one timeline per day. Lore does not summarize or extract to-do items. You hand the records to the AI of your choice through MCP.

Speech recognition and the default text formatting run on the Mac. Dictation audio is never stored. Only when you explicitly enable the Life Log does Lore save reprocessable audio chunks on the Mac. Audio is never sent anywhere. For details, see [Data handling](PRIVACY.md).

- External specification: [Markdown](docs/spec.md) / [HTML](docs/spec.html)
- Internal design: [Markdown](docs/design.md) / [HTML](docs/design.html)
- Overview: [docs/overview/index.html](docs/overview/index.html)
- Changes in each release: [CHANGELOG.md](CHANGELOG.md)

## Requirements

- macOS 26 (Tahoe) or later
- Apple Silicon
- Xcode 26 or later

## Build and run

```bash
make run
```

macOS grants permissions to the `.app`, so during development use `make run` and do not launch the executable directly.

| Command | What it does |
|---|---|
| `make run` | Builds and launches `Lore.app` |
| `make app` | Assembles and signs `Lore.app` |
| `make tools` | Builds only the MCP server into `build/tools/` |
| `make test` | Runs the unit tests |
| `make ui-test` | Runs the UI E2E that drives the main user journeys in the real app |
| `make install` | Places a release build in `/Applications` |
| `make stop` | Quits the running Lore |
| `make lp-media` | Regenerates the landing page screenshots and videos in `site/assets/` |

The tested user journeys and the conditions for running them are in the [test policy](docs/testing.md).

### Landing page

`site/` is a static page served as Cloudflare Workers static assets (`wrangler.jsonc`). A small Worker (`worker/index.js`) runs only for the English root: it redirects a first visit to `/ja/` or `/zh-Hans/` by the browser's `Accept-Language`, and a language picked in the page's switcher (the `lang` cookie) overrides that. The `Site` workflow deploys it to production on pushes to `main` that touch `site/`, and uploads a preview version (`pr-<number>`) for pull requests from this repository. The workflow needs the repository secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`. Create the `lore-site` Worker once, either in the Cloudflare dashboard (Hello World template, no Git connection) or with `npx wrangler@4 login` and `npx wrangler@4 deploy`, then give the CI token the Workers Editor role scoped to the `lore-site` Worker only. Creating a Worker needs the product-level Workers Admin role, which CI does not need after the first deploy.

### Permissions

1. **Microphone**: used for dictation and Life Log recording.
2. **Accessibility**: used to detect hotkeys and to insert text.
3. **Input Monitoring**: needed only when a hotkey is Option plus a letter key.
4. **Calendar**: optional. Shows your events in the Life Log.

### When the Accessibility permission is lost on every build

If the Keychain has a valid Apple Development certificate, the build prefers it. Running the App Intents from macOS Shortcuts requires a verifiable signature from Apple Development or Developer ID.

Without an Apple Development certificate, you can create a fixed self-signed certificate, which keeps permissions better than ad-hoc signing. A self-signed build cannot run the App Intents from Shortcuts.

```bash
make dev-cert
```

If the permissions are broken, this command resets the registrations of this app only:

```bash
make reset-permissions
```

## Usage

- **Press Right ⌥ briefly** to start and stop recording.
- **Hold Right ⌥** for push-to-talk.
- **Press Esc** to cancel. Text that was already recognized stays in the history.

The other default hotkeys are ⌃⌥L to start and stop Life Log recording, ⌃⌥M to show and hide the mini window, and ⌃⌥V for a voice memo. Settings changes every hotkey and the hold duration.

In Settings > Life Log > Scheduled Recording, choose days and a time window (for example weekdays 9:00 to 19:00) and Lore records the Life Log only during that window. This suits an always-on Mac, such as a Mac mini, that should record only at fixed hours. At the end of the window only a recording that started automatically stops. A recording that you started yourself continues. If you stop recording inside a window, it does not resume until the next window.

Lore exposes "Start Life Log", "Stop Life Log", "Pause Life Log", and "Resume Life Log" to the macOS Shortcuts app. The stop action waits for the final transcription and saving to finish. The pause action takes a duration, and recording resumes by itself when it ends.

A day can be exported from the Life Log screen and through MCP. You select events, speech, dictation, and memos individually, and the result is chronological Markdown.

## MCP

For finer automation there is a stdio MCP server that uses the same database and export definition. Settings > Integrations shows its path and copies the registration command.

`/Applications/Lore.app/Contents/Helpers/lore-mcp` is a standard input/output MCP server. It exposes the list of days with records (`life_log_days`), the entries of a range as JSON (`life_log_range`), the day Markdown (`life_log_export`), the notes that Life Log AI generated for events (`life_log_ai_notes`), and cross-record search (`life_log_search`). None of them changes your records. A Lore memo is a rough draft captured quickly by voice. Review, summaries, to-do extraction, and rewriting rough memos into another notes or task app are left to the AI on the MCP client side. The server only reads the database on the Mac.

```sh
claude mcp add lore -- /Applications/Lore.app/Contents/Helpers/lore-mcp
```

## Sync between Macs

Settings > Sync shares Life Log speech, memos, dictation history, and vocabulary between several Macs. Recorded audio, API keys, and settings are not synced.

1. On the first Mac, choose "Start a new sync" and select a folder that your other Macs can also see, such as iCloud Drive, Dropbox, or Syncthing. Write down the sync code that is shown.
2. On each additional Mac, choose "Join with a sync code", enter the code, and select the same folder.

Lore writes only change files, encrypted on the Mac, into `Lore Sync/` inside the folder. Lore itself makes no network connection, and the folder provider cannot read the contents. When the same item changes on several Macs, the later change wins.

## Text formatting

- **On this Mac**: Apple Foundation Models by default, or a local Ollama or LM Studio server. Text data is not sent to an external service.
- **Cloud**: OpenAI, Claude, Gemini, or Groq. Only when you select one does Lore send the dictation transcript, the instructions, and your vocabulary to it. Life Log records and recorded audio are never sent. API keys are stored in the macOS Keychain.

Whichever you choose, Lore inserts the raw transcript when formatting fails.

## Structure

```text
Sources/LoreKit/
├── Domain/        Session state, modes, formatting policy, vocabulary, speech segmentation, schedule
├── Engines/       SpeechAnalyzer, whisper.cpp, Foundation Models, cloud and local LLMs
├── System/        Hotkeys, recording, insertion, Keychain, macOS integration
├── Persistence/   History, Life Log, modes, and sync state on GRDB / SQLite
├── Sync/          Sync between Macs through encrypted change files
├── Analysis/      Text generation for export
├── Automation/    Read-only use cases for the MCP server
├── App/           Coordinators, settings, and the composition root
└── UI/            Menu bar, HUD, main and mini windows, settings, history
```

The central invariant is "never lose what was said". After speech recognition finishes, Lore persists the transcript first and only then formats and inserts. It falls back to the raw text when formatting fails and to the clipboard when insertion fails. The Life Log saves recovery audio every 30 seconds, detects speech spans from the input signal, and recognizes them afterward at adaptive silence boundaries. After an input failure it resumes from the stored audio, and it reconnects automatically while recording is enabled.

Structured data is saved as SQLite snapshots in `~/Library/Application Support/Lore/Backups/` at launch. A snapshot is always taken before a pending database migration, and otherwise once per day. The 7 newest are kept. To restore, quit Lore, move the current database aside, and follow [Backup and recovery](docs/recovery.md).

## License

[MIT License](LICENSE)
