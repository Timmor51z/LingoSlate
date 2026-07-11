# MVP implementation status

## Completed in the first slice

- Shared Swift package structure for macOS and future iOS clients.
- Course, glossary, session, marker, and bilingual transcript models.
- Replaceable recognition, translation, and summary protocols.
- Validated session lifecycle transitions.
- Provisional-to-final subtitle pipeline with translation context.
- Atomic local JSON session persistence.
- Native macOS SwiftUI classroom workspace.
- Deterministic recognition and translation adapters for end-to-end UI development.
- Unit tests covering zero-preparation courses, approved terminology, lifecycle transitions, subtitle translation, and persistence.

## Verification status

- Xcode 26.6 is installed on the external APFS volume at `/Volumes/Disk/Applications/Xcode.app`.
- All Swift source files pass `swiftc -parse`.
- Full package build and tests run with the external Xcode selected through `DEVELOPER_DIR`.
- `swift test` builds the shared core, Mac executable, and test bundle successfully.
- All 5 core tests pass, covering course readiness, approved terminology, lifecycle transitions, subtitle translation, and JSON persistence.

Set the external Xcode as the active developer directory once:

```bash
sudo xcode-select -s /Volumes/Disk/Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
xcodebuild -version
swift test
```

## Next production slice

1. Add FluidAudio through Swift Package Manager.
2. Implement AVAudioEngine microphone capture and 16 kHz mono conversion.
3. Connect streaming audio frames to a local recognition adapter.
4. Replace the demo translator with Apple TranslationSession.
5. Add microphone permission descriptions and signed app bundling.
6. Run live subtitle, battery, thermal, and 90-minute soak tests.

Soniox, system audio capture, automatic course preparation, and summary generation follow after the local microphone path is stable.
