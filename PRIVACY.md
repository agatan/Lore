# Lore data handling

Lore runs speech recognition on the Mac and uses no cloud speech recognition. Dictation with voice memos, and the Life Log, each use Apple SpeechAnalyzer or a whisper.cpp GGML model that the user downloaded. Both uses share the whisper.cpp model, and it runs only on the Mac.

Dictation audio exists only in memory while it is processed. Lore neither stores nor sends it.

The Life Log is the exception, and only when the user explicitly enables recording and consents to audio storage. So that speech can be recovered even if transcription fails, Lore saves short audio chunks in `~/Library/Application Support/Lore/LifeLog/`. Stored audio is never sent to an external service. The rolling provisional text shown while the user speaks is held in memory for confirming input and is not saved to the database. Household noise and silence that do not meet the voiced time and voiced ratio thresholds are not passed to speech recognition.

## Text formatting

With the default Apple Foundation Models, and with a local Ollama or LM Studio server, the transcript and the instructions are processed on this Mac and are not sent to an external service. The local API that Lore connects to is fixed to localhost.

Only when the user explicitly selects OpenAI, Claude, Gemini, or Groq in Settings does Lore send the following data to the API of the selected service:

- The current transcript
- The common rules
- The instructions of the selected mode
- The enabled vocabulary

Recorded audio, dictation history, Life Log utterances, memos, and events, and information about the frontmost app are not sent. Fetching the model list and checking the connection use the stored API key to authenticate with the selected API.

Data sent to a cloud API is subject to the terms and the privacy policy of that service.

## Life Log and AI clients

Lore never sends the Life Log to an LLM or to the cloud to summarize or analyze it. To review the Life Log with AI, the user passes it to an AI client of their choice through the CLI or MCP. Where that client sends data, and under what terms, follows the client's settings.

The CLI and the MCP server (`lore-mcp`) run on the Mac and return results only to the client connected through standard input and output. They make no network connection and never change the user's records. Like the app, opening the database can apply a pending migration, create a backup, and perform the one-time move of Koe data.

## Data stored on the Mac

Lore stores the following in `~/Library/Application Support/Lore/lore.sqlite`:

- Raw transcripts and formatted text
- The mode, instructions, engine, and model that were used
- The name and bundle ID of the app that was frontmost when recording started
- Results, errors, and processing times
- Modes, common rules, and vocabulary
- Life Log audio chunk records, timestamped utterances, text memos, and event snapshots

If you used the app under its old name Koe, the first launch moves `~/Library/Application Support/Koe/` to the Lore location, and copies the old Keychain items (service `dev.agatan.Koe`) to new items (service `dev.agatan.Lore`) before deleting the old ones. This migration happens entirely on the Mac and sends nothing.

When a whisper.cpp model is selected, the model file and the temporary file of a download in progress are stored in `~/Library/Application Support/Lore/Models/WhisperCpp/`. Lore connects to Hugging Face only to download the model file. The request contains no audio, transcript, event, history, or frontmost app information. Settings shows the size, download progress, and failures of each model, and the user can cancel, retry, or delete. A model in use is not deleted until the use stops or the selection changes.

Structured data is saved as SQLite snapshots in `~/Library/Application Support/Lore/Backups/` before a database migration and once per day at launch. The 7 newest are kept. Life Log audio is large and sensitive, so it is not copied. The retention period of the original files applies.

API keys and the sync key are stored in the macOS Keychain, not in the settings file, the history database, or the log. The log never contains spoken content, formatted results, vocabulary, or API keys.

The default retention of dictation history is forever. It can be changed to 30 days, 90 days, or 1 year. Life Log audio is deleted after transcription succeeds by default, which can be changed to 7 or 30 days. A whisper.cpp model is kept until the user deletes it or resets Lore.

Settings > Privacy deletes the dictation history only, the whole Life Log, or everything:

- **Dictation History** deletes transcripts and formatted text.
- **Life Log** deletes utterances, memos, imported events, and stored audio.
- **All Data ("Reset Lore…")** deletes history, backups, Life Log audio, utterances, memos, event snapshots, vocabulary, modes, common rules, downloaded whisper.cpp models and partial files, and legacy WhisperKit models. It also deletes every Keychain item: each API key, keys registered for the Life Log by older versions, and the sync key. Settings return to their defaults and sync is turned off. Files in the sync folder are not deleted.

When Lore is updated from an older version that stored to-do items, daily summaries, topics, or cloud AI token counts, it creates a backup immediately before the migration and then deletes that data from the database. That backup is also subject to the 7-snapshot retention and to the full reset.

## Sync between Macs (optional)

Only when "Sync" is enabled in Settings does Lore make the same text data available on several Macs. It is off by default.

- Synced: Life Log utterance text, memos, dictation history (raw transcript, formatted text, status, mode instructions, the name and bundle ID of the app that was frontmost when recording started, engine and model, error, processing times), and vocabulary.
- Not synced: recorded audio, API keys, settings, event snapshots, whisper.cpp models, backups, and modes.
- Lore writes only change files, encrypted on the Mac, into `Lore Sync/` inside the folder that the user chose (iCloud Drive, Dropbox, Syncthing, and so on). Lore itself makes no network connection. The folder provider transports the files.
- Encryption uses AES-GCM with a 256-bit key. The first Mac generates the key as a "sync code", and each Mac stores it only in its own Keychain. It is not synced to iCloud Keychain. The folder provider, and any third party without the sync code, cannot read the file contents. The number, size, and modification time of the files, and a random identifier created per Mac, are visible without encryption.
- Anyone who knows the sync code can read the contents of the folder. Do not give the sync code to anyone else. Enter it only on the Macs that join.
- Turning off sync or resetting Lore deletes this Mac's sync key and sync state. The files in the folder are not deleted. Delete the folder yourself when you no longer need it.

## Permissions

- Microphone: used for dictation, voice memos, and local recording of the Life Log when it is enabled.
- Calendar: used to show events on the timeline, to store their association with utterances, and to hold Life Log recording during events of calendars marked "Never Record" and events marked "Do Not Record". For the hold, Lore reads events from every calendar on the Mac only while at least one mark exists, and does not store those events.
- Accessibility: used to detect global hotkeys and to insert text into the frontmost app.
- Input Monitoring: used only when a global hotkey is Option plus a letter key, to detect the press and release of that combination. Other typing is neither stored nor processed.

Lore reads the name and bundle ID of the frontmost app. It does not read the contents of the screen, windows, or text fields.
