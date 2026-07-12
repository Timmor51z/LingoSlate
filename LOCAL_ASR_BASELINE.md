# Local ASR baseline

This baseline uses one private 59-minute English university orientation recording. The audio and transcripts remain in Git-ignored directories; only aggregate measurements are recorded here.

## Configuration

- Models: FluidAudio Parakeet EOU 120M (320 ms) and Parakeet Unified 0.6B (640 ms).
- Hardware: Apple silicon development Mac.
- Reference: LecSync output on the same audio, not manually corrected ground truth.
- Alignment: five-minute timestamp windows.
- Subtitle finalization: every 15 seconds or at a detected end of utterance.

## Results

Audio duration is 3,556.9 seconds and the LecSync competitor reference contains 9,084 words.

| Metric | EOU 120M raw | EOU 120M adaptive | Unified 0.6B raw |
| --- | ---: | ---: | ---: |
| Local inference time | 148.5 s | 177.7 s | 466.6 s |
| Offline processing speed | 23.95x | 20.01x | 7.62x |
| LingoSlate hypothesis words | 6,087 | 6,737 | 8,409 |
| Agreement error rate | 52.59% | 49.88% | 28.69% |
| Normalized-word recall | 61.51% | 67.99% | 87.68% |
| Normalized-word precision | 91.80% | 91.67% | 94.72% |
| Normalized-word F1 | 73.67% | 78.07% | 91.06% |
| Acronym exact recall | 18 / 49 | 20 / 49 | 35 / 49 |
| Number exact recall | 0 / 52 | 0 / 52 | 26 / 52 |

## Interpretation

Adaptive gain recovers useful content for the 120M model, but the improvement is not large enough to change its product role. It remains an energy-saving draft tier.

Unified 0.6B materially reduces omissions, improves critical-token recall, and produced no subtitle gaps longer than one second in this benchmark. It remains more than seven times faster than real time during offline replay and is the default high-accuracy local tier. On the low-volume 10-minute subset, raw audio slightly outperformed adaptive gain, so gain processing is intentionally disabled for Unified.

The agreement error rate is not ground-truth WER: LecSync can also be wrong, and differences in punctuation, formatting, segmentation, and speaker handling affect the score. Number recall is especially misleading until inverse text normalization maps spoken forms such as `twenty twenty-six` to forms such as `2026`.

The next quality gate is a manually corrected 10-15 minute subset plus live battery, thermal, latency, and 90-minute stability testing. Translation quality must be evaluated only after the stabilized English transcript is available.
