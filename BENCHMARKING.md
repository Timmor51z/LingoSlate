# LecCue Local Benchmarking

The benchmark compares LecCue and LecSync on the same audio. It is designed for private local evaluation and does not treat competitor output as ground truth.

## Privacy boundary

- `Benchmarks/Private/` contains source audio and sanitized LecSync references.
- `BenchmarkResults/Private/` contains LecCue transcripts and reports.
- Both directories are ignored by Git.
- The importer removes `userId`, signed audio URLs, raw cache metadata, and account fields from the reference JSON.
- Never move private benchmark artifacts into a tracked fixture directory.

## Prepare a LecSync session

Open the target session in LecSync so its detail response is present in the app cache. Locate the cached detail JSON, then run:

```bash
./scripts/prepare-lecsync-benchmark.sh /path/to/lecsync-detail-cache.json
```

The command creates:

```text
Benchmarks/Private/<session-id>/reference.json
Benchmarks/Private/<session-id>/audio-16k.wav
```

The reference retains only session metadata and segment-level English, Chinese, speaker, timestamps, and confidence.

## Run LecCue

```bash
swift run LecCueBenchmark \
  --model eou120m \
  --audio raw \
  Benchmarks/Private/<session-id>/reference.json \
  Benchmarks/Private/<session-id>/audio-16k.wav \
  BenchmarkResults/Private/<session-id>/report.json
```

Available model values are `eou120m`, `unified640`, `unified1120`, `unifiedOffline`, and `nemotron1120`. Audio values are `raw` and `adaptive`. High-accuracy models download their private local Core ML assets on first use. The offline model buffers the complete audio and emits its transcript only at finish.

The preparation script converts the downloaded source to 16 kHz mono PCM WAV. The benchmark intentionally rejects compressed input because AVFoundation can terminate the process instead of returning a recoverable decoding error for malformed or decoder-incompatible files.

The report includes:

- Word substitutions, deletions, and insertions in five-minute windows.
- Agreement error rate against LecSync output.
- Format-normalized global word-sequence edit distance, used as the primary cross-model comparison.
- Literal global word-sequence distance for auditing normalization effects.
- Timestamp-independent normalized-word coverage (precision, recall, and F1).
- Number and acronym recall.
- Audio decoding, model loading, and inference time.
- Local inference speed relative to real time.
- Timestamped LecCue hypothesis segments for later manual review.

Five-minute windows reduce false penalties when the two products choose different subtitle boundaries. Word coverage is a second diagnostic that ignores order and timestamps; it shows whether both transcripts contain similar vocabulary, but it is not an accuracy score.

Number recall currently compares written tokens exactly. A result such as spoken `twenty twenty-six` versus `2026` is counted as a miss until inverse text normalization is added.

## Current model decision

The July 2026 59-minute local comparison against the same LecSync transcript produced:

| LecCue model | Global agreement error | Speed |
| --- | ---: | ---: |
| Unified 640 ms streaming | 22.11% | 7.62x realtime |
| Unified 1120 ms streaming | 17.85% | 7.29x realtime |
| Unified offline 15 s | 15.75% | 74.69x realtime |

This is format-normalized agreement with competitor output, not ground-truth WER. It supports using Unified 1120 ms for live high-accuracy subtitles and Unified offline 15 s as an automatic post-session refinement. The offline pass improved global agreement error by 2.10 percentage points, or about 11.7% relative, over the 1120 ms stream. A manually corrected reference remains necessary before treating the numbers as release-quality accuracy.

Adaptive gain was also tested across the complete recording with the offline model. It worsened agreement from 15.75% to 16.71% and reduced throughput to 23.14x realtime, so high-accuracy mode intentionally keeps the raw 16 kHz signal. Adaptive gain remains limited to the 120M energy-saving path where it previously improved quiet-speech coverage.

A July 12 repeat with the current dependency and evaluation code produced 18.34% at 6.74x
realtime for Unified 1120 ms and 16.28% at 72.36x realtime for Unified offline. The roughly
half-point movement does not change the product decision. The repeat also confirmed that the
competitor transcript contains errors such as `STEAM` for spoken `STEM`, so these figures must
remain agreement diagnostics rather than advertised WER.

## Ground truth

LecSync and LecCue can both make the same mistake. For release-quality WER, manually correct a stratified 10-15 minute subset covering quiet speech, distant speech, accents, technical terms, numbers, and overlapping speakers. Keep that corrected reference private unless every speaker has consented to publication.

## Translation sampling

The translation benchmark uses LecSync English as input so it can measure translation
separately from LecCue recognition errors. By default it samples 24 segments spread across
the session and limits inputs to 6-36 words, matching LecCue's production translation chunks.

```bash
./scripts/build-mlx-metallib.sh

DEVELOPER_DIR=/Volumes/Disk/Applications/Xcode.app/Contents/Developer \
  swift build --disable-sandbox --product LecCueTranslationBenchmark

cp .build/mlx-metal/mlx.metallib \
  .build/arm64-apple-macosx/debug/mlx.metallib

LECCUE_TRANSLATION_MODEL_PATH=/path/to/translategemma-snapshot \
  .build/arm64-apple-macosx/debug/LecCueTranslationBenchmark \
  --sample-count 24 \
  --term Moodle \
  --glossary "paper outline=课程大纲" \
  Benchmarks/Private/<session-id>/reference.json \
  BenchmarkResults/Private/<session-id>/translation-report.json
```

The report records model loading and per-segment latency, a local character n-gram F-score,
number recall, protected-term recall, glossary-target recall, and every candidate/reference pair. Character overlap is
only a regression diagnostic: valid Chinese translations can use different wording, and the
LecSync Chinese text is not manually corrected. Human bilingual review remains the quality gate.

The July 2026 24-segment production-length sample loaded TranslateGemma 4B in 3.44 seconds
and translated with a 1.05-second median segment latency. It preserved every sampled numeric
token. A phrase-level New Zealand academic glossary improved the local character diagnostic
from 26.34% to 26.50% and improved the reviewed `paper outline`, lab-attendance, and tutorial-
priority examples. Broad replacements such as `paper=课程` and `lab=实验课` were rejected
because they damaged valid phrases such as `submit my paper` and `lab coat`.
