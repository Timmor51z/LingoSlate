# LingoSlate Review Handoff for GPT

This file is a self-contained work order. It packages the results of a full-project code review
(performed by Claude on 2026-07-20, branch `codex/translation-quality`, commit `e7fd2d2`, clean
working tree) so that GPT can act on it without any other conversation context.

## 0. How to use this brief

1. Read section 1 (context and constraints) first.
2. Treat every finding in section 2 as a **claim to re-verify against the current working tree**
   before changing code. Line numbers were accurate at `e7fd2d2`; if the tree has moved, locate by
   file + symbol, not by line.
3. Implement **Iteration 1** (section 3) in order, one finding per commit, each with its tests.
4. Do not start Iteration 2 items until Iteration 1 is green.
5. Findings you disagree with after verification: do not silently skip — leave a short note per
   finding (agree/disagree + reason) in your final summary.

## 1. Project context

LingoSlate is a local-first bilingual (EN→zh-Hans) classroom companion for international students.
Native SwiftUI macOS app, Swift 6 strict concurrency, SwiftPM. Pipeline: `AVAudioEngine` mic
capture → 16 kHz mono Float32 → FluidAudio local ASR (energy-saver Parakeet EOU 120M, or
high-accuracy Parakeet Unified 0.6B streaming) → live EN/zh subtitles (Apple Translation, plus
TranslateGemma 4B MLX refinement in high-accuracy) → incremental 48 kbps AAC M4A recording →
post-class offline re-transcription (`unifiedOffline15s`) that replaces the transcript → summary
(Apple Foundation Models with deterministic fallback) → atomic JSON save under
`~/Library/Application Support/LingoSlate/Sessions/`.

Layout (≈8.7k lines Swift):

```
Sources/LingoSlateCore/         domain models, SubtitlePipeline, normalizer, state machine, store
Sources/LingoSlateAudio/        MicrophoneAudioCapture, FluidAudio engines, SessionAudioBuffer
Sources/LingoSlateTranslation/  TranslateGemmaTranslationEngine (MLX)
Sources/LingoSlateMac/          AppModel (orchestration), ClassroomWorkspaceView, Apple engines
Tests/                          LingoSlateCoreTests, LingoSlateMacTests
```

Build and test (Xcode lives on an external volume):

```bash
DEVELOPER_DIR=/Volumes/Disk/Applications/Xcode.app/Contents/Developer swift build --disable-sandbox
DEVELOPER_DIR=/Volumes/Disk/Applications/Xcode.app/Contents/Developer swift test --disable-sandbox
```

Baseline: 64 tests pass; one TranslateGemma smoke test is env-gated
(`LINGOSLATE_TRANSLATION_MODEL_PATH`) and skips when unset.

**Hard constraints (do not violate):**

- Local-first stays. No cloud calls. Soniox is design-only; do not implement it here.
- No wholesale rewrite. Smallest credible fix per finding; preserve existing architecture.
- Existing saved session JSON must keep decoding (only additive optional fields; never change
  stored enum rawValues such as `"highAccuracy"`).
- Course name stays optional; zero-preparation start must keep working.
- Never read, upload, or commit anything under `Benchmarks/Private/` (gitignored private audio).
- Chinese UI strings: match the existing tone; keep new user-facing strings in Simplified Chinese.
- All existing tests must still pass; every fix ships with the tests listed for it.

## 2. Findings (severity-ordered)

Labels: [CB] confirmed bug · [RR] likely runtime risk · [QL] quality limitation ·
[AD] architecture debt · [SP] security/privacy gap · [DM] documentation mismatch

### F1 [CB] Any mid-class failure deletes the whole recording and transcript
- `Sources/LingoSlateMac/AppModel.swift` `markFailed` (≈595-608) calls
  `postClassAudioBuffer.reset()`; `SessionAudioBuffer.reset` (≈154-156, 196-207) deletes the temp
  M4A. Before `finishWriting()`, that temp file *is* the entire class recording. `markFailed` is
  reached from `engine.accept`/`append` throws in the capture loop (≈251-257), capture/recognition
  `.failed` events, and `recognitionEngine.finalize()` throwing inside `stopSession` (≈315-318).
  `currentDocument` is never saved on this path.
- **Fix:** in `markFailed`, salvage instead of reset: `try? finishWriting()`; if a URL returns,
  save a partial `SessionDocument` (segments from current snapshot, `endedAt` = now, failure note)
  via `sessionStore.save`. Clear buffer state only after salvage.
- **Tests:** mock engine throwing on `accept` after N frames → M4A exists + playable, JSON with
  partial transcript exists. Same for `finalize()` throwing at stop.

### F2 [CB] Session persisted only once at the very end; crash/quit loses everything; `endedAt` wrong
- `completeSession` (AppModel ≈610-685) is the only `save`; `document.endedAt = Date()` (≈627)
  runs *after* the ~15-min post-class pass (matches the observed 15-min `endedAt` offset).
  Crash during class → temp M4A unplayable (no moov) + no JSON. Crash during post-class → audio
  survives (replay finalizes it first, `SessionAudioBuffer.replay` ≈111) but no JSON. Stale hidden
  temp files (`.<stem>-<UUID>.m4a`, ≈55-57) are never cleaned up.
- **Fix:** (1) save a first JSON snapshot the moment recognition finishes, before post-class,
  with live transcript + new optional `recordingEndedAt: Date?` and a post-processing marker;
  re-save at completion. (2) `endedAt` should mean recording stop; add `processedAt` if needed.
  (3) on launch, sweep Sessions dir for stale temp audio + incomplete JSONs; surface/clean.
- **Tests:** JSON exists before post-class completes; old-JSON fixture without new fields decodes;
  sweep finds planted stale temp + incomplete JSON.

### F3 [CB] Cancel-during-preparing leaks the session graph; every cancel/restart strands a loaded ASR model
- `cancelPreparation` (AppModel ≈687-699) transitions to idle but does NOT finalize the engine,
  cancel `eventTask`/`captureTask`/`snapshotTask`, or nil `pipeline`/`recognitionEngine`/
  `audioCapture`. `startSession` (≈134-140) reassigns those tasks without cancelling old ones.
  Engine `events` streams only finish in `finalize()`
  (`FluidAudioStreamingRecognitionEngine.swift` ≈149-169), so the old detached `eventTask` stays
  suspended forever holding the old engine (~595 MB model in high-accuracy) strongly.
- Related race: last `Task.checkCancellation()` is *before* `capture.start()` (≈286-287); a Stop
  landing during `capture.start()` is never observed and the session keeps running.
- **Fix:** give `cancelPreparation` full teardown (cancel+nil the three tasks,
  `try? await recognitionEngine.finalize()`, nil pipeline/engine/capture). Add a cancellation
  check (+ capture stop on catch) after `capture.start()`. Defensively cancel stale tasks at the
  top of `startSession`.
- **Tests:** cancel during preparing with mock engine → finalize called, tasks completed; repeat
  start/cancel ×10 with weak refs → no engine outlives its cycle.

### F4 [RR] Stop can stall forever; translation backlog unbounded
- `SubtitlePipeline.finishPendingTranslations` (≈116-123) loops until the pending dict is empty;
  `scheduleTranslation` (≈235-275) spawns one unbounded Task per final segment.
  `AppleTranslationEngine.translate` (≈138-154) holds a serial gate around `session.translateText`
  with no timeout; TranslateGemma `session.respond` (≈89-101) has no timeout. One hung call, or a
  large refine backlog (fast lecturer vs 4B model), blocks completion; UI stuck in 正在整理字幕;
  force-quit → F2 loss. Stop's `Task` in `stopSession` (≈306) is unstored/uncancellable.
- **Fix:** (1) `finishPendingTranslations(timeout:)` 30-60 s → on expiry
  `cancelPendingTranslations()` and return (English is final; Chinese recoverable). (2) cap live
  refinement scheduling when pending > ~8 (Apple draft stays). (3) drain progress in status text.
- **Tests:** never-returning engine + deadline → returns within deadline (hangs today); 100 finals
  through slow refiner → pending never exceeds cap; per-segment results deterministic.

### F5 [RR] Backpressure silently drops mic frames (gaps in recording AND transcript)
- `MicrophoneAudioCapture` events use `bufferingNewest(512)` (≈39-41) ≈ 20 s of audio; the single
  consumer (AppModel ≈241-265) does disk append + ASR accept serially. Sustained ASR
  slower-than-real-time (thermal + concurrent Gemma) → oldest events silently discarded: holes in
  the M4A and transcript, no counter, no warning. Control events share the same buffer.
- **Fix:** decouple recording from recognition (dedicated consumer or second stream for
  frames-to-disk, effectively unbounded; keep the bound for ASR frames). Add a dropped-frame
  counter surfaced in diagnostics/status. Ensure `.stopped`/`.failed` cannot be evicted.
- **Tests:** fast producer + slow mock engine through the real stream shape → recorded samples ==
  produced samples (fails today); drop counter reported for ASR side.

### F6 [RR] No route-change handling; input device never recorded
- `MicrophoneAudioCapture.start` (≈85-125): default `inputNode`, converter fixed at start format,
  no `AVAudioEngineConfigurationChange` observer. Default-device changes (AirPods/Continuity
  iPhone/aggregate) stop the engine silently → frozen subtitles, empty recording, or converter
  failures cascading into F1. `SessionDocument` (Models.swift ≈214-246) has no device identity, so
  the 2026-07-20 audit's routing question is unprovable by design.
- **Fix:** observe `.AVAudioEngineConfigurationChange` → restart tap with fresh format or emit
  `.failed`; never silent. Capture default input device UID/name/sampleRate at start
  (`kAudioHardwarePropertyDefaultInputDevice` → `kAudioDevicePropertyDeviceUID`) into a new
  optional diagnostics field; append route-change events with timestamps.
- **Tests:** injectable notification source → config change produces a visible event; document
  round-trip with new optional fields; old JSON without them decodes.

### F7 [CB] Summary substring cues: "for example" becomes an action item
- `DeterministicSummaryEngine.actionItems` (≈97-103) uses `source.contains(cue)`; cues include
  `"exam"` → matches "example"/"examine". `LocalSummaryEngine.merge` (≈71-80) appends fallback
  action items even when Foundation Models succeeded, so false positives survive.
- **Fix:** word-boundary cue matching; in `merge`, use fallback `actionItems` only when generated
  is empty (mirror `overview`).
- **Tests:** "For example, S3 is object storage." → no action item (fails today); FM success + 3
  cue hits → only FM items.

### F8 [QL] Short acronyms unrecoverable; thresholds stricter than they look
- `TranscriptTermNormalizer`: fuzzy disabled under 6 normalized chars (≈10-12); thresholds
  0.84/0.92 (≈39-53) mean one edit needs ≥7 chars (terms) / ≥13 (aliases). `NIST→NISC` = 0.75:
  no general threshold fixes it. Exact alias matching bypasses the gate (≈159-173) and already
  works ("I triple E"→IEEE) — that is the safe route.
- **Fix (design):** per-course approved phrase-level aliases, exact-only for short forms
  ("platform as the service"/"telephone as the service" → "platform as a service"); single-token
  aliases only with guards (not a dictionary word; denylist `is/ice/ias…`; require ALL-CAPS ASR
  token, non-sentence-initial) so `NISC→NIST` is safe and `ICE→IaaS` stays multi-word/contextual.
  Seed `cloudAndSecurityTerms` (UserProfile.swift ≈130-150) with IaaS, PaaS, SaaS, NIST, EC2, S3,
  Lambda, SageMaker + curated aliases. Optionally allow distance-1 fuzzy for 4-5-char ALL-CAPS
  terms vs ALL-CAPS tokens only.
- **Tests (false-positive suite):** "The ice on the lake" unchanged; "This is important"
  unchanged; the two phrase aliases repair; `NISC→NIST` repairs while `disc` doesn't.

### F9 [QL] `TranslationContext.recentSourceText` populated but unused by both engines
- Built in `SubtitlePipeline` (≈85-97, 171-177); ignored by `AppleTranslationEngine` (builder
  ≈262-284) and TranslateGemma (prompt ≈96-101). Live segments are force-cut at 15 s
  (`FluidAudioStreamingRecognitionEngine` ≈171-180), so fragments translate without antecedents.
- **Fix:** Apple has no context API. For Gemma: prepend 1-2 previous source sentences as marked
  do-not-translate context, behind a flag, validated with `LingoSlateTranslationBenchmark` (the
  immersive-translate finetune may only accept bare text — measure, don't assume). Post-class pass
  first (lowest risk, most win).
- **Tests:** prompt-builder unit tests (context included/marked/stripped); benchmark A/B gated on
  protected-term/number retention.

### F10 [QL] No uncertainty representation: fluent Chinese conceals broken English
- `TranscriptSegment` (Models.swift ≈154-186) has no confidence. Add optional
  `sourceConfidence: Double?` / `isLowConfidence: Bool?` (additive, Codable-safe); populate with
  cheap proxies initially; render hedged Chinese (dimmed + ⚠) for low-confidence segments; exclude
  them from summary action-item extraction. Also future-proofs a cloud adapter.

### F11 [RR] O(session²) streaming-cursor diffing
- `FluidAudioStreamingRecognitionEngine.accept` calls `getPartialTranscript` +
  `IncrementalTranscriptCursor.uncommittedText` every frame (≈142-147);
  the cursor (IncrementalTranscriptCursor.swift ≈12-51) re-splits and lowercases the entire
  cumulative committed transcript per call; the streaming engine never resets it. 90-min session →
  quadratic total work, thermal/battery drain, steals the headroom F5 needs.
- **Fix:** cache committed token array + normalized forms; tokenize only the incoming tail;
  compare only the last K committed tokens (anchor already limits to 8).
- **Tests:** existing cursor tests unchanged; new perf test asserting bounded per-call cost as
  committed length grows.

### F12 [RR] Stop button dead during the ~15-min post-class pass; no skip
- `stopSession` guard requires `recognitionEngine != nil` (≈296-303) but it is nil'd at
  `receiveRecognitionFinished` (≈557); the 结束 button renders whenever `isActive`
  (ClassroomWorkspaceView ≈134-139) → visible button that does nothing for 15 minutes;
  `resetForNextSession` blocked; only exit is quit → F2. Cancellation plumbing exists:
  `postClassTask.cancel()` propagates into `SessionAudioBuffer.replay`'s check (≈126) and the
  catch saves the live transcript.
- **Fix:** during `.finalizing` with active `postClassTask`, show 跳过课后优化 →
  `postClassTask?.cancel()`; add `try Task.checkCancellation()` per chunk in
  `replaceFinalTranscript`'s loop (SubtitlePipeline ≈169-208). Consider a window-close
  confirmation during active sessions.
- **Tests:** cancel mid-replay and mid-retranslation → live transcript saved, state completed.

### F13 [QL] Offline pass hears 48 kbps lossy audio; word timings discarded; markers desync
- `OfflineTranscriptCollector` (AppModel ≈849-864) keeps only text (per-event start/end times are
  available and thrown away); `replaceFinalTranscript` re-times by word proportion
  (SubtitlePipeline ≈147-164); replay decodes the finalized AAC (SessionAudioBuffer ≈110-152).
- **Fix:** keep per-event boundaries through the collector and chunk-align within them; optionally
  replay from a lossless temp (CAF/ALAC) and transcode for retention. Benchmark both with
  `LingoSlateBenchmark` before committing.
- **Tests:** two-speed synthetic fixture → boundary times within tolerance; marker alignment ±1 s.

### F14 [QL] Failed translations are permanent; failed Apple session never retried on start
- Pipeline failure path (≈243-273) never re-queues; `startSession` calls
  `translationEngine.activate()` with default `retryIfFailed: false` (AppModel ≈165;
  AppleTranslationEngine ≈62-87). Language-pack window → permanently English-only segments.
- **Fix:** `activate(retryIfFailed: true)` on start; add `retranslateMissing()` on the pipeline,
  invoked when the engine becomes ready and in `completeSession` before save.
- **Tests:** engine failing first N calls then recovering → all segments end translated.

### F15 [AD] Migration posture: no schema version; enum rename hazard; fragile `list()`
- Keep `ProcessingMode.highAccuracy` rawValue forever (rename UI label only; future cloud mode is
  a NEW case). Add optional `schemaVersion` now. `SessionStore.list()` (≈40-52) rethrows per-file
  errors — one corrupt JSON would hide all sessions (latent; no production caller yet) → make it
  per-file tolerant before a session browser ships.
- **Tests:** legacy fixture decodes; unknown `processingMode` string falls back once custom
  decoding lands; `list()` skips a planted corrupt file.

### F16 [SP] Privacy: plaintext storage, orphaned hidden temps, failure-path deletion
- Product design (PRODUCT_DESIGN.md:401) requires encryption — milestone, not this pass. The
  retention inconsistency (user chose keep; failure deletes) is covered by F1; temp litter by
  F2's sweep.

### F17 [DM] Documentation mismatches (verified)
- All ten items in the original review brief §9 confirmed. Additionally: README.md:38 claims
  "selected macOS input device" — no device selection exists (default input only);
  `.paused` is a dead state (no `pauseSession` anywhere; `SessionStateMachine.swift` ≈42-47,
  AppModel ≈123/311/616) — implement or remove; PRODUCT_DESIGN menu-bar controls don't exist.
  Fix docs in the same PR as related code, or a single docs-truth pass at the end.

### F18 [AD] AppModel (864 lines): extract only a `SessionRunner`
- Owns per-session pipeline/engine/capture + the three consumer tasks with a single `teardown()`;
  makes the F3 bug class structurally impossible. Do it opportunistically while fixing F3 if the
  diff stays small; otherwise defer. Do NOT rewrite the state machine or split further now.

**Known-good — do not churn:** atomic JSON writes; idempotent `finalize`/`stop`; bounded replay
chunks; `bufferingNewest(1)` snapshot delivery; serialized Apple session + its concurrency tests;
pinned model revisions and exact dependency versions; brand-migration paths (dirs/defaults/env);
quality gate (placeholder restore, number equivalence incl. Chinese numerals, Trad→Simp);
benchmark CLIs and private-data hygiene.

## 3. Implementation order

**Iteration 1 — never lose a class:** F1 → F2 → F3 → F4 → F12, each with its tests, one commit
per finding. These interact (F12 exercises F4/F2 paths), so keep the order.

**Iteration 2 — classroom quality:** F8 → F6 → F7 → F5 → F11 → F9 (flagged + benchmarked) → F10.
F13/F14/F15 fit wherever adjacent code is already open; F16 encryption and the Soniox adapter are
explicitly out of scope.

## 4. Acceptance criteria

- `swift test` fully green, including all new tests; no existing test modified except to reflect
  intentionally changed behavior (call those out explicitly).
- No new dependencies. No stored-format breaking changes (prove with the legacy-fixture tests).
- Existing session JSONs from before your changes still load.
- Final summary: per finding — agree/disagree after verification, what changed, which tests cover
  it; plus anything you found that this review missed.
