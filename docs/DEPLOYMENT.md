# LingoSlate Deployment Guide

This guide covers source builds for macOS and iPhone, optional Soniox configuration, and deployment of the self-hosted Soniox credential broker.

## 1. Choose a Deployment Path

| Goal | Required components |
| --- | --- |
| macOS local transcription and translation | Xcode, Metal Toolchain, local model downloads |
| macOS Soniox mode | macOS app and your own Soniox API key |
| iPhone companion | Xcode, Apple signing team, Soniox account, self-hosted broker |
| Public hosted iPhone service | All iPhone components plus real user authentication, App Attest, quotas, rate limiting, monitoring, and billing controls |

The repository does not provide a shared Soniox account or production authentication service.

## 2. Prerequisites

### Apple development

- Apple Silicon Mac recommended.
- macOS 15 or later.
- Xcode 26 or later with Swift 6.2.
- At least 8 GB free while compiling dependencies; approximately 4 GB for optional runtime models.
- Apple Developer account for physical-device signing and distribution.

Select Xcode when it is installed in the normal location:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
```

If Xcode is installed elsewhere, do not change the system selection unless needed. Set `DEVELOPER_DIR` for the current shell instead:

```bash
export DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer
```

Install the optional Metal Toolchain used by MLX:

```bash
xcodebuild -downloadComponent MetalToolchain
```

### Broker development

- Node.js 22 or later.
- Cloudflare account.
- Soniox account with available credit and a permanent API key.

## 3. Build the macOS Application

Clone and verify the repository:

```bash
git clone https://github.com/Timmor51z/LingoSlate.git
cd LingoSlate
swift package resolve
swift test --disable-sandbox
```

Build the development application bundle:

```bash
./scripts/build-macos-app.sh
open .build/LingoSlate.app
```

The script:

1. Builds the `LingoSlateMac` Swift package product.
2. Builds or locates the MLX Metal library.
3. Generates the macOS icon set.
4. Creates `.build/LingoSlate.app`.
5. Applies an ad-hoc local signature.

The resulting bundle is suitable for local development. It is not notarized for general distribution.

### Model cache locations

LingoSlate downloads local ASR and translation models on first use. Development builds support:

```bash
export LINGOSLATE_TRANSLATION_MODEL_PATH=/path/to/existing/translategemma-snapshot
export LINGOSLATE_MODEL_CACHE_PATH=/path/to/model-cache
```

The first variable uses an existing TranslateGemma snapshot. The second relocates future model downloads, which is useful when an external APFS disk has more free space.

## 4. Configure Soniox on macOS

The Mac app can call Soniox directly because the API key is stored in the user's macOS Keychain.

1. Create a Soniox API key in your own account.
2. Open LingoSlate.
3. Open profile settings.
4. Enter the key in the **Soniox** section and select **Save**.
5. Select **Soniox** in the classroom processing-mode picker.

For command-line development tools, set the key only for the current command or shell:

```bash
export SONIOX_API_KEY=your-key
swift run LingoSlateASRSmoke --soniox /path/to/audio.wav
```

Avoid placing a real key in shell scripts, Git-tracked files, screenshots, or issue reports.

## 5. Deploy the Soniox Key Broker

The iPhone app requests a restricted, single-use Soniox temporary key from a Cloudflare Worker. The permanent Soniox key must remain in Worker secrets and must never be embedded in the app.

Install dependencies and run tests:

```bash
cd Backend/soniox-key-broker
npm ci
npm test
```

Create local secret configuration:

```bash
cp .dev.vars.example .dev.vars
openssl rand -hex 32
```

Edit `.dev.vars`:

```dotenv
SONIOX_API_KEY=your-permanent-soniox-key
LINGOSLATE_CLIENT_TOKEN=the-random-token-generated-above
```

Authenticate and deploy:

```bash
npx wrangler login
npx wrangler deploy --secrets-file .dev.vars
```

Verify the health endpoint using the Worker URL printed by Wrangler:

```bash
curl https://your-worker.workers.dev/health
```

Expected response:

```json
{"status":"ok"}
```

The temporary-key endpoint is:

```text
https://your-worker.workers.dev/v1/soniox/temporary-key
```

The Worker issues a key that:

- is limited to `transcribe_websocket` usage;
- must be used within 60 seconds;
- opens one stream; and
- caps the stream at four hours.

### Important production boundary

The included bearer-token check is intentionally small and is appropriate only when every user is trusted and deploys or privately shares the broker. Do not operate it as an unrestricted public service.

A public hosted deployment should add, at minimum:

- authenticated users and revocable sessions;
- Apple App Attest verification;
- per-user and per-device rate limits;
- daily and monthly spending quotas;
- abuse monitoring and alerting;
- server-side audit records that do not contain lecture audio or API keys; and
- a clear privacy policy and deletion process.

## 6. Build and Install the iPhone Application

1. Deploy the broker first.
2. Open `Apps/LingoSlateIOS/LingoSlateIOS.xcodeproj` in Xcode.
3. Select the `LingoSlateIOS` target.
4. Under **Signing & Capabilities**, choose your Apple development team.
5. Change `PRODUCT_BUNDLE_IDENTIFIER` to a unique reverse-domain identifier you control.
6. Select an iPhone running iOS 18 or later.
7. Build and run the `LingoSlateIOS` scheme.
8. Allow microphone access on first launch.
9. Open the app settings and enter:
   - the broker temporary-key endpoint; and
   - the same `LINGOSLATE_CLIENT_TOKEN` used by your Worker.
10. Save the settings before starting a session.

The endpoint is stored in preferences. The broker token is stored in iOS Keychain. The permanent Soniox key remains on Cloudflare.

## 7. Distribution Builds

The repository intentionally does not include Apple certificates, provisioning profiles, or App Store credentials.

For macOS distribution to users who do not build from source, replace the ad-hoc signature with your own Developer ID Application signature, enable the hardened runtime, package the app, submit it to Apple's notary service, and staple the result. Review entitlements and privacy strings before release.

For iOS distribution, configure App Store Connect, versioning, signing, privacy disclosures, background-audio justification, and TestFlight/App Store review metadata in your own Apple developer account.

Do not publish a build that contains your personal Soniox key or a shared unrestricted broker token.

## 8. Verification Checklist

Before sharing a build:

```bash
swift test --disable-sandbox

cd Backend/soniox-key-broker
npm ci
npm test
```

Then verify manually:

- microphone permission is requested and audio level moves;
- a short session produces English and Chinese text;
- ending a session creates a JSON document and M4A recording;
- history can reopen the session and play its audio;
- listening-practice export contains the expected files;
- local modes work without a Soniox key;
- Soniox mode fails safely when credentials are absent or invalid;
- iPhone settings contain your broker URL, not another developer's endpoint; and
- no `.dev.vars`, API keys, broker tokens, recordings, or exports are staged in Git.

## 9. Common Problems

### `xcodebuild` says Command Line Tools are active

Point `xcode-select` or `DEVELOPER_DIR` at a complete Xcode installation, not `/Library/Developer/CommandLineTools`.

### MLX cannot find its Metal library

Install the Metal Toolchain and rerun `./scripts/build-macos-app.sh`.

### First local start takes several minutes

The ASR and translation models are downloaded and prepared on first use. Use Energy-saving mode for the smallest first download.

### Apple Translation is unavailable

Open System Settings and allow macOS to download the English and Simplified Chinese language assets when prompted.

### Broker returns `401`

The token saved in the iPhone app must exactly match `LINGOSLATE_CLIENT_TOKEN` deployed to the Worker.

### Broker returns `429` or `502`

Check Soniox credit, account limits, Worker logs, and upstream service status. The Worker intentionally does not return private Soniox error details to the client.

### Recording exists but post-processing is incomplete

Reopen LingoSlate and use session history. The app checkpoints stable transcript segments and attempts to recover readable interrupted recordings.
