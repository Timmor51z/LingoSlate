# LingoSlate Product and Code Review Brief

This document is the handoff for a full-project review. Please review the repository as it exists,
not only the intended architecture in `PRODUCT_DESIGN.md`. Findings should come first and should
cite concrete files and lines.

## 1. Product summary

LingoSlate is a local-first bilingual classroom companion for international students. Its initial
platform is macOS, with an iPhone microphone-caption companion planned later. The core workflow is:

1. Start a lecture immediately. Course name and materials are optional.
2. Capture an English-speaking lecturer or meeting participant.
3. Show live English and Simplified Chinese subtitles.
4. Let the student mark important moments.
5. Save the original audio, bilingual transcript, and a post-class summary locally.

The primary user is an international student who generally understands English but loses details
when speech is fast, accented, acoustically difficult, or terminology-heavy. The product should
protect names, acronyms, numbers, negation, assignment requirements, and deadlines more strongly
than ordinary prose.

The current pilot hardware is a 14-inch Apple Silicon MacBook Pro with 32 GB unified memory. The
product direction remains local-first, but difficult accented speech may later use explicit,
user-selected Soniox cloud assistance. Cloud use must never be silent.

## 2. Current implementation, not roadmap

The repository currently implements a native SwiftUI macOS vertical slice:

- Microphone capture through `AVAudioEngine`.
- Conversion to 16 kHz mono Float32 frames.
- Incremental 48 kbps AAC M4A recording without retaining a whole class in memory.
- FluidAudio local ASR in two user-selectable modes.
- Live provisional/final English subtitle events.
- Apple on-device English-to-Simplified-Chinese translation.
- TranslateGemma 4B local refinement in high-accuracy mode.
- Optional course name, generated/editable course terms, school, and region settings.
- Local JSON session persistence, audio playback, and Finder reveal.
- Bookmarks/markers and post-class summaries.
- Apple Foundation Models summary when available, with a deterministic fallback.
- Private ASR and translation benchmark command-line tools.

Important boundaries:

- The current `highAccuracy` mode is still fully local. It uses FluidAudio Unified ASR plus
  TranslateGemma refinement and a post-class offline ASR replay.
- Soniox is designed but not implemented.
- System/app audio and mixed capture are designed but disabled in the current UI.
- Course catalogue discovery, document import, exports, cloud cost display, session repair, and the
  iPhone app are roadmap items.
- The current session UI is the working product surface; the broader Today/Courses/Sessions/Settings
  information architecture in `PRODUCT_DESIGN.md` is not yet implemented.

## 3. User-visible modes

### Energy-saving mode

- FluidAudio Parakeet EOU 120M.
- Adaptive gain and limiting before recognition.
- Apple Translation for Chinese.
- Smallest model download and lower energy use.

### High-accuracy mode

- FluidAudio Parakeet Unified 0.6B with 1120 ms streaming context.
- Raw input rather than the adaptive-gain wrapper.
- Apple Translation draft followed by TranslateGemma 4B local refinement.
- After Stop, the saved audio is replayed through `unifiedOffline15s` and the transcript is replaced
  before translation and summary are saved.
- The post-class pass currently creates clause-aware chunks capped at 36 words.

The name `highAccuracy` may be misleading because the product design also uses “Cloud High
Accuracy” for the future Soniox path. Please flag naming and migration risks.

## 4. Runtime data flow

```text
SwiftUI ClassroomWorkspaceView
        |
        v
AppModel (session orchestration and lifecycle)
        |
        +--> MicrophoneAudioCapture --> 16 kHz AudioFrame stream
        |          |                         |
        |          |                         +--> FluidAudio ASR
        |          +--> SessionAudioBuffer ------> incremental M4A
        |
        +--> RecognitionEvent AsyncStream
                    |
                    v
             SubtitlePipeline
              |           |
              |           +--> Apple Translation
              |                    |
              |                    +--> TranslateGemma refinement (high accuracy)
              v
         TranscriptSnapshot --> SwiftUI

Stop in high-accuracy mode
        |
        v
Replay retained audio --> Unified Offline ASR --> replace final transcript
        --> translate all chunks --> summarize --> atomic JSON save
```

Concurrency uses Swift actors, `AsyncStream`, detached consumer tasks, and structured/unstructured
`Task` instances coordinated by `AppModel`. Snapshot delivery uses `bufferingNewest(1)`, and audio
capture uses a bounded event buffer. A major review goal is to verify cancellation, ordering,
finalization, and ownership across this graph.

## 5. Source layout

```text
Sources/LingoSlateCore/
  Models.swift                         Codable domain models
  EngineProtocols.swift                Recognition, translation, summary contracts
  SubtitlePipeline.swift               Segment state, normalization, translation scheduling
  TranscriptTermNormalizer.swift       Course/glossary spelling repair
  SessionStateMachine.swift             Lifecycle validation
  SessionStore.swift                    Atomic local JSON persistence
  AdaptiveGainProcessor.swift           Local input normalization
  AudioInputQualityMonitor.swift        Sustained low-input warning
  DeterministicSummaryEngine.swift      Summary fallback
  TranscriptComparison.swift            Benchmark metrics

Sources/LingoSlateAudio/
  MicrophoneAudioCapture.swift          AVAudioEngine capture and conversion
  FluidAudioRecognitionEngine.swift     120M energy-saving adapter
  FluidAudioStreamingRecognitionEngine.swift
                                        Unified/Nemotron streaming adapters
  AudioEnhancingRecognitionEngine.swift Adaptive-gain wrapper
  SessionAudioBuffer.swift              Disk-backed M4A and bounded replay

Sources/LingoSlateTranslation/
  TranslateGemmaTranslationEngine.swift MLX model loading, prompt, fidelity checks

Sources/LingoSlateMac/
  AppModel.swift                        Main orchestration and session ownership
  ClassroomWorkspaceView.swift          Primary live/review UI
  AppleTranslationEngine.swift          Apple Translation adapter and term protection
  CoursePreparationService.swift        Local term preparation and warmup
  LocalSummaryEngine.swift              Foundation Models plus fallback
  UserProfileSettingsView.swift         School and region settings

Sources/LingoSlateBenchmark/             Same-audio FluidAudio benchmark
Sources/LingoSlateTranscriptBenchmark/   External Whisper comparison importer
Sources/LingoSlateTranslationBenchmark/  Sampled translation benchmark
Tests/                                   Core, Mac adapter, summary, and app tests
```

The package is about 8,700 lines of Swift including tests and developer tools. Dependencies are
versioned in `Package.swift`/`Package.resolved`:

- FluidAudio 0.15.5
- mlx-swift-lm 3.31.4
- swift-huggingface
- swift-transformers

## 6. Persistence and privacy

Completed sessions are saved under:

```text
~/Library/Application Support/LingoSlate/Sessions/
```

Each session has a JSON document and, when retained, a same-UUID M4A file. JSON includes the
configuration, timestamps, final English and Chinese segments, markers, summary, audio filename,
and warmup diagnostics. Session JSON writes are atomic.

Audio, ASR, translation, and summary are currently local. Encryption, crash recovery for unfinished
sessions, in-app session deletion, and Keychain-backed cloud credentials are product requirements
but are not complete. Private benchmark audio and transcripts live under `Benchmarks/Private/` and
are gitignored. Do not upload or include those artifacts in review output.

## 7. Model and context behavior

### Recognition

`RecognitionConfiguration` contains course, language, and approved terms. However,
`FluidAudioStreamingRecognitionEngine.start(configuration:)` currently loads the selected model and
does not consume those fields. Course warmup preloads models and prepares terms, but it does not
currently bias FluidAudio decoding.

### Transcript normalization

`TranscriptTermNormalizer` performs conservative edit-distance matching for prepared terms and
supports explicit approved aliases. Its current fuzzy matcher is disabled for normalized terms
shorter than six characters. This means short technical forms such as `NIST`, `IaaS`, `PaaS`,
`SaaS`, and `IAM` cannot recover from close ASR spellings unless an exact alias was supplied.

Any fix must avoid unsafe global replacements. For example, replacing every occurrence of “is”
with `IaaS` would corrupt normal speech. Prefer course-enabled, phrase-level, approved aliases and
tests for false positives.

### Translation

`SubtitlePipeline` constructs `TranslationContext` with up to four previous source segments.
Currently neither `AppleTranslationEngine` nor `TranslateGemmaTranslationEngine` uses
`recentSourceText` as semantic context. They use the course/glossary primarily to protect exact
terms. TranslateGemma receives only the current source chunk in its model prompt.

The translation quality gate checks protected-term and number retention, then converts Traditional
Chinese output to Simplified Chinese. It does not detect whether fluent Chinese is based on an
implausible English ASR result.

### Summary

`LocalSummaryEngine` uses Apple Foundation Models when available. The deterministic fallback
samples translated segments, counts repeated words, and detects broad action cues. On poor ASR it
can produce generic concepts and false action items.

## 8. Real-class evidence and current diagnosis

### 2026-07-13 comparison against LecSync

The committed private report records a same-class comparison, not a ground-truth WER:

- Competitor-agreement WER: 23.08%.
- Number recall against LecSync: 52.5%.
- Acronym recall against LecSync: 41.7%.
- LingoSlate Chinese was often more natural, but LecSync captured more source content.
- LecSync is also fallible and must not be treated as manual truth.

See `Benchmarks/Private/today-2026-07-13/QUALITY_REPORT.md` only on an authorized local machine.

### 2026-07-20 classroom audit

The latest inspected session was a cloud-computing lecture delivered by a lecturer with an Indian
English accent. The user sat close to the lecturer, so do not attribute the failure simply to
seating distance.

Observed facts:

- Audio duration: about 48 minutes 45 seconds.
- 222 continuous final segments with no transcript timeline gaps.
- The 48 kbps recording and 36-word post-class chunk changes were active.
- The lecturer portion had lower effective speech/noise separation than an AWS promotional video
  played at the end of the same recording.
- FluidAudio produced errors such as `NIST -> NISC`, `IaaS -> IS/ICE`, and
  `platform as a service -> telephone as the service`.
- A separate Whisper medium.en run on the same opening audio also performed poorly. With a cloud
  terminology prompt it still produced `IaaS -> IELTS`; without the prompt it was worse.
- The AWS video narration in the same file transcribed much more coherently, including AWS,
  Lambda, and SageMaker.
- The course name was blank and no prepared terms were present for this session.
- Chinese translation usually made bad English sound fluent instead of repairing it.
- The deterministic summary fallback produced generic concepts and false action items.
- JSON `endedAt` was about 15 minutes after audio stopped because it is assigned during
  `completeSession`, after post-class work. It is not the physical recording-stop timestamp.

Current diagnosis:

1. The actual macOS input device and microphone mode were not persisted, so the historical route
   cannot be proven. Logs showed a default aggregate input and nearby iPhone Continuity activity.
2. Classroom acoustics, system microphone processing, and Indian-accent model fit all matter.
3. The local vocabulary/context path does not currently influence ASR decoding.
4. Short acronym recovery and semantic translation context are concrete local code gaps.
5. A larger translation model is not the first fix because the English source is already wrong.

## 9. Known product/code mismatches to review

Please verify these rather than assuming the design document is current:

1. `PRODUCT_DESIGN.md` describes Soniox as Cloud High Accuracy; code uses a local high-accuracy
   mode and has no Soniox adapter.
2. Product design includes system audio, mixed audio, export, course-source providers, and repair;
   current code does not provide those completed workflows.
3. Course warmup UI suggests context preparation, but prepared terms do not bias FluidAudio ASR.
4. `TranslationContext.recentSourceText` is populated but not used by the translation engines.
5. Session `endedAt` currently means post-processing completion, not recording stop.
6. Audio capture uses the macOS default `AVAudioEngine.inputNode`; selected device identity and
   route changes are not stored in `SessionDocument`.
7. Replacing an offline transcript estimates timestamps by word-count proportion instead of
   preserving model-aligned word timestamps.
8. Confidence/uncertainty is not represented in persisted transcript segments.
9. The product design requires crash recovery and transactional committed segments, but the
   current app saves the completed document at the end.
10. Privacy design mentions encryption; current JSON and M4A files are ordinary local files.

## 10. Review priorities

### P0: correctness and data integrity

- Task cancellation, actor isolation, and races in start/stop/finalize/reset.
- Whether stopping during model preparation, translation, or post-class replay can lose data.
- Whether `finishPendingTranslations()` can stall or miss tasks added/removed concurrently.
- Audio capture backpressure and whether bounded streams can silently drop speech frames.
- M4A finalization and JSON persistence under errors, sleep, route changes, and app termination.
- Codable backward compatibility for existing saved sessions.
- Preservation of user-corrected segments during automatic transcript replacement.

### P1: classroom quality

- Safest design for short acronym and Indian-accent pronunciation aliases.
- Where course and lecturer context should enter ASR, normalization, and translation.
- How to translate with two-to-four-sentence context without breaking live latency or segment
  alignment.
- How to represent uncertainty so polished Chinese does not conceal broken English.
- Whether raw versus adaptive audio behavior is correctly chosen for each FluidAudio model.
- Whether `unifiedOffline15s` is actually the best post-class local model for this workload.

### P1: resource use and long sessions

- Model-container ownership and MLX cache release.
- Multiple ASR models overlapping during warmup and post-class processing.
- 90-to-120-minute memory, thermal, battery, and disk behavior.
- Translation task queue growth when a lecturer speaks faster than TranslateGemma can refine.
- UI publication frequency and main-actor work during long transcripts.

### P2: architecture and roadmap

- Smallest clean seam for a future Soniox adapter without destabilizing the local path.
- Whether `highAccuracy` should be renamed before cloud mode exists.
- Which shared types genuinely support a later iPhone client and which are macOS-coupled.
- Whether `AppModel` has accumulated too many responsibilities and, if so, the smallest useful
  extraction rather than a broad rewrite.
- Documentation that claims planned features as implemented.

## 11. Testing gaps to identify

Existing tests cover core models, lifecycle transitions, term normalization, translation
coordination, audio encoding/replay, summaries, migration, and persistence. Please specifically
look for missing tests around:

- Repeated start/stop/reset and cancellation at every lifecycle phase.
- Two-hour sessions and post-class replay.
- Audio-route changes and iPhone Continuity microphone disappearance.
- Actual device identity persistence.
- Short acronym aliases and false-positive protection.
- Context-aware translation and retranslation after source correction.
- Translation backlog limits and deterministic output ordering.
- App termination before final save and unfinished-session recovery.
- Old JSON documents after adding optional diagnostic fields.
- Real TranslateGemma behavior; the smoke test is skipped without a configured local model path.

The correct quality benchmark needs a manually corrected English reference. LecSync output is a
useful competitor comparison but not ground truth. Measure at least overall WER, omitted-speech
rate, acronym/term recall, numbers, negation, and Chinese adequacy from both raw and corrected
English.

## 12. Suggested reading order

1. `README.md`
2. `MVP_STATUS.md`
3. `Package.swift`
4. `Sources/LingoSlateMac/AppModel.swift`
5. `Sources/LingoSlateCore/SubtitlePipeline.swift`
6. `Sources/LingoSlateAudio/MicrophoneAudioCapture.swift`
7. `Sources/LingoSlateAudio/FluidAudioStreamingRecognitionEngine.swift`
8. `Sources/LingoSlateCore/TranscriptTermNormalizer.swift`
9. `Sources/LingoSlateMac/AppleTranslationEngine.swift`
10. `Sources/LingoSlateTranslation/TranslateGemmaTranslationEngine.swift`
11. `Sources/LingoSlateAudio/SessionAudioBuffer.swift`
12. `Sources/LingoSlateMac/LocalSummaryEngine.swift`
13. Tests, then `PRODUCT_DESIGN.md`

Reading the implementation before the full roadmap helps separate current behavior from intent.

## 13. Build and verification

The user's Xcode installation is on an external APFS volume:

```bash
DEVELOPER_DIR=/Volumes/Disk/Applications/Xcode.app/Contents/Developer \
  swift build --disable-sandbox

DEVELOPER_DIR=/Volumes/Disk/Applications/Xcode.app/Contents/Developer \
  swift test --disable-sandbox

./scripts/build-macos-app.sh
```

The working branch at the time of this brief is `codex/translation-quality`; the brief was created
after commit `e7fd2d2` (`feat: improve classroom context and translation recovery`). Check the
working tree before reviewing because new uncommitted changes may exist.

Baseline verification on 2026-07-20: all 64 tests passed with zero failures. One optional
TranslateGemma local-model smoke test was skipped because `LINGOSLATE_TRANSLATION_MODEL_PATH` was
not configured for that test process.

## 14. Requested review output

Please return:

1. Findings first, ordered by severity, with file and line references.
2. For each finding, label it as a confirmed bug, likely runtime risk, quality limitation,
   architecture debt, security/privacy gap, or documentation mismatch.
3. Explain the user-visible failure mode and the smallest credible fix.
4. List missing tests that would fail before each proposed fix and pass afterward.
5. Give a prioritized implementation sequence for the next two development iterations.
6. Separately assess the best path for Indian-accent technical lectures:
   local-only, local plus context repair, or optional Soniox cloud assistance.

Avoid a wholesale rewrite unless a concrete correctness problem makes it necessary. Preserve the
local-first requirement, optional course setup, future iPhone reuse, existing user data, and the
ability to retain original audio for review.
