# ClassBridge

ClassBridge is a local-first bilingual classroom companion for international students. The first product is a native macOS app; the shared Swift core is designed for a planned iPhone companion.

## Current slice

This repository currently contains the first executable architecture slice:

- Cross-platform course, session, glossary, marker, and transcript models.
- Replaceable speech recognition, translation, and summary protocols.
- Session lifecycle validation.
- A bilingual subtitle pipeline with provisional and final segment handling.
- Atomic JSON session persistence.
- A native SwiftUI macOS workspace backed by a deterministic demo engine.
- Core unit tests.

The demo engine validates UI and event flow without pretending to be the production recognizer. The next adapter will connect microphone audio to FluidAudio after a full Xcode installation is available.

## Build

```bash
swift build
swift test
swift run ClassBridgeMac
```

The command-line Swift toolchain can build the package. A complete Xcode installation is still required for microphone permission descriptions, signing, app bundling, ScreenCaptureKit, and device testing.

## Structure

```text
Sources/
  ClassBridgeCore/       Shared macOS/iOS domain and pipeline
  ClassBridgeMac/        Native macOS application
Tests/
  ClassBridgeCoreTests/  Shared core tests
```

See [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md) for product scope, architecture, quality targets, and roadmap.
