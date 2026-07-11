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
Benchmarks/Private/<session-id>/audio.mp3
```

The reference retains only session metadata and segment-level English, Chinese, speaker, timestamps, and confidence.

## Run LecCue

```bash
swift run LecCueBenchmark \
  --model eou120m \
  --audio raw \
  Benchmarks/Private/<session-id>/reference.json \
  Benchmarks/Private/<session-id>/audio.mp3 \
  BenchmarkResults/Private/<session-id>/report.json
```

Available model values are `eou120m`, `unified640`, `unified1120`, and `nemotron1120`. Audio values are `raw` and `adaptive`. High-accuracy models download their private local Core ML assets on first use.

The report includes:

- Word substitutions, deletions, and insertions in five-minute windows.
- Agreement error rate against LecSync output.
- Timestamp-independent normalized-word coverage (precision, recall, and F1).
- Number and acronym recall.
- Audio decoding, model loading, and inference time.
- Local inference speed relative to real time.
- Timestamped LecCue hypothesis segments for later manual review.

Five-minute windows reduce false penalties when the two products choose different subtitle boundaries. Word coverage is a second diagnostic that ignores order and timestamps; it shows whether both transcripts contain similar vocabulary, but it is not an accuracy score.

Number recall currently compares written tokens exactly. A result such as spoken `twenty twenty-six` versus `2026` is counted as a miss until inverse text normalization is added.

## Ground truth

LecSync and LecCue can both make the same mistake. For release-quality WER, manually correct a stratified 10-15 minute subset covering quiet speech, distant speech, accents, technical terms, numbers, and overlapping speakers. Keep that corrected reference private unless every speaker has consented to publication.
