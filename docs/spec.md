# Lore external specification

This document is the source of truth for the behavior that users and automation clients can observe. The [HTML version](spec.html) is generated from this file. For internal structure, see [design.md](design.md). For data handling, see [PRIVACY.md](../PRIVACY.md).

## 1. Environment and product boundary

| Item | Specification |
|---|---|
| OS | macOS 26 or later |
| CPU | Apple Silicon |
| Form | Menu bar app. Lore appears in the Dock and the app switcher only while one of its windows is open |
| Required permissions | Microphone. Accessibility for hotkey detection and for inserting text at the cursor. Input Monitoring for hotkeys made of Option plus a letter key |
| Optional permission | Calendar, to show events in the Life Log |
| Speech recognition | Chosen separately for dictation and voice memos, and for the Life Log: Apple SpeechAnalyzer or a locally downloaded whisper.cpp GGML model. With whisper.cpp, dictation is recognized in one pass after recording stops, and the Life Log is recognized per speech burst after the burst ends |
| Default text formatting | On-device processing with Apple Foundation Models |
| Life Log AI | Optional and off by default. Generates notes for calendar events from Life Log text with a provider that the user chooses (section 4.4) |
| Display language | System Settings, English, Japanese, or Simplified Chinese. The default is System Settings. A change applies to open windows and date formats immediately |
| Color theme | System Settings, Light, or Dark. The default is System Settings. A change applies to open windows immediately |
| Storage | SQLite, UserDefaults, Keychain, and Life Log audio files, all on the Mac |
| Sync | Optional. Lore places text data, encrypted on the Mac, in a folder that the user chooses, and other Macs read it from there (section 6.1) |

Out of scope: platforms other than macOS, batch transcription of arbitrary audio files, voice commands that operate apps, storing dictation audio, and cloud speech recognition.

## 2. First launch and permissions

- The first launch shows a full-window onboarding in three steps:
  1. **Welcome.** It explains the three features (Life Log, dictation, voice memo), the microphone, Accessibility, and optional calendar permissions with their current state, and what Lore stores.
  2. **Try dictation.** It shows the dictation hotkey large, a text field, and a prompt to hold the hotkey and say one sentence. While this step is on screen and Lore is the frontmost app, a dictation lands in that field instead of being pasted into another app. It is saved to the history like any other dictation. When text lands, the step shows the recognized text next to the formatted text. If the microphone or Accessibility permission is missing, the step names each missing permission and offers a button back to the permissions in step 1. The step can be skipped.
  3. **Ready.** It offers to start the Life Log as the next step. Starting it goes through the same audio storage consent as any first Life Log start. The user can also open Lore without starting it.
- Finishing and skipping both mark onboarding as completed, so it does not show again.
- A normal launch keeps the menu bar item and also opens the main window with the Life Log selected.
- Lore was renamed from Koe. On its first launch, Lore (bundle ID `dev.agatan.Lore`) takes over the data of Koe (`dev.agatan.Koe`) once:
  - It moves `~/Library/Application Support/Koe/` to `~/Library/Application Support/Lore/`, renames the database file to `lore.sqlite`, and repoints stored audio paths.
  - It copies the Koe settings unless Lore already has settings.
  - It copies each API key and the sync key in the Keychain to the new service and then deletes the old item. A value that Lore already holds is not overwritten.
  - If the Lore folder already exists, Lore does not merge. It leaves the Koe folder in place and shows its location in the menu bar panel.
  - If the folder cannot be moved, Lore does not open the database and shows the reason. The Koe data stays where it was.
  - macOS permissions and the login item belong to the bundle ID, so the user grants them again for Lore.
  - The MCP server is now `lore-mcp`. AI clients must be registered again. If the MCP server starts before the app, it performs the same folder and settings migration.
- Lore does not restore the recording intent of the previous process. Life Log recording starts only from an explicit action in the UI, a hotkey, or Shortcuts, inside a scheduled recording window that the user enabled, or when a pause that the user started in an earlier process ends (section 4.1).
- Without the microphone permission, Lore cannot record. Without the Accessibility permission, Lore cannot insert text, cannot detect a modifier-only hotkey such as the default Right Option, and cannot detect Esc. A hotkey made of Option plus a letter key also needs Input Monitoring.
- Dictation does not need the calendar permission. Settings > General lists each permission with its state and an "Allow" button for the ones not granted. The Input Monitoring row appears only when a hotkey needs it. For the microphone and the calendar, the button shows the system dialog the first time and opens System Settings after a denial. For Accessibility and Input Monitoring, the button requests access and opens System Settings.
- The first time the Life Log starts, Lore asks the user to confirm that it saves recovery audio in 30-second chunks on the Mac. If Shortcuts starts the Life Log before this consent, the action returns an error that asks the user to open Lore and confirm.

## 3. Dictation

### 3.1 Controls

- The default hotkey is Right Option.
- A short press toggles recording. A long press is push-to-talk and stops on release. The default long-press threshold is 500 ms, adjustable from 150 to 1000 ms.
- A hotkey that includes a letter key is registered with the standard macOS hotkey dispatcher. On macOS 26 the dispatcher sometimes does not report letter keys combined with Option only (including Option+Shift). For those, Lore also watches input events when the user grants Input Monitoring, and it uses only the first press and release pair that arrives. Modifier-only hotkeys and Esc also use input event monitoring. While Secure Input is on, macOS blocks input event monitoring and pasting into the target app. A registration failure or missing permission for one hotkey does not stop the others.
- Lore refuses to assign the same key to two actions.
- The menu bar panel can also start and stop dictation. Only one dictation runs at a time.
- Esc cancels the dictation in any active phase: recording, transcribing, formatting, or inserting. If text was already recognized, it stays in the history as `cancelled`. System sleep also cancels an active dictation or voice memo.
- The HUD and the menu bar icon show recording, transcribing, formatting, inserting, and the result. Settings can turn the HUD, the sound effects, and the input level display on or off.

### 3.2 Recognition, modes, and vocabulary

- By default, dictation and voice memos stream to Apple SpeechAnalyzer and the HUD shows provisional text. When the user selects whisper.cpp, Lore prepares the model while recording starts and recognizes the whole recording on the Mac after it stops. In that case no provisional text appears during recording. Dictation audio is never written to a file or the database and is never sent anywhere.
- Before audio goes to whisper.cpp, Lore trims leading and trailing silence (below about -50 dBFS) and keeps a 0.5-second margin. If it detects no voiced span, it passes the whole recording. The wait for the final result after stopping is at most 30 seconds plus the recording length.
- Lore passes the enabled vocabulary spellings to whisper.cpp in their list order as a prompt of about 200 tokens at most. A segment that only repeats a whole prompt of two or more words is treated as an echo generated from silence and is removed.
- The whisper.cpp models are Whisper Large v3 Turbo Q5_0 (574 MB, the default), Whisper Large v3 Q5_0 (1.08 GB), and Whisper Small Q5_1 (190 MB). Dictation and the Life Log share one selected model. Both settings pages list the models and show download progress and failure reasons, and the user can cancel, retry, or delete a download. A model cannot be used before its download completes. It cannot be deleted while the Life Log is recording or processing, or while dictation is processing.
- The Life Log selects its engine separately from dictation. Section 4.1 describes how it detects and recognizes speech.
- The known boilerplate that whisper.cpp generates from silence or ambient sound, "ご視聴ありがとうございました", is neither shown nor saved when it is recognized as a standalone sentence. Real speech that follows in the same segment is kept.
- Lore picks the mode once from the frontmost app when recording starts and keeps it for that session. A manually pinned mode takes priority over automatic selection. The pin lasts until Lore quits.
- A mode has a name, target bundle ID patterns (`*` is a wildcard), formatting instructions, and a language (automatic, Japanese, English, or Simplified Chinese). The user can create, edit, duplicate, and delete modes, and restore a built-in mode to its shipped content. The built-in modes are Default, Chat, Mail / Docs, Memo, and Commit / PR. Default cannot be deleted and serves apps that match no other mode.
- The common rules apply to every mode. The shipped common rules and mode instructions are written in English regardless of the display language or the spoken language. The formatted result is returned in the language that was spoken and is not translated. The common rules and each built-in mode follow updates to the shipped content while the user has not edited them. Edited content is never changed, and a built-in mode that the user deleted stays deleted.
- A vocabulary entry has a spelling, an optional reading, misrecognition patterns, and an enabled flag. Entries feed the speech recognition hint and the formatting instructions.

### 3.3 Text formatting

Formatting applies only to dictation. Life Log text is never passed to formatting.

| Option | Where the text goes |
|---|---|
| Apple Foundation Models | Processed on the Mac |
| Ollama | Sent to `localhost:11434` |
| LM Studio | Sent to `localhost:1234` |
| OpenAI / Anthropic / Gemini / Groq | Text data is sent to the provider that the user explicitly selected |

A cloud request contains the current transcript, the common rules, the mode instructions, and the enabled vocabulary. Recorded audio, past history, the frontmost app name and bundle ID, and API keys are never part of the prompt. The request is a text transformation, not a question to answer.

Lore inserts the raw transcript unchanged when the formatted output is empty, is abnormally short or long compared with the input, shows signs of leaked instructions, or does not match what was said, and when the provider times out or returns an error. The default timeout is 6 seconds, adjustable from 2 to 20 seconds. The history entry then shows that formatting was skipped and why.

### 3.4 Insertion and history

- Lore pastes the result in one operation at the cursor of the app that was frontmost when recording started.
- The exception is the try-dictation step of onboarding (section 2). While it is on screen and Lore is frontmost when recording starts, the result goes into the onboarding text field without the clipboard.
- Lore saves the existing clipboard first and restores it after a successful paste. If it cannot insert (no Accessibility permission, Secure Input, or the target app cannot be brought back to the front), it leaves the result on the clipboard and notifies the user.
- After speech recognition finishes, Lore saves the raw text to the history before formatting starts.
- A history entry shows the date and time, target app, mode, trigger (toggle, hold, or manual), speech recognition engine, formatting engine, raw text, result, status, error, the time taken by each stage, and the full instructions that were sent to the model with the vocabulary count.
- The statuses are `interrupted`, `completed`, `cancelled`, `failed`, `fallback`, and `clipboard_only`.
- The user can search raw text and results by substring, copy a result again, delete one entry, and delete all entries.
- History retention is forever (the default), 30 days, 90 days, or 1 year. Settings shows the current number of stored entries.

### 3.5 Voice memo

- The dedicated global hotkey (default ⌃⌥V) and the voice button in the memo field of the main and mini windows each toggle recording on every press. The recognized raw text is saved as a memo in today's Life Log. A voice memo is not formatted, not inserted into the frontmost app, and not saved to the dictation history.
- A voice memo uses the dictation speech recognition engine with automatic language detection. Esc cancels it.
- The voice button shows a progress indicator while it prepares, and the rose color of the app icon's dot with a pulse while it records. It cannot start while another voice process, such as dictation, is running.
- If a voice memo starts while the Life Log is recording, Lore commits the current recovery audio chunk and pauses Life Log capture. After the memo completes, is canceled, or fails, the Life Log resumes only if the user's recording intent is still in place.
- Because of this exclusive boundary, one voice memo creates exactly one memo and adds nothing to the dictation history or to the Life Log utterances.

## 4. Life Log

### 4.1 Recording

- The Life Log starts and stops independently of dictation, and both can run at the same time.
- The user controls it from the menu bar panel, the main window, the mini window, a dedicated global hotkey (default ⌃⌥L), and macOS Shortcuts.
- The app starts in the stopped state. It does not start recording because the previous process was recording. Only a launch inside a scheduled recording window starts recording, as a scheduled recording, and a pause that was active when Lore quit is restored (see Pause below). After wake from sleep or an input device reconnection, recording resumes only for a recording intent that remains in the same process.
- When "Scheduled Recording" is enabled in Settings, Lore records the Life Log from the start time to the end time on the selected days. The defaults are off, Monday to Friday, 9:00 to 18:00. If the end time is not later than the start time, the window crosses midnight and belongs to the day it starts on.
  - On entering a window, or when the app launches, wakes, or the setting changes inside a window, Lore starts recording if it is not recording.
  - On leaving a window, Lore stops only a recording that the schedule started. A recording that the user started from the UI, a hotkey, or Shortcuts is not stopped automatically.
  - If the user stops recording inside a window, Lore does not resume in the rest of that window. Scheduled recording resumes from the next window.
  - Without the first-time consent to save audio, the schedule does not start. A banner asks the user to start manually once and consent. Without the microphone permission, the failure is shown as for a manual start and is not retried automatically.
  - Settings shows the next window. While a scheduled recording runs, the status shows the end time, as in "Scheduled · until 18:00". While waiting, it shows the next start time, as in "Next scheduled 9:00".
  - Time checks follow the Mac's calendar and time zone. Lore recalculates the next switch time after a clock change, a time zone change, or wake from sleep.
- **Pause.** While a recording intent exists, the menu bar panel, the main window, the mini window, and Shortcuts can pause the Life Log for 15 minutes, 30 minutes, 1 hour, or until the current event ends. "Until the current event ends" is offered only while a timed event of today's timeline is in progress.
  - A pause stops capture immediately and commits the audio captured so far as a chunk, as for any stop. No audio is captured while paused.
  - Recording resumes by itself at the resume time. The user can resume early with "Resume" in the same places or with Shortcuts. Stopping the Life Log during a pause ends the pause, and recording does not resume.
  - The pause is kept across sleep and quit. If the resume time passed while the Mac slept, recording resumes on wake. If Lore quits during a pause and launches again, it stays paused until the resume time and then records. If the resume time has already passed at launch, it records immediately. In both cases the recording keeps the owner it had before the pause, a scheduled recording or a manual one.
  - A scheduled start does not end a pause. If the scheduled window of a scheduled recording ends during the pause, the pause ends and recording does not resume. A manual recording that is paused is not affected by the end of a window.
  - Pausing again during a pause replaces the resume time.
- **Never record events.** In Settings > Calendar, the user can mark calendars as "Never Record". A single event can also be marked "Do Not Record" from its row in the timeline, from the moment it is shown until it ends, and the mark can be removed the same way. While a timed event that is marked this way, or that belongs to a "Never Record" calendar, is in progress, Life Log capture is held: no audio chunk is created, and recording resumes by itself when the event ends if the recording intent remains. All-day events never hold capture.
  - The hold applies to manual and scheduled recordings and to a recording started during the event. It does not change the recording intent or the schedule.
  - Lore reads these events from every calendar on the Mac, including calendars hidden from the timeline, only while at least one calendar or event is marked. It reads them at launch, on wake, after a calendar change in EventKit, after the marks change, and every 15 minutes. Without calendar access no event holds capture, and Settings > Calendar shows the permission request.
  - The event marks are stored in the app settings, not in the database, and are removed after the event ends.
- Every Life Log view and the menu bar icon show the same recording state, taken from whether the audio writer is actually running. The menu bar icon is the "L." of the app icon, and only its dot shows state: rose while recording (dictation or Life Log), a ring in the icon's own color while processing, mint when a dictation completed, gold when formatting was skipped, the result is on the clipboard only, or the dictation failed, and a gold ring while the Life Log is reconnecting, and a rose ring while the Life Log is paused or held for an event. Dictation state takes priority over Life Log state. With no state to show, the icon is a template image.
- While dictation runs at the same time, the recoverable Life Log audio keeps recording. For a span where dictation succeeded, the dictation's raw transcript is authoritative, and the utterances that the Life Log recognized in the same span do not appear in the timeline, search, or export. If the dictation was canceled or failed, the Life Log utterances remain.
- The user can choose the input device. While recording, Lore commits a recovery `.m4a` on the Mac every 30 seconds and whenever a speech burst ends. Audio is never sent to a cloud speech service.
- An audio chunk is the unit of durability and recovery. Because the chunk closes when a burst ends, final recognition does not wait for the next periodic commit. Recognition runs per adaptive speech burst, and sustained near-silence is not transcribed.
- Speech onset uses the linear RMS of the input signal, not the level shown in the UI. Lore calibrates a background noise floor during the first second and keeps updating it while nobody speaks. A burst starts only when the input stays above an absolute floor of about -50 dBFS and sufficiently above the noise floor, by both difference and ratio, for 250 ms. A burst ends after 1.5 seconds of continuous silence when it holds less than 30 seconds of voiced audio, after 1 second when it holds 30 seconds or more, and after 5 minutes of wall time as a safety limit.
- A candidate with less than 0.5 seconds of voiced audio, or with a voiced ratio below 20% of the burst, is discarded as household noise or silence. Lore runs no preview, no final recognition, and no chunk checkpoint for it.
- With whisper.cpp selected, Lore shows provisional text while the user speaks: starting 1.5 seconds after valid speech begins, it recognizes the latest 5 seconds every 1.5 seconds, as long as the previous preview has finished. Provisional text is only for confirming input. It is never saved to the database, timeline, search, or export. Only the final recognition of persisted audio is authoritative.
- When a valid burst ends, Lore commits the current recovery chunk atomically and runs the final recognition after the audio it refers to is persisted. Utterance timestamps are restored from the recording start time and the audio offset. The vocabulary is captured when the recording session starts and stays fixed until it ends. Reprocessing of stored audio uses the same speech detection and the latest enabled vocabulary.
- When the main or mini window detects valid speech, it shows a live row separate from the recording state. The row first shows "Listening" and the length of the input audio, and updates the rolling text whenever a preview returns. After the burst ends, it switches to "Transcribing" and the elapsed processing time, and disappears when the final result is saved to the timeline.
- The timeline in the main and mini windows shows the latest item when first displayed and follows new utterances, memos, and events only while the user stays at the bottom. If the user scrolls back or jumps to an item from search or an event, following stops. It resumes when the user returns to the bottom.
- The Life Log recognition language is "Match Display Language" (the default), "Detect Automatically", Japanese, English, or Simplified Chinese. When the display language is "System Settings", the resolved supported language is used. This setting applies only to the Life Log and does not affect dictation, voice memos, or modes.
- whisper.cpp control tokens and timestamp tokens are removed from results at the engine boundary and are never saved. Lore does not correct or rewrite text that was saved in the past.
- Stored audio is always kept until transcription succeeds and the utterances are saved to the database. With the default "Delete After Transcription", Lore deletes only the audio right after success and keeps the utterances. The options are "Delete After Transcription", "7 Days", and "30 Days". A value stored by an older version that is outside these options is shown as a legacy entry.
- With 7 or 30 days, unprocessed and failed chunks are still kept beyond the period and are reprocessed after the next launch. When the user shortens the retention, Lore deletes the processed audio that meets the new condition.
- On a temporary interruption or an audio configuration change, such as switching or disconnecting the default microphone, Lore commits the current chunk and reconnects automatically. It also closes the stream safely before sleep and resumes after wake if the recording intent remains. Only a lost microphone permission is not retried.
- When the app quits, Lore interrupts operations in progress and waits briefly only for the recovery audio commit and the required database writes. A stored chunk that did not finish is reprocessed at the next launch.

### 4.2 Day view

- The main window is a split view with a full-height translucent sidebar. "Life Log" and "Dictation" at the top of the sidebar switch the content. The Life Log is the default.
- The Life Log view has three columns:
  - The sidebar puts a monthly activity calendar under the navigation.
  - The center is the timeline of the selected day, a readable column centered in the window. It starts with a large date and weekday, a small label above them ("Today" in rose for today, the year for other days), a recording chip while today is being recorded, and the all-day events.
  - The right inspector shows the talk time, the counts of utterances, memos, and dictations, and "By Hour", a vertical time axis with event blocks and record marks. Selecting an event block or a position on the axis moves the timeline to that time. Today has a current-time line. The "Overview" toolbar button hides and shows the inspector, and the choice is kept for the next launch.
- A day with no records shows only that fact instead of the counts. A past day with neither events nor records shows no "By Hour". On such a day, the timeline shows one line at the rail position: how to start recording (today) or that nothing was recorded (a past day).
- The search and export buttons are also in the window toolbar.
- On a normal launch and whenever the Life Log is opened in the main window, Lore shows today and scrolls once to the latest item at the bottom after the data loads. The mini window does the same when it opens. The mini window always shows today, whatever day the main window shows, so browsing another day, jumping to a search result, or opening an earlier occurrence in the main window never takes the mini window away from today. Later recognition results and events do not take over the reading position, except for the follow behavior at the bottom described in section 4.1.
- The timeline shows timed events, utterances, dictations, and text memos in one column in time order, with no column header. A vertical rail runs to the right of the times, and each row has a mark on the rail for its kind: a small dot for an utterance, a symbol for a memo or a dictation, and a ring for an event. Each utterance is its own row. Inside an event's start-to-end span, the rail takes the event color, and the event row shows the title, the duration, and the calendar name. An event in progress has a "Now" tag. Where one hour or more passed since the previous item, the timeline shows the length of the gap. Events have no fill.
- Selecting a date reloads the events of that day and updates both the inspector and the timeline.
- The toolbar search button or `Command-F` opens cross-record search. A result shows its kind with a symbol, highlights the matching text, and has the date and time. The user selects a result with the up and down arrow keys without leaving the field and opens it with Return. Selecting an utterance, dictation, or memo result opens that day and moves to the item.
- The mini window shows events, utterances, dictations, and memos in one column in time order and pins the event in progress today above the timeline. It has no standard title bar and no all-day events. It stays in front, across Spaces and over full-screen apps, until the user closes it. Its toggle hotkey (default ⌃⌥M) acts only on a matching press and release that include the configured modifiers. Typing the same letter key alone does not open or close it.
- At the bottom of the main and mini windows, one capsule bar floats above the timeline. From the left it has the record button, the recording state, a chat-style memo field, the voice memo button, and the send button. A sent memo appears in today's timeline immediately. The send and voice buttons are circles of the same diameter. The timeline scrolls under the bar, and the bar does not hide the last row. To keep current memos out of past days, the main window shows the memo field only while today is selected. On a past day, the bar has only the record button and the state.
- A voice memo is added to today's timeline as the same kind of memo as typed input.
- A Lore memo is a rough draft captured quickly by voice or short typing. Careful rewriting, and copying into another notes or task app, is the job of an external AI that reads the records through MCP. Lore itself offers only light editing for fixing typos.
- A memo in the main or mini window can be edited in place with the edit button that appears on hover or with a double-click on the text. Return saves, Option-Return inserts a line break, and Esc cancels. An empty text is not saved, and the memo's creation time does not change. Deleting uses the delete button that appears on hover in the main window.
- The main window timeline column is at most 720 pt wide, including the time column and the rail, so rows do not stretch on a wide window.
- While the recording intent continues, the status text does not follow internal transcription starts and stops. It shows stable user-facing states: recording, starting, paused, reconnecting, and stopped.
- An utterance is associated with an event within a tolerance of 2 minutes before and after.
- A recording that crosses midnight is distributed to the actual days. If the view is following today, it switches to the new day.

### 4.3 Calendar

- Lore reads the events of the selected calendars and saves a snapshot of the time, title, calendar name, all-day flag, and participation status. It keeps one snapshot per occurrence, so each occurrence of a repeating event stays on its own day with its own time. Reading a day's events replaces that day's snapshot, so an event that was deleted or moved to another day leaves it.
- By default, only events that the user accepted, or that have no RSVP, are shown and exported. The user can change this filter.
- "Refresh Events" in the Calendar settings explicitly reloads the events of the day currently selected in the timeline. The button is disabled while it runs. Afterward the timeline and the monthly activity are updated.
- Lore does not change an RSVP and offers no path into the Calendar app.
- "Never Record" calendars and "Do Not Record" events hold Life Log capture while they are in progress (section 4.1). An event row that holds capture shows a "Not Recorded" tag.
- **Last time.** A repeating event that has not ended yet shows a "Last time" row with the date of its latest earlier occurrence that has recorded speech. The row appears on the event pinned in the mini window and on the event in the main window timeline, and disappears when the event ends. Selecting the date opens the main window on that day and highlights the first utterance of that occurrence. Occurrences are matched by the event identifier that the calendar shares across a repeating series, never by title. Only utterances recorded on this Mac carry that identifier, so an occurrence recorded only on another Mac does not count.
- When the earlier occurrence has AI notes, the row also lists up to three of its action items and open questions, action items first. The row only shows what is already stored and never sends a request. Life Log AI being off does not hide the date.
- The row is absent for an all-day event, for the first occurrence, for a series with no earlier recorded speech, and for an event that holds capture. For an event excluded from AI, or one in an excluded calendar, the row has the date only.
- In the monthly activity calendar, the day shown in the timeline is a filled circle: ink, or rose when that day is today. Today, when not selected, has a rose number. Each day has two density dots, one for events and one for speech. The header has previous month, next month, and "Today" buttons.

### 4.4 Life Log AI

Life Log AI generates a small set of notes from the Life Log at fixed moments. It is off by default. Until the user turns it on and picks a provider, no Life Log text is sent anywhere. MCP still gives an external AI client read access (section 8).

**Setting and consent.**

- Settings > Life Log AI has the on/off switch, the provider, the model, a statement of what is sent to whom, the excluded calendars, the event notes trigger (automatic or manual), the "notes are ready" notification switch, and the number of requests Lore made today.
- The providers are the same set as dictation formatting: Apple Foundation Models (on this Mac), Ollama (`localhost:11434`), LM Studio (`localhost:1234`), OpenAI, Claude, Gemini, and Groq. The choice is separate from the formatting provider. An API-key provider uses the key stored for that provider in AI Formatting.
- Turning Life Log AI on with a cloud provider, or switching to a cloud provider while it is on, asks for an explicit confirmation that names the provider. Without that confirmation, Lore refuses to send to that provider. An on-device or localhost provider needs no confirmation.
- Recorded audio never leaves the Mac. A request contains only the fixed instructions and, for event notes, the event title, its start and end time, and the time and text of each utterance and memo inside the event's time range. Calendar names, attendees, other days, dictation history, the frontmost app, and API keys are never part of the prompt.
- Generation runs only at the moments described below, never continuously, and never blocks or changes recording, transcription, or the timeline. A provider failure shows its reason on the event with a "Retry" button.

**Exclusions.**

- In Settings > Life Log AI, a calendar can be marked "do not send to AI". In the timeline, the context menu of an event has "Do Not Send to AI" and "Allow Sending to AI". An excluded event shows "Not sent to AI".
- An exclusion applies to the event's identifier, so it covers every occurrence of a repeating event.
- Text inside the time range of an excluded event or of an event in an excluded calendar is never part of any request, even when it also falls inside another event's range. An utterance that overlaps such a range at all is left out. An excluded all-day event covers its whole day. Lore reads the events of excluded calendars from the calendar for this, even when those calendars are not shown in the timeline. Without calendar access, Lore knows only the events already in the snapshot.

**Event notes.**

- When a timed calendar event that overlaps recorded speech ends, Lore generates notes for it from the utterances and memos inside its time range. The notes have three short sections: decisions, action items (with the owner when one was stated), and open questions. Every item names the source utterances or memos it came from, and an item that names none is dropped. A result with no items is stored as "nothing to note".
- The Life Log records only this Mac's microphone. In an online meeting the notes cover what the user said, not the other participants. The instructions and the UI say so and never claim a full meeting record.
- The notes appear under the event in the main window timeline, marked "AI-generated" with the provider name. Selecting an item moves the timeline to its first source. The day inspector lists the events of the day that have notes. Actions on the notes: copy as Markdown, regenerate, and delete.
- A notification says the notes are ready, unless the user turned it off. Clicking it opens the main window on that event.
- With the manual trigger, Lore never generates on its own. An ended event that has no notes shows "Generate Notes" while Life Log AI is on.
- Lore generates automatically only when all of these hold: Life Log AI is on, the trigger is automatic, the event is not all-day, it passes the participation filter of the Life Log settings, it ended today (an event that ends at midnight counts for the day it ended on, and an event that ended while the Mac slept or Lore was not running is handled at the next launch or wake on the same day), it has no notes yet, the user did not delete its notes, neither the event nor its calendar is excluded, and its range has at least 120 characters of utterance text. If audio captured before the event ended is not transcribed yet, Lore waits for it and checks again every 2 minutes. Audio whose transcription failed does not hold generation back.
- Generation is idempotent per event occurrence, identified by the event identifier and the day it starts. Relaunching, waking, or refreshing the calendar never creates a second note. Regenerating replaces the note. Deleting the notes stops automatic generation for that occurrence. "Generate Notes" still works.
- When the event is edited or moved after generation so that its start or end no longer matches the range the note was made from, or the event no longer exists in the snapshot, the note is marked "Event changed" and offers "Regenerate". When a source utterance or memo is deleted, the note is marked "Sources deleted" and offers "Regenerate". Lore never regenerates a marked note on its own. Each occurrence of a repeating event is checked against its own snapshot.

### 4.5 Search and export

- Search covers Life Log utterances, dictations, and memos with substring matching.
- A day export selects calendar events, Life Log utterances, dictations, and memos individually. Voice memos are included with memos. AI notes are an optional item, off by default. When selected, the export ends with an "AI-generated notes" section that names the provider and model of each note.
- An export is human-readable Markdown with the date as the heading. It lists events, utterances, dictations, and memos as readable chronological bullets. It contains no machine-oriented uppercase tags or raw metadata.
- In an export, consecutive utterances less than 90 seconds apart, with no other item between them, are merged into one paragraph with a time range.
- The export sheet treats the data at the time it opened as a snapshot and builds the preview off the UI thread. While it prepares, it shows progress and does not block selection changes, closing the sheet, or other voice processing. The preview shows the first 4,000 characters. The export contains everything.
- The UI exports to the clipboard or a file. MCP returns the same Markdown as text.

## 5. Screens and settings

Lore's colors are fixed to the three colors of the app icon: ink, white, and rose. There is no color theme setting. Primary actions are ink (near white in dark mode). Wide surfaces such as the sidebar selection and switches are a gray lighter than ink. Rose marks only "now": recording, today, and the current time. Events are a colorless gray. Only success, warning, and failure have other colors, with the same meaning on every screen. In the sidebars of the main window and Settings, each symbol sits on a rounded tile in a calm color for its feature: indigo for the Life Log, blue for dictation, gray for general, and teal for sync and integrations.

The display language is "System Settings", English, 日本語, or 简体中文, and the choice persists across launches. "System Settings" uses the first supported language among the macOS preferred languages and falls back to English when none is supported. Traditional Chinese is not silently replaced with Simplified Chinese. A change applies immediately to the menu bar, window contents, onboarding, Settings, the HUD, dialogs, and notices. The display language reaches speech recognition only when the Life Log recognition language is explicitly "Match Display Language". It does not change dictation, voice memos, modes, prompts, stored text, search, export content, or the machine-facing MCP interface.

The color theme is "System Settings", Light, or Dark, and the choice persists across launches. "System Settings" follows the macOS appearance and changes with it. A change applies immediately to the menu bar menu, window contents, onboarding, Settings, the HUD, and dialogs. The color theme changes only appearance and never changes stored data or the MCP output.

| Place | Features |
|---|---|
| Menu bar panel | Two cards, with no tabs. The Life Log card has the record button, the pause button, the recording state with the resume time or the scheduled time (or today's counts), and links to open today and the mini window. The dictation card has the record button, the hotkey, a button to copy the last text, a link to the history, and the mode menu. Notices for permissions, the Koe migration, and database errors appear below the cards. The footer has only Settings and Quit |
| Main window | Opens on a normal launch as the frontmost key window at 1680×960 pt (minimum 1080×680). Three columns: full-height sidebar (navigation, calendar), timeline, and inspector. Shows today's Life Log at the latest position. Hosts onboarding, the Life Log with the floating bar for typed and voice memos and recording control, and the dictation history (list and detail). Inspector toggle, search, and export are in the window toolbar. The history detail is a readable centered column |
| Mini window | Life Log state, today's timeline, and typed and voice memos. Once opened it stays in front of other apps, desktop Spaces, and full-screen Spaces until closed. Recording control is in the floating bar at the bottom. The whole window uses a translucent material |
| Settings: General, Privacy | General has the display language, the color theme, launch at login, and permissions. Privacy has the data folder, the storage used on this Mac, and deletion |
| Settings: Life Log, Calendar, Life Log AI | Life Log has the recording, mini window, and voice memo hotkeys, scheduled recording days and time window, input device, speech recognition engine, recognition language, whisper.cpp model, and audio retention. Calendar has calendar selection, the participation filter, "Refresh Events", and the "Never Record" calendars. Life Log AI is described in section 4.4 |
| Settings: Dictation, AI Formatting, Modes, Vocabulary | Dictation has the hotkey and hold duration, speech recognition engine and whisper.cpp model, display and sounds, and history retention. AI Formatting has the backend, model, API key, connection check, and wait time. Modes has the common rules and modes. Vocabulary has the entries |
| Settings: Sync, Integrations | Sync is described in section 6.1. Integrations has the MCP server path with a copyable registration command for Claude Code |

The Privacy settings show the total storage that Lore data uses on this Mac, including history, Life Log, stored audio, and whisper.cpp models.

The Life Log state in the main window, the mini window, and the menu bar panel share one record button. While stopped, the button is an ink circle with a rose dot. While a recording intent exists, it is a rose stop symbol, and it keeps the rose look while reconnecting, paused, or held for an event. The button has no visible text. Its tooltip and accessibility label are "Start Life Log Recording" and "Stop Life Log Recording". The text beside it is the state: "Life Log Stopped", "Starting Life Log", "Life Log Recording", "Reconnecting Life Log", or "Life Log Paused". While paused, the line under it shows the resume time, as in "Resumes at 10:30". While held for an event, it shows the event end, as in "Not recording during this event · until 11:00". Next to the record button, a pause button opens the pause durations while recording, and becomes "Resume" while paused. It is hidden while stopped and while capture is held for an event.

A message that does not prevent continued operation, such as an audio configuration change or a processing failure, appears as a dismissible banner with `×` at its right edge. Dismissing removes only the message. It does not affect the recording intent, automatic reconnection, or stored data.

## 6. Storage, backup, and deletion

| Data | Location | Default retention |
|---|---|---|
| History, modes, common rules, vocabulary, Life Log, AI notes, AI exclusions | `~/Library/Application Support/Lore/lore.sqlite` | History is kept forever. AI notes are kept until the user deletes them. The rest follows each setting |
| Life Log audio | `~/Library/Application Support/Lore/LifeLog/` | Deleted after transcription succeeds. Can be changed to 7 or 30 days |
| whisper.cpp models | `~/Library/Application Support/Lore/Models/WhisperCpp/` | Until the user deletes one, or resets Lore |
| General settings (including display language and color theme) | App UserDefaults | Until the user resets Lore |
| API keys | macOS Keychain | Until the user replaces one, or resets Lore |
| Sync key | macOS Keychain (this Mac only, not synced to iCloud Keychain) | Until the user turns off sync, or resets Lore |
| Sync change files | `Lore Sync/` in the folder that the user chose | Lore never deletes them. The user manages the folder |
| Database backups | `~/Library/Application Support/Lore/Backups/` | The 7 newest files |

- Lore backs up an existing database immediately before it applies pending migrations. On a normal launch it also backs up once per day.
- If the backup fails, the migration does not start.
- Settings > Privacy has three deletions. Each asks for confirmation and cannot be undone.

| Row | What it deletes | What it keeps |
|---|---|---|
| Dictation History | Transcripts and formatted text | Vocabulary, Life Log, settings, Keychain |
| Life Log | Utterances, memos, imported events, stored audio, AI notes, and AI event exclusions | Dictation history, settings, Keychain |
| All Data ("Reset Lore…") | History, Life Log, stored audio, AI notes, AI event exclusions, vocabulary, modes, common rules, downloaded whisper.cpp models, partial downloads, legacy WhisperKit models, database backups, and every Keychain item (API keys, the sync key, and keys registered by older versions). Settings return to their defaults, sync is turned off, and the built-in modes and common rules are created again | Files in the sync folder |

- A database from an older version that stored to-do items, daily summaries, topics, or cloud AI token counts is backed up immediately before migration, and then those tables are deleted. Utterances, memos, events, and dictation history are unchanged. API keys that an older version registered for the Life Log are never read and are removed from the Keychain by "Reset Lore…".

### 6.1 Sync between Macs

- Settings > Sync lets several Macs use the same text data. It is off by default.
- Synced: Life Log utterance text, memos (additions, edits, deletions), dictation history (raw text, formatted result, status, mode snapshot, target app name and bundle ID, engine and model, error, timings), and vocabulary.
- Not synced: recorded audio, API keys, settings, event snapshots (each Mac reads its own calendar), AI notes and AI event exclusions, whisper.cpp models, database backups, and modes. Each Mac generates its own AI notes. An utterance that arrives from another Mac has no stored audio and no event association.
- Lore writes only encrypted change files into `Lore Sync/` inside the folder that the user chose (iCloud Drive, Dropbox, Syncthing, and so on). Lore itself makes no network connection. The folder provider transports the files.
- Encryption happens on the Mac with AES-GCM and a 256-bit key. The first Mac generates the key and shows it as a "sync code". Other Macs join by entering that code. The key is stored only in each Mac's Keychain, and the folder provider cannot read the contents. A joined Mac can show the sync code again from Settings after a confirmation. If every joined Mac is lost and the sync code was not written down, nobody can read the folder.
- A wrong sync code is detected with a check file in the folder, and joining is refused. A change file that is unreadable, tampered with, only partly delivered, or in a newer format is not imported. Lore shows the reason in Settings and in the log and retries at the next sync. Later changes from the same Mac wait behind that file to keep their order.
- Changes are written out together a few seconds after they happen. Import runs at launch, when Lore comes to the front, every 2 minutes, and on "Sync Now". For an iCloud Drive file that is not yet local, Lore requests the download and imports it in a later sync.
- When several Macs change the same item, the change with the newer timestamp wins. A deletion is also recorded with its time, and an older change does not bring the item back.
- Deletions that the user makes one at a time (a memo, one dictation history entry, a vocabulary entry) reach the other Macs. Automatic deletion by the history or audio retention period, "Delete History", "Delete Life Log", and "Reset Lore…" delete only this Mac's data.
- When sync is turned on, Lore writes out all the target data that this Mac already has.
- "Turn Off Sync" and "Reset Lore…" delete this Mac's sync key and sync state and stop writing and importing changes. They do not delete the files in the folder.

## 7. macOS Shortcuts / App Intents

Lore exposes the following App Intent actions to Shortcuts. Each action waits for Lore to launch and for database initialization to finish before it runs. "Start Life Log" launches Lore in the foreground because it uses the microphone. "Stop Life Log" and "Pause Life Log" run in the background. "Resume Life Log" launches Lore in the foreground for the same reason as "Start Life Log".

| Action | Input / Output |
|---|---|
| Start Life Log | Starts recording, idempotently. Returns an error if the user has not consented to audio storage |
| Stop Life Log | Stops recording and waits for the transcription and saving in progress |
| Pause Life Log | Input: duration (15 minutes, 30 minutes, 1 hour, or until the current event ends; defaults to 30 minutes). Pauses as in section 4.1. Returns an error if the Life Log is not recording, or if "until the current event ends" is chosen while no timed event is in progress |
| Resume Life Log | Ends a pause and resumes recording. Does nothing if the Life Log is not paused |

Day export is available from MCP, not from Shortcuts.

## 8. MCP

`lore-mcp` is a stdio JSON-RPC server that reads and writes one JSON object per line. The MCP protocol version is `2025-03-26` and the server version is `1.0.0`. It does not answer notifications. Protocol errors are JSON-RPC errors (`-32600` invalid request, `-32601` method not found, `-32602` invalid parameters). A failure inside a tool call is returned as a successful JSON-RPC response with `isError: true` and a text.

The `initialize` result carries `instructions` for the AI client. They say that the server is read-only and local; that the client should list the days with records first and then read a range; that summaries, to-do extraction, and rewriting memos into another app are the client's job; and that AI notes are AI output, not the user's words, so the client checks them against their sources when it matters, and that they never cover what other meeting participants said because Lore records only this Mac's microphone.

| Tool | Arguments | Result |
|---|---|---|
| `life_log_days` | `from?: YYYY-MM-DD`, `to?: YYYY-MM-DD`. `to` defaults to today and `from` defaults to 29 days before `to`. At most 366 days | An array with only the days that have records. Each has `day`, the counts `utterances`, `dictations`, `memos`, and `events`, and `spokenSeconds`, the seconds of utterances that remain in the timeline |
| `life_log_range` | `from: YYYY-MM-DD`, `to?: YYYY-MM-DD` (inclusive, defaults to the single day `from`, at most 31 days), `include?: [calendar,speech,voice-input,memos]` (defaults to all) | An array of entries in time order. Each has `id`, `kind` (`event`, `utterance`, `dictation`, `memo`), `day`, `start`, optional `end`, and `text`. Events also have `title`, `calendar`, and `allDay` |
| `life_log_export` | `date?: YYYY-MM-DD`, `include?: [calendar,speech,voice-input,memos,ai-notes]` (defaults to all except `ai-notes`) | Human-readable Markdown |
| `life_log_ai_notes` | `from?: YYYY-MM-DD`, `to?: YYYY-MM-DD`. `to` defaults to today and `from` to `to`. At most 31 days | An array of AI-generated notes in time order. Each has `id`, `generated: true`, `kind` (`event_notes`), `day`, `eventId`, `start`, `end`, `provider`, `model`, `createdAt`, `stale` (an array of `event_changed` and `sources_deleted`), `sourceUtteranceIds`, `sourceMemoIds`, and `sections` (each with `kind`: `decisions`, `action_items`, or `open_questions`, and `items` with `text`, optional `owner`, and `sources`) |
| `life_log_search` | `query: string`, `limit?: integer` (minimum 1, default 100) | Tab-separated lines of `day`, `kind`, and text, newest first |

- Times are ISO 8601 strings with the local UTC offset. Events follow the participation filter of the Life Log settings. Life Log utterances that overlap a successful dictation are excluded, as on screen and in exports.
- MCP never changes the user's records and offers no write-back to Lore. Rewriting utterances or memos and copying them into another app is the job of the AI on the MCP client side. The server reads the database on the Mac and makes no network connection. Like the app, opening the database applies pending migrations with their backup, takes the daily backup, and performs the one-time Koe data migration.

## 9. Behavior on failure

- If speech recognition cannot produce a final result, the dictation becomes `failed` and Lore shows the reason. When SpeechAnalyzer reaches a state that needs a process restart, Lore shows the reason and relaunches itself. If that happens within the first 5 minutes after launch, Lore only shows the message, so it cannot loop. For a whisper.cpp model that is not downloaded, is corrupt, or does not fit on disk, the settings page shows how to recover.
- A formatting failure falls back to the raw transcript. An insertion failure leaves the result on the clipboard.
- A failure of database initialization, saving, search, or backup is never treated as success. Lore reports the reason on screen, through MCP, or in the log.
- An interrupted Life Log capture reconnects automatically only while recording is enabled, and stored chunks are not lost.
- If the Shortcuts stop action times out, its error says that the stored audio will be reprocessed at the next launch.

## 10. Acceptance criteria

1. With the on-device configuration, neither transcripts nor instructions leave the Mac.
2. A cloud configuration is used only after the user explicitly selects it, and Settings shows what is sent.
3. Dictation audio is never stored. Life Log audio is stored only after consent.
4. After a formatting failure the raw transcript is recoverable, and after an insertion failure the result is recoverable from the clipboard.
5. The history shows the mode, instructions, engines, result, and status that applied at the time.
6. Pending Life Log chunks are reprocessed after a restart.
7. A pre-migration backup and a daily backup are created, and at most 7 backup files are kept in total.
8. The public interfaces of MCP and Shortcuts match this document.
9. The dot of the menu bar "L." icon is rose only while audio is actually being recorded, shows a gold ring while the Life Log reconnects, and has no color while stopped.
10. A dictation that succeeds during Life Log recording appears exactly once in the timeline, search, and export. For the span of a canceled or failed dictation, the Life Log utterances are not lost.
11. With Life Log AI off, no Life Log text is sent to any provider. With it on, only the fields listed in section 4.4 are sent, only to the chosen provider, only after the confirmation for a cloud provider, and never for excluded events or calendars. A localhost provider sends nothing beyond localhost.
12. "Refresh Events" in the Calendar settings updates the snapshot of the currently selected day, the timeline, and the monthly activity.
13. After an audio configuration change such as a microphone switch, Life Log capture resumes automatically as long as the recording intent remains.
14. One voice memo creates exactly one memo, and the same content is added neither to the dictation history nor to the Life Log utterances.
15. On a normal launch the Life Log screen of the main window opens as the frontmost key window, and the voice button in the memo field starts and stops the same voice memo as the dedicated hotkey.
16. With "Delete After Transcription", unprocessed and failed chunks remain, and only audio whose transcription succeeded is deleted.
17. On a normal launch, when the Life Log is opened in the main window, and when the mini window opens, the latest item of today's timeline is visible.
18. The timeline is one column with no header and shows events, utterances, dictations, and memos in time order. Selecting a date updates the events and the timeline, and search also opens with `Command-F`.
19. The mini window is a one-column timeline without a title bar, shows events and records in time order, and pins the event in progress at the top. It stays in front across Spaces and full-screen apps until closed, and ordinary typing does not toggle it.
20. The recording state in the main window, the mini window, and the menu bar comes from the actual audio writer state and uses the same colors, symbols, and wording. In the main and mini windows, the record button is at the left end of the same floating bar as the memo field.
21. A message that allows continued operation can be closed with `×`, and dismissing it changes neither automatic reconnection nor the recording intent.
22. The monthly calendar fills the shown day with an ink circle, or a rose circle when that day is today, and shows today in rose when another day is shown.
23. Opening a database from an older version with to-do items, summaries, or token counts leaves a pre-migration backup, deletes those tables, and keeps utterances, memos, and search working.
24. The recording intent of the previous process is not restored at launch. With scheduled recording enabled, recording starts on launch or wake inside a window and at the start of a window, and only a recording that the schedule started stops at the end of the window. After a manual stop inside a window, recording does not resume until the next window.
25. Dictation with voice memos, and the Life Log, each select SpeechAnalyzer or a downloaded whisper.cpp model. With whisper.cpp, dictation recognizes the whole recording after it stops, and both uses share one model. Settings shows the download, cancel, retry, and delete states and the sizes, and audio never leaves the Mac.
26. The Life Log calibrates the background noise floor from linear RMS right after capture starts and keeps updating it from non-speech input. A burst starts only when the input stays above about -50 dBFS and sufficiently above the recent noise floor for a short time, so faint noise and steady air conditioning create no recognition job. With whisper.cpp, provisional text for the latest 5 seconds appears at a 1.5-second cadence while speaking, only when the previous preview has finished. A burst flushes after 1.5 seconds of silence under 30 seconds of speech and after 1 second at 30 seconds or more. Audio is committed when a burst ends, timestamps match the stored audio offset, provisional text is not persisted, and the vocabulary is the snapshot taken when the recording session started.
27. A candidate with less than 0.5 seconds of voiced audio or a voiced ratio below 20% starts no preview, no final recognition, and no burst checkpoint, and is also excluded when stored audio is reprocessed. The main and mini timelines follow new items only while the bottom is visible, stop following after a scroll back or a jump to a source item, and resume at the bottom.
28. The known whisper.cpp boilerplate hallucination "ご視聴ありがとうございました" is removed at the engine boundary only as a standalone sentence, and real speech in the same segment is kept.
29. Two Macs with sync enabled share utterance text, memos, dictation history, and vocabulary by placing only encrypted change files in a folder. A different sync code is refused. An unreadable change file is not imported, its reason is shown, and it is imported when it arrives intact later. Individual deletions reach the other Mac. Deletions by retention period and bulk deletions do not.
30. A pause stops capture immediately, commits the audio captured so far, and resumes at the stated time without user action, also after sleep and after a quit and relaunch. A scheduled start does not end a pause, and the end of the window of a paused scheduled recording cancels the resume.
31. While a timed event of a "Never Record" calendar, or a timed event marked "Do Not Record", is in progress, no Life Log audio chunk is created, and recording resumes after the event if the recording intent remains.
32. Ending an event with enough speech while Life Log AI is on with the automatic trigger produces exactly one note. Relaunching or refreshing the calendar produces no duplicate. An event that ended earlier the same day is handled at the next launch, pending transcription is waited for, and a note whose event moved or whose sources were deleted is marked and offers regeneration.
33. Deleting the Life Log and "Reset Lore…" remove every AI note and AI event exclusion.
34. A repeating event in progress whose earlier occurrence has recorded speech shows "Last time" with that date in the mini window and the timeline, with that occurrence's action items and open questions when it has notes. The first occurrence and an event that holds capture show nothing, and selecting the date opens that day.
