# MVP implementation status

## Completed

- Shared Swift package structure for macOS and iOS clients.
- Course, glossary, session, marker, and bilingual transcript models.
- Replaceable recognition, translation, and summary protocols.
- Validated session lifecycle transitions.
- Provisional-to-final subtitle pipeline with translation context.
- Incremental atomic session checkpoints plus failure-path JSON and M4A salvage.
- Local 16 kHz mono 48 kbps AAC M4A recording linked to each saved session, with playback and Finder access.
- Separate bounded recording and ASR streams, drop diagnostics, 10 Hz input metering, and disk-backed after-class replay.
- Energy-saving recognition by default, sequential heavyweight model warmup, and explicit post-class translation progress.
- Fifteen-minute TranslateGemma keep-warm window after high-accuracy sessions, with immediate MLX cache clearing when switching to energy-saving mode; downloaded weights remain cached.
- Live transcript follow mode reacts to provisional text and translation growth, while after-class high-accuracy work runs at utility priority to keep the end-session transition responsive.
- Native macOS SwiftUI classroom workspace.
- Deterministic recognition and translation adapters for end-to-end UI development.
- Unit tests covering zero-preparation courses, approved terminology, lifecycle transitions, subtitle translation, and persistence.
- FluidAudio 0.15.5 integrated and version-locked through Swift Package Manager.
- AVAudioEngine microphone permission and capture lifecycle.
- CoreAudio microphone enumeration and UID-locked selection, plus 15-second local playback tests.
- Real-time conversion to 16 kHz mono Float32 audio frames.
- Live input-level monitoring in the classroom status bar.
- Fully local Parakeet EOU 120M streaming recognition through FluidAudio.
- Cumulative streaming transcript de-duplication across end-of-utterance boundaries.
- Unsupported system-audio controls remain disabled until a capture adapter exists.
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
- Persisted warmup diagnostics for ASR, quick translation, enhanced translation, generated terms, and actual recognition-engine reuse.
- Conservative course-name typo repair plus academic, cloud, security, and software terminology preparation.
- Apple Translation integration for on-device English-to-Simplified-Chinese subtitles.
- Optional Soniox `stt-rt-v5` transcription and Chinese translation with a Keychain-backed API key,
  language identification, endpoint detection, and reviewed recognition/translation terminology.
- Optional lecturer name and Indian English profile with course-scoped correction history.
- Contextual TranslateGemma refinement for each completed three-segment live group and across the post-class transcript.
- Inline English correction with immediate Chinese retranslation.
- Non-blocking translation jobs that keep English subtitles live during translation preparation.
- Bounded translation concurrency, completion deadlines, missing-segment retry, and a skip-post-class-optimization action.
- Local post-class summary generation with Apple Foundation Models and a deterministic fallback.
- Persisted overview, concepts, timestamped actions, and summary/full-transcript review views.
- Missing-input-device preflight that prevents AVAudioEngine crashes on Macs without a microphone.
- iPhone Continuity Camera microphone verified on a Mac mini at the app's 16 kHz capture rate.
- Sustained low-input warning, misplaced currency-symbol repair, and clause-aware 36-word post-class translation chunks.
- Persisted microphone identity, sample rate, route-change/drop diagnostics, interrupted-recording recovery, and preserved offline transcript boundaries.
- Exact course-scoped aliases for common cloud-computing acronyms without unsafe single-word guessing.
- Indian English aliases guarded by prepared cloud terms and sentence cues, including NIST, IaaS,
  PaaS, SaaS, and CloudTrail variants.
- Translation quality gates for numbers, negation, acronyms, and protected service names.
- Searchable local classroom history with summary, bilingual transcript, audio playback, Finder access, and confirmed deletion.
- Automatic TranslateGemma preparation for high-accuracy sessions, strict prompts, per-segment translation provenance, and truthful refinement completion.
- Predominantly Chinese discussion retained as source evidence but excluded from translation context, translation, and summaries.
- Mobile/Android and LLM terminology packs plus requirement/modality quality checks.
- Native iPhone app target with 16 kHz microphone capture, Soniox bilingual session control,
  live English/Chinese captions, input metering, interruption handling, and latest-caption scrolling.
- iPhone AAC M4A recording and atomic bilingual JSON checkpoints, plus searchable-by-list
  local classroom history with transcript detail, audio playback, and coordinated deletion.
- Backend-issued temporary Soniox credential client; the permanent provider key is not embedded in the app.
- Zero-dependency Cloudflare Worker credential broker with constant-time bearer-token checks,
  one-use 60-second Soniox keys, four-hour stream limits, sanitized upstream failures, and no-store responses.
- iPhone broker settings with HTTPS validation, preference-backed endpoint storage, and Keychain-backed token storage.

## Verification status

- Xcode 26.6 is installed on the external APFS volume at `/Volumes/Disk/Applications/Xcode.app`.
- All Swift source files pass `swiftc -parse`.
- Full package build and tests run with the external Xcode selected through `DEVELOPER_DIR`.
- `swift test` builds the shared core, Mac executable, and test bundle successfully.
- All 106 tests pass in the host Xcode build, with one optional local-model smoke test skipped when its model path is not configured. Coverage includes bounded recording/ASR/translation queues, microphone route-change filtering, failure salvage, cancellation teardown, stale-audio recovery, offline timing, legacy JSON compatibility, session deletion, Chinese-discussion exclusion, Soniox bilingual token separation and translation pass-through, stable-sentence soft commits, short-utterance endpoint protection, cloud-term risk controls, course-scoped translation terminology, strict TranslateGemma prompts, translation provenance, modality checks, mobile terminology, Indian English alias false positives, contextual refinement, correction history and retranslation, long-prefix cursor behavior, adaptive gain, M4A replay, Apple translation coordination, summaries, compact-window UI rendering, Soniox configuration, endpoint grouping, language preservation, and Mac mode routing.
- A 25-minute 57-second same-audio Soniox A/B completed at realtime speed. Its combined LecSync agreement error was 12.94%, versus 21.57% for local live recognition and 19.27% for local offline recognition. These remain competitor-agreement diagnostics, not ground-truth WER.
- A separate 120-second Indian-English secure-cloud sample validated Soniox transcription and Chinese translation end to end. Soniox corrected local errors including `NISC`/`NIST`, `cloud monitor`/`cloud auditor`, and `API clouding`/`API logging`. Translation terms stabilized cloud-role Chinese, while both `CloudTrail` and `AWS CloudTrail` recognition hints over-biased `cloud carrier`; the adapter now excludes that ambiguous recognition hint, repairs `cloud trail(s)` locally only with course cues, and enables cloud translation terms only for cloud-related courses.
- `LingoSlateSoniox` is now a Foundation-only Swift target that depends only on `LingoSlateCore`; an iPhone target can reuse it without linking FluidAudio or MLX.
- `LingoSlateMobile` and the iPhone app entry compile for `arm64-apple-ios18.0` against the installed iPhoneOS SDK. Five focused mobile lifecycle, persistence, and broker-contract tests pass on macOS; the Worker has five additional security/contract tests. Installing and launching on the connected iPhone remains blocked until Xcode's matching iOS 26.5 device-support component is installed.
- On the same 120-second lecture sample, bilingual stable-sentence soft commits reduced the longest finalized Soniox segment from about 90 seconds to 18.36 seconds while retaining server endpoints for short utterances.

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
7. Save the stopped recording and live bilingual checkpoint before optional post-class optimization.
8. Preserve offline recognition boundaries, generate the summary, and update the same local session.

## Next production slice

1. Add inverse text normalization for dates, times, and broader spoken-number forms.
2. Add per-span uncertainty signals and detailed model download progress.
3. Run live subtitle, battery, thermal, and 90-minute soak tests.
4. Add Markdown, text, SRT, and VTT bilingual export.

Source-attributed automatic course preparation and consent-aware cloud diagnostics remain future work.
