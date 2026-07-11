# LecCue

LecCue is a local-first bilingual classroom companion for international students. The first product is a native macOS app; the shared Swift core is designed for a planned iPhone companion. `ClassBridge` remains the temporary internal Swift module name while the product branding is migrated.

## Current slice

This repository currently contains the first local microphone vertical slice:

- Cross-platform course, session, glossary, marker, and transcript models.
- Replaceable speech recognition, translation, and summary protocols.
- Session lifecycle validation.
- A bilingual subtitle pipeline with provisional and final segment handling.
- Atomic JSON session persistence.
- AVAudioEngine microphone permission, capture, and 16 kHz mono conversion.
- FluidAudio Parakeet EOU 120M energy-saving recognition with adaptive gain and limiting.
- FluidAudio Parakeet Unified 0.6B high-accuracy streaming recognition at 1120 ms context.
- An automatic full-context offline transcription pass before high-accuracy sessions are saved.
- In-memory session audio buffering that is released after the offline pass and never persisted.
- A native SwiftUI macOS workspace with live input level and real subtitle events.
- Twenty unit tests across the shared core and audio buffer.

Energy-saving mode downloads an approximately 120 MB model. High-accuracy mode progressively caches approximately 1.2 GB for its real-time and after-class encoders, then starts from the local Core ML cache. A one-hour 16 kHz mono session uses about 230 MB of temporary memory for the after-class pass. Audio and recognition remain on the Mac. Chinese translation is still a placeholder and is the next production adapter.

## Build

```bash
DEVELOPER_DIR=/Volumes/Disk/Applications/Xcode.app/Contents/Developer swift build --disable-sandbox
DEVELOPER_DIR=/Volumes/Disk/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox
DEVELOPER_DIR=/Volumes/Disk/Applications/Xcode.app/Contents/Developer swift run --disable-sandbox ClassBridgeMac
```

Build a foreground development app with microphone permission metadata and an ad-hoc signature:

```bash
./scripts/build-macos-app.sh
open .build/LecCue.app
```

A complete Xcode installation is required for App Store signing, ScreenCaptureKit, and device testing. The script produces a local development bundle, not a release archive.

Run the local recognition adapter against a known audio file:

```bash
swift run LecCueASRSmoke /path/to/english-audio.wav
```

## Structure

```text
Sources/
  ClassBridgeCore/       Shared macOS/iOS domain and pipeline
  ClassBridgeAudio/      Shared local capture and FluidAudio adapters
  ClassBridgeMac/        Native macOS application
  LecCueASRSmoke/        Local audio-file recognition smoke tool
Tests/
  ClassBridgeCoreTests/  Shared core tests
```

See [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md) for product scope, architecture, quality targets, and roadmap.
