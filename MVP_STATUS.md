# MVP implementation status

## Completed

- Shared Swift package structure for macOS and future iOS clients.
- Course, glossary, session, marker, and bilingual transcript models.
- Replaceable recognition, translation, and summary protocols.
- Validated session lifecycle transitions.
- Provisional-to-final subtitle pipeline with translation context.
- Atomic local JSON session persistence.
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
- Foreground `LecCue.app` development bundle with microphone usage metadata and ad-hoc signing.
- Audio-file smoke tool for repeatable local ASR verification.
- Finalization silence padding so the last spoken word is not truncated.
- Private LecSync benchmark importer with signed URLs and account metadata removed.
- Same-audio local benchmark runner with five-minute alignment windows, word coverage, critical-token recall, and runtime measurements.
- Revision-tolerant streaming transcript cursor that prevents cumulative model output from being emitted twice.
- Adaptive classroom gain with silence protection and peak limiting for the 120M energy-saving tier.
- Parakeet Unified 0.6B streaming high-accuracy tier with retained long-session context.
- User-selectable energy-saving and high-accuracy modes in the macOS workspace.
- Benchmark model/audio selectors for repeatable local A/B comparisons.

## Verification status

- Xcode 26.6 is installed on the external APFS volume at `/Volumes/Disk/Applications/Xcode.app`.
- All Swift source files pass `swiftc -parse`.
- Full package build and tests run with the external Xcode selected through `DEVELOPER_DIR`.
- `swift test` builds the shared core, Mac executable, and test bundle successfully.
- All 17 core tests pass, covering adaptive gain and limiting, comparison metrics, revised streaming transcripts, audio levels, course readiness, approved terminology, lifecycle transitions, subtitle translation, and JSON persistence.

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
6. Pass final segments into the bilingual subtitle pipeline.
7. Persist the completed session locally.

## Next production slice

1. Replace the placeholder translator with Apple `TranslationSession`.
2. Add inverse text normalization for dates, times, and numbers.
3. Add model download progress, cancellation, and preflight readiness.
4. Run live subtitle, battery, thermal, and 90-minute soak tests.
5. Add a high-accuracy overlapping-window post-class transcription pass.

Soniox, automatic course preparation, and summary generation follow after the local bilingual path is stable.
