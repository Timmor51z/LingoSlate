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
- Conservative course-name and optional term normalization for proper nouns and technical vocabulary.
- Local user profile settings for school and country or region.
- Course warmup that prepares editable terms and preloads the selected real-time model.
- On-device English-to-Simplified-Chinese translation through Apple Translation.
- Two-stage high-accuracy translation: Apple Translation appears first, then a local
  TranslateGemma 4B pass replaces it with a more natural classroom translation.
- Phrase-level New Zealand academic terminology for ambiguous course language such as
  paper outlines, lab attendance, and tutorial priority.
- Verbatim protection for course codes and institution-specific names, plus a quality gate
  that keeps the Apple draft when a refined translation loses a number or protected term.
- Automatic Traditional-to-Simplified Chinese normalization on local refined translations.
- Non-blocking translation jobs so English subtitles remain responsive while Chinese is prepared.
- Automatic post-class summaries using Apple Foundation Models with a deterministic local fallback.
- Persisted overview, key concepts, timestamped tasks, and a summary/transcript review switcher.
- Audio-input preflight that reports a missing microphone instead of crashing on headless Macs.
- iPhone Continuity Camera microphone support through the selected macOS input device.
- A native SwiftUI macOS workspace with live input level and real subtitle events.
- Fifty-three tests across the shared core, audio capture, translation, summary, and macOS UI adapters.

Energy-saving mode downloads an approximately 120 MB model. High-accuracy mode progressively caches approximately 1.2 GB for its real-time and after-class encoders. Course warmup also downloads a pinned approximately 2.22 GB MLX TranslateGemma model for the second-stage translation pass. A one-hour 16 kHz mono session uses about 230 MB of temporary memory for the after-class pass. Audio, recognition, and translation remain on the Mac. Apple may ask the user to download the English and Simplified Chinese language package the first time translation is prepared. TranslateGemma is distributed under the [Gemma terms](https://ai.google.dev/gemma/terms) and is downloaded separately rather than bundled in LecCue.

Course warmup also prepares Apple Translation so the first stable English clause can be translated without waiting for language-model setup. On macOS 26 or later, warmup uses the on-device Apple Foundation Model when available to propose likely English terminology. The suggestions remain editable before the class starts. When Apple Intelligence is unavailable, LecCue still warms the ASR model and derives conservative terms from the course and school names.

After a session ends, LecCue stores a local summary beside the bilingual transcript. Apple Foundation Models produces a concise Chinese summary when available. The fallback remains useful without Apple Intelligence by extracting translated overview points, course terminology, repeated concepts, and timestamped assignment or deadline cues.

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

MLX requires Xcode's optional Metal toolchain. Install it once before the first app build:

```bash
DEVELOPER_DIR=/Volumes/Disk/Applications/Xcode.app/Contents/Developer \
  xcodebuild -downloadComponent MetalToolchain
```

For development, `LECCUE_TRANSLATION_MODEL_PATH` may point at an already downloaded
MLX model snapshot, and `LECCUE_MODEL_CACHE_PATH` can move future model downloads to
an external disk.

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
  ClassBridgeTranslation/ Native MLX translation adapter
  ClassBridgeMac/        Native macOS application
  LecCueASRSmoke/        Local audio-file recognition smoke tool
  LecCueBenchmark/       Private same-audio ASR benchmark
  LecCueTranslationBenchmark/ Private sampled translation benchmark
Tests/
  ClassBridgeCoreTests/  Shared core tests
```

See [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md) for product scope, architecture, quality targets, and roadmap.
