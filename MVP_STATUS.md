# MVP implementation status

## Completed

- Shared Swift package structure for macOS and future iOS clients.
- Course, glossary, session, marker, and bilingual transcript models.
- Replaceable recognition, translation, and summary protocols.
- Validated session lifecycle transitions.
- Provisional-to-final subtitle pipeline with translation context.
- Atomic local JSON session persistence.
- Local 16 kHz mono AAC M4A recording linked to each saved session, with playback and Finder access.
- Bounded subtitle and microphone event streams, 10 Hz input metering, and disk-backed after-class audio replay for long-session stability.
- Energy-saving recognition by default, sequential heavyweight model warmup, and explicit post-class translation progress.
- Native macOS SwiftUI classroom workspace.
- Deterministic recognition and translation adapters for end-to-end UI development.
- Unit tests covering zero-preparation courses, approved terminology, lifecycle transitions, subtitle translation, and persistence.
- FluidAudio 0.15.5 integrated and version-locked through Swift Package Manager.
- AVAudioEngine microphone permission and capture lifecycle.
- Real-time conversion to 16 kHz mono Float32 audio frames.
- Live input-level monitoring in the classroom status bar.
- Fully local Parakeet EOU 120M streaming recognition through FluidAudio.
- Cumulative streaming transcript de-duplication across end-of-utterance boundaries.
- Unsupported system-audio and cloud controls disabled until their adapters exist.
- Foreground `LingoSlate.app` development bundle with microphone usage metadata and ad-hoc signing.
- Audio-file smoke tool for repeatable local ASR verification.
- Finalization silence padding so the last spoken word is not truncated.
- Private LecSync benchmark importer with signed URLs and account metadata removed.
- Same-audio local benchmark runner with five-minute alignment windows, word coverage, critical-token recall, and runtime measurements.
- Revision-tolerant streaming transcript cursor that prevents cumulative model output from being emitted twice.
- Adaptive classroom gain with silence protection and peak limiting for the 120M energy-saving tier.
- Parakeet Unified 0.6B streaming high-accuracy tier with retained long-session context.
- User-selectable energy-saving and high-accuracy modes in the macOS workspace.
- Benchmark model/audio selectors for repeatable local A/B comparisons.
- Local school and country or region profile settings.
- Course-name warmup for terminology and real-time/post-class ASR models.
- Apple Translation integration for on-device English-to-Simplified-Chinese subtitles.
- Non-blocking translation jobs that keep English subtitles live during translation preparation.
- Local post-class summary generation with Apple Foundation Models and a deterministic fallback.
- Persisted overview, concepts, timestamped actions, and summary/full-transcript review views.
- Missing-input-device preflight that prevents AVAudioEngine crashes on Macs without a microphone.
- iPhone Continuity Camera microphone verified on a Mac mini at the app's 16 kHz capture rate.

## Verification status

- Xcode 26.6 is installed on the external APFS volume at `/Volumes/Disk/Applications/Xcode.app`.
- All Swift source files pass `swiftc -parse`.
- Full package build and tests run with the external Xcode selected through `DEVELOPER_DIR`.
- `swift test` builds the shared core, Mac executable, and test bundle successfully.
- All 59 tests pass, with one optional local-model smoke test skipped when its model path is not configured. Coverage includes bounded snapshot delivery, adaptive gain and limiting, comparison metrics, revised streaming transcripts, audio input preflight, M4A encoding, decoding, and chunked replay, optional course naming, approved terminology, brand migration, lifecycle transitions, non-blocking subtitle translation, Apple translation coordination, deterministic summaries, long-session sampling, summary rendering, and JSON persistence.

Set the external Xcode as the active developer directory once:

```bash
sudo xcode-select -s /Volumes/Disk/Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
xcodebuild -version
swift test
```

## Current runtime path

1. Request microphone permission.
2. Select the 120M energy-saving tier or Unified 0.6B high-accuracy tier.
3. Download the selected local model on first use (approximately 120 MB or 595 MB).
4. Capture and convert microphone audio locally; apply adaptive gain only to the energy-saving tier.
5. Emit provisional and final English segments from FluidAudio.
6. Publish final English segments immediately and translate them locally through Apple Translation.
7. Generate a local structured summary with deterministic fallback behavior.
8. Persist the original M4A recording, completed bilingual session, and summary locally.

## Next production slice

1. Add inverse text normalization for dates, times, and numbers.
2. Add detailed model download progress and preflight readiness.
3. Run live subtitle, battery, thermal, and 90-minute soak tests.
4. Add Markdown, text, SRT, and VTT bilingual export.

Soniox and source-attributed automatic course preparation follow after the local bilingual path is stable.
