# LingoSlate User Guide

LingoSlate creates English and Simplified Chinese subtitles for lectures and meetings while saving a local recording and reviewable transcript.

## 1. Before Recording

### Follow recording rules

Ask for permission where required and follow the rules of the classroom, workplace, institution, and country. LingoSlate shows and stores a recording, but it cannot determine whether a particular recording is lawful.

### Choose a Mac processing mode

| Mode | Best for | Trade-off |
| --- | --- | --- |
| Energy-saving | Battery life, smaller download, ordinary speech | Lower recognition accuracy on difficult accents and technical lectures |
| High accuracy | Technical lectures, difficult accents, post-class refinement | Larger downloads, more memory, longer warmup and finalization |
| Soniox | Lowest setup burden and strongest cloud recognition | Requires internet, Soniox credit, and cloud audio processing |

The iPhone app uses Soniox in the current release.

### Add course context when available

The course name is optional. You can start immediately without any material.

Context can include:

- course name and code;
- a short topic description;
- lecturer name;
- Indian English profile when applicable;
- school and country or region; and
- reviewed technical terms, acronyms, product names, and proper nouns.

Use course warmup on macOS when you have time before class. It prepares terms and models, but it is not required to start recording.

## 2. macOS First Run

1. Open LingoSlate.
2. Allow microphone access.
3. Choose **Lecture** or **Meeting**.
4. Choose **Energy-saving**, **High accuracy**, or **Soniox**.
5. At the bottom of the window, select the microphone.
6. Use the microphone test button and listen to the 15-second sample.
7. Confirm the input-level meter responds to speech.

An iPhone Continuity microphone may appear as an input device when macOS makes it available. Select it explicitly if you intend to use it; otherwise choose the MacBook or an external microphone.

If you select Soniox, save your API key in profile settings first.

## 3. During a Session

Select **Start** to begin recording and transcription.

The workspace shows:

- original English text;
- Simplified Chinese translation when available;
- current microphone and input level;
- processing/translation status;
- elapsed time; and
- warnings for weak input, dropped frames, or service errors.

### Hide Chinese without stopping translation

Turn off **Show Chinese** to practise listening with English-only subtitles. Translation continues in the background and remains available in the saved session.

### Add markers

Use the marker buttons while listening:

- **Bookmark** for a location to revisit;
- **Important** for a key concept;
- **Question** for something to ask or research; and
- **Task** for an assignment, deadline, or action item.

Markers are included in the saved session and can influence the post-class summary.

### Correct English text

Use the edit control beside a finalized English segment to correct an important term or recognition error. LingoSlate regenerates the corresponding Chinese translation and stores correction history scoped to the course, lecturer, and accent profile.

## 4. Ending a Session

Select **Stop** once. LingoSlate first closes recording and live recognition, saves a recoverable checkpoint, and then performs optional local post-processing.

High-accuracy mode can take longer because it may replay the saved audio and refine translations. Keep the app open until it reports completion, or use the available skip action when you need the live transcript immediately.

Closing a MacBook for ten minutes during an active session triggers automatic session finalization. A shorter sleep keeps the session active when capture can resume safely.

## 5. Review and Export on macOS

Open **History** from the classroom toolbar.

You can:

- search saved sessions;
- switch between summary and bilingual transcript;
- play the recording;
- reveal the recording in Finder;
- export a listening-practice package; and
- delete the session and its linked recording.

The listening-practice export contains, when audio is available:

```text
recording.m4a
english.srt
bilingual.srt
transcript.txt
```

Session files are stored locally under:

```text
~/Library/Application Support/LingoSlate/Sessions/
```

Do not edit session JSON while LingoSlate is running.

## 6. iPhone Setup and Use

The iPhone app requires a self-hosted Soniox broker. Ask the person who deployed your build for:

- the HTTPS temporary-key endpoint; and
- the broker token.

Open **Settings**, enter both values, and select **Save**.

Before a class, open **Course Context** to enter optional course, lecturer, school, region, and terminology information. Select **Prepare Terms** to merge safe suggestions with your manual list.

Return to the main screen, allow microphone access, and start the session. The app saves the recording and bilingual transcript locally while Soniox provides live transcription and translation.

Open **History** to review, play, share, or delete saved mobile sessions.

## 7. Privacy by Mode

### macOS local modes

- Microphone audio is processed locally after models are downloaded.
- Recording, transcript, translation, and summary remain on the Mac.
- Apple and model-hosting services may be contacted for required language assets and model downloads.

### Soniox mode

- Live microphone audio is sent to Soniox.
- Prepared course context and approved terminology may be sent with the stream.
- The local app stores the recording, transcript, and summary.
- Consult Soniox terms and privacy information before use.

### Credentials

- macOS stores the Soniox API key in Keychain.
- iPhone stores the broker token in Keychain.
- The permanent iPhone Soniox key belongs only in Worker secrets.

## 8. Troubleshooting

### No microphone activity

- Check System Settings or iOS Settings for microphone permission.
- Select the intended device again.
- On macOS, refresh the input-device list and run the microphone test.
- Disconnect unstable Continuity or Bluetooth devices when diagnosing capture problems.

### Subtitles are delayed

- Verify the network before using Soniox.
- Keep the microphone close to the lecturer and avoid covering it.
- Use High accuracy for difficult local lectures, but expect longer post-processing.
- Use Energy-saving when latency and battery life matter more than difficult-accent accuracy.

### Soniox stops after a network interruption

LingoSlate retries recoverable WebSocket failures and preserves finalized text. If it cannot reconnect, end the session so the saved recording and existing transcript can be finalized, then start a new session after the network is stable.

### Chinese text is missing

- Confirm **Show Chinese** is enabled for live display.
- In local mode, make sure the Apple English and Simplified Chinese language assets are installed.
- In Soniox mode, confirm the key or broker is configured and has credit.

### A session was not ended manually

Reopen LingoSlate and check History. Stable transcript data is checkpointed during class, and the app attempts to recover readable recordings. A Mac sleep lasting ten minutes also triggers automatic finalization.

### Disk usage is growing

Recordings use approximately 22 MB per hour, while optional models use several gigabytes. Export sessions you need, delete sessions from History, and remove model caches only when you are prepared to download them again.
