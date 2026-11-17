# LingoSlate

<img src="Resources/LingoSlate-AppIcon-v2.png" alt="LingoSlate app icon" width="128">

LingoSlate is an open-source bilingual lecture and meeting companion for English-to-Simplified-Chinese transcription, translation, recording, and review. It provides a native macOS application with local and cloud processing modes, plus an iPhone companion that uses Soniox through a self-hosted credential broker.

> LingoSlate is a development preview. It is not currently distributed through the Mac App Store or App Store, and the repository does not include notarized binaries or a hosted Soniox service.

## Highlights

- Live English and Simplified Chinese subtitles for lectures and meetings.
- Optional course name, course code, lecturer, accent, school, and terminology context.
- Two local macOS recognition modes using FluidAudio Parakeet models.
- On-device Apple Translation with optional TranslateGemma refinement on macOS.
- Soniox cloud transcription and translation on macOS and iPhone.
- Local AAC M4A recording, atomic transcript checkpoints, and interrupted-session recovery.
- Searchable session history with summaries, bilingual transcripts, playback, and deletion.
- Listening-practice export with audio, English SRT, bilingual SRT, and timestamped text.
- Markers for bookmarks, important points, questions, and action items.
- A live switch that can hide Chinese subtitles while translation continues in the background.
- Chinese audience discussion is preserved in the source transcript but excluded from English-to-Chinese translation and summary context.

## Supported Platforms

| Platform | Minimum version | Processing options | Audio source |
| --- | --- | --- | --- |
| macOS | macOS 15 | Energy-saving local, high-accuracy local, or Soniox | Microphone |
| iPhone | iOS 18 | Soniox through a self-hosted broker | Microphone |

System-audio and mixed-audio capture are visible as future options in the macOS interface but are currently disabled. The supported public workflow is microphone capture.

## Processing Modes

| Mode | Transcription | Translation | Network use |
| --- | --- | --- | --- |
| Energy-saving | Local Parakeet EOU 120M | Apple Translation | Model and language-pack downloads only |
| High accuracy | Local Parakeet Unified 0.6B plus offline refinement | Apple Translation followed by TranslateGemma refinement | Model and language-pack downloads only |
| Soniox | Soniox `stt-rt-v5` | Soniox English-to-Chinese translation | Live microphone audio and prepared course context are sent to Soniox |

Local modes keep classroom audio, transcription, translation, summaries, and session files on the Mac after required models have been downloaded. Soniox mode keeps the recording and saved session locally but sends live audio and approved context to Soniox for processing.

## Requirements

- Apple Silicon Mac recommended.
- macOS 15 or later.
- Xcode 26 or later with Swift 6.2.
- Xcode Metal Toolchain for TranslateGemma/MLX builds.
- iOS 18 or later for the iPhone target.
- Node.js 22 or later and a Cloudflare account for the optional iPhone broker.
- A Soniox account and API key for Soniox mode.
- Approximately 4 GB of free space for all optional local models, plus space for recordings.

## Quick Start: macOS Local Mode

```bash
git clone https://github.com/Timmor51z/leccue.git
cd leccue

sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
xcodebuild -downloadComponent MetalToolchain

swift test --disable-sandbox
./scripts/build-macos-app.sh
open .build/LingoSlate.app
```

On first launch, allow microphone access. Choose **Energy-saving** for the smallest model download or **High accuracy** for the full local pipeline. The course name is optional.

The build script creates an ad-hoc signed development application at `.build/LingoSlate.app`. See [Deployment Guide](docs/DEPLOYMENT.md) for Xcode paths, Soniox setup, iPhone installation, and release-signing limitations.

## Quick Start: Soniox on macOS

1. Create a Soniox API key in your own Soniox account.
2. Open LingoSlate profile settings.
3. Save the key in the **Soniox** section.
4. Select **Soniox** in the classroom mode picker.

The key is stored in macOS Keychain and is not written to session files. You can also supply `SONIOX_API_KEY` to development and benchmark commands without saving it in the app.

## Quick Start: iPhone

The iPhone app does not contain a permanent Soniox key. Before running it, deploy your own Cloudflare Worker from `Backend/soniox-key-broker`, then enter its HTTPS endpoint and broker token in the app settings.

```bash
cd Backend/soniox-key-broker
npm ci
npm test
cp .dev.vars.example .dev.vars
# Edit .dev.vars with your own Soniox key and a random broker token.
npx wrangler login
npx wrangler deploy --secrets-file .dev.vars
```

Open `Apps/LingoSlateIOS/LingoSlateIOS.xcodeproj`, select your Apple development team, use a unique bundle identifier, and run the `LingoSlateIOS` scheme on an iPhone running iOS 18 or later.

Full instructions and the security boundary of the broker are documented in the [Deployment Guide](docs/DEPLOYMENT.md).

## Usage

The normal workflow is:

1. Optionally enter the course name and course context.
2. Choose a processing mode.
3. Select and test the microphone on macOS, or configure the broker on iPhone.
4. Start the lecture and add markers when useful.
5. Toggle Chinese subtitle visibility without stopping background translation.
6. End the session and wait for any local post-processing to finish.
7. Review, play, search, or export the saved session from history.

See the [User Guide](docs/USER_GUIDE.md) for mode selection, first-run downloads, session recovery, exports, data locations, and troubleshooting.

## Local Data

macOS sessions are stored under:

```text
~/Library/Application Support/LingoSlate/Sessions/
```

Each completed session normally has a JSON document and a matching M4A recording named with the same UUID. A one-hour 48 kbps recording typically uses about 22 MB. Models are downloaded separately and are never committed to this repository.

Private recordings, exports, model caches, benchmark inputs, local credentials, and `node_modules` are excluded by `.gitignore`.

## Privacy and Responsible Recording

- Obtain permission and follow your institution, workplace, and local recording rules.
- Local mode does not make a recording lawful by itself.
- Soniox mode sends audio and prepared context to a third-party cloud service.
- The iPhone app always uses Soniox for live transcription and translation in the current release.
- Never commit `.dev.vars`, API keys, broker tokens, recordings, or session exports.

See [SECURITY.md](SECURITY.md) for credential handling and vulnerability reporting.

## Architecture

```text
Sources/
  LingoSlateCore/          Shared session, transcript, glossary, and pipeline logic
  LingoSlateAudio/         macOS microphone capture, local ASR, and recording
  LingoSlateSoniox/        Shared Soniox WebSocket adapter
  LingoSlateTranslation/   MLX TranslateGemma integration
  LingoSlateMac/           Native macOS SwiftUI application
  LingoSlateMobile/        iOS capture, persistence, history, and SwiftUI interface
Apps/
  LingoSlateIOS/           Native iPhone Xcode project
Backend/
  soniox-key-broker/       Self-hosted Cloudflare Worker for temporary Soniox keys
Tests/
  LingoSlateCoreTests/
  LingoSlateMacTests/
  LingoSlateMobileTests/
```

The shared package targets macOS 15 and iOS 18. FluidAudio and MLX dependencies remain outside the iPhone cloud path; the mobile app depends only on the shared core and Soniox adapter.

## Development

Run the full Swift test suite:

```bash
swift test --disable-sandbox
```

Run the broker tests:

```bash
cd Backend/soniox-key-broker
npm ci
npm test
```

Run the local recognition adapter against an audio file:

```bash
swift run LingoSlateASRSmoke /path/to/english-audio.wav
```

Additional engineering notes are available in [PRODUCT_DESIGN.md](PRODUCT_DESIGN.md), [MVP_STATUS.md](MVP_STATUS.md), and [BENCHMARKING.md](BENCHMARKING.md). Benchmark results that compare against another product are agreement diagnostics, not ground-truth word error rates.

## Known Limitations

- English-to-Simplified-Chinese is the implemented language direction.
- macOS system-audio and mixed-audio capture are not enabled.
- iPhone requires a self-hosted broker and Soniox account.
- The included broker uses a shared bearer token and is suitable only for personal or small trusted deployments. A public hosted service needs user authentication, App Attest, rate limits, quotas, monitoring, and abuse controls.
- The repository does not include Apple distribution certificates, provisioning profiles, notarization, or App Store configuration.
- Model downloads are large and the first high-accuracy warmup can take several minutes.

## License

LingoSlate is available under the [MIT License](LICENSE). Third-party models and services retain their own terms, including the [Gemma Terms of Use](https://ai.google.dev/gemma/terms), FluidAudio model licenses, Apple platform terms, and Soniox service terms.
