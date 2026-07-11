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

## Verification status

- Xcode 26.6 is installed on the external APFS volume at `/Volumes/Disk/Applications/Xcode.app`.
- All Swift source files pass `swiftc -parse`.
- Full package build and tests run with the external Xcode selected through `DEVELOPER_DIR`.
- `swift test` builds the shared core, Mac executable, and test bundle successfully.
- All 14 core tests pass, covering comparison metrics, revised streaming transcripts, audio levels, course readiness, approved terminology, lifecycle transitions, subtitle translation, and JSON persistence.

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
2. Download the approximately 120 MB Parakeet EOU model on first use.
3. Capture and convert microphone audio locally.
4. Emit provisional and final English segments from FluidAudio.
5. Pass final segments into the bilingual subtitle pipeline.
6. Persist the completed session locally.

## Next production slice

1. Evaluate a higher-accuracy local recognizer against the saved private benchmark.
2. Add inverse text normalization for dates, times, and numbers.
3. Replace the placeholder translator with Apple `TranslationSession`.
4. Add model download progress, cancellation, and preflight readiness.
5. Run live subtitle, battery, thermal, and 90-minute soak tests.

Soniox, automatic course preparation, and summary generation follow after the local bilingual path is stable.
