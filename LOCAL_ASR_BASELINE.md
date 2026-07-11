# Local ASR baseline

This baseline uses one private 59-minute English university orientation recording. The audio and transcripts remain in Git-ignored directories; only aggregate measurements are recorded here.

## Configuration

- Model: FluidAudio Parakeet EOU 120M, 320 ms streaming configuration.
- Hardware: Apple silicon development Mac.
- Reference: LecSync output on the same audio, not manually corrected ground truth.
- Alignment: five-minute timestamp windows.
- Subtitle finalization: every 15 seconds or at a detected end of utterance.

## Results

| Metric | Result |
| --- | ---: |
| Audio duration | 3,556.9 seconds |
| Local inference time | 148.5 seconds |
| Offline processing speed | 23.95x real time |
| LecSync reference words | 9,084 |
| LecCue hypothesis words | 6,087 |
| Agreement error rate | 52.59% |
| Normalized-word recall | 61.51% |
| Normalized-word precision | 91.80% |
| Normalized-word F1 | 73.67% |
| Acronym exact recall | 18 / 49 |
| Number exact recall | 0 / 52 |

## Interpretation

The 120M model is fast enough for real-time captions and inexpensive offline reprocessing. Most words it emits also appear in the LecSync transcript, but it omits substantially more content. It is therefore useful as a low-power draft tier, not yet as the release-quality classroom recognizer.

The agreement error rate is not ground-truth WER: LecSync can also be wrong, and differences in punctuation, formatting, segmentation, and speaker handling affect the score. Number recall is especially misleading until inverse text normalization maps spoken forms such as `twenty twenty-six` to forms such as `2026`.

The next model decision should be based on the same private audio and a manually corrected 10-15 minute subset. A larger local recognizer should be accepted only if it materially improves recall and technical-term accuracy while retaining real-time performance and reasonable battery use.
