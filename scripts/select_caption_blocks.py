#!/usr/bin/env python3
"""Select readable caption windows from dense OCR observations."""

import argparse
import json
import re
from pathlib import Path


COMMON = set(
    """a about actually all also an and are as at be because been but by can could did do
    does for from get go going good had has have he her here how i if in into is it its
    just know like me more my no not of on one or our out people really right so some
    something than that the their them then there these they this through to too up us
    very want was we well were what when where which who why will with would you your
    i'm i've i'll you're you've we're we've they're that's it's don't doesn't didn't
    can't couldn't won't wouldn't""".split()
)
OVERLAYS = (
    "tactiq",
    "transcribing this call",
    "participants chat react",
    "hide captions",
    "from harry to everyone",
    "ai extension",
)


def clean_line(line: str) -> str:
    line = " ".join(line.replace("|", "I").split()).strip(" ._-=~")
    lowered = line.lower()
    if any(marker in lowered for marker in OVERLAYS):
        return ""
    words = re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)?", line)
    if not words:
        return ""
    normalized = [word.lower() for word in words]
    common_rate = sum(word in COMMON for word in normalized) / len(words)
    mixed_rate = sum(
        any(char.isupper() for char in word[1:]) and any(char.islower() for char in word)
        for word in words
    ) / len(words)
    if len(words) >= 7 and (common_rate < 0.08 or mixed_rate > 0.35):
        return ""
    if len(words) < 3 and lowered not in {"yes", "yep", "yeah", "okay", "right", "so", "hmm"}:
        return ""
    return line


def clean_text(text: str) -> str:
    lines = [clean_line(line) for line in text.splitlines()]
    return " ".join(line for line in lines if line)


def score(text: str, time_in_bucket: float) -> float:
    words = re.findall(r"[A-Za-z]+(?:'[A-Za-z]+)?", text)
    common = sum(word.lower() in COMMON for word in words)
    excess = max(0, len(words) - 80)
    return min(len(words), 80) + common * 1.5 - excess * 2 + time_in_bucket / 20


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--seconds", type=int, default=15)
    args = parser.parse_args()

    buckets: dict[int, list[dict]] = {}
    for line in args.input.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        record["text"] = clean_text(record["text"])
        if record["text"]:
            buckets.setdefault(int(record["time"] // args.seconds), []).append(record)

    selected = []
    for bucket, records in sorted(buckets.items()):
        start = bucket * args.seconds
        best = max(records, key=lambda item: score(item["text"], item["time"] - start))
        selected.append(best)

    args.output.write_text(json.dumps(selected, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"selected {len(selected)} caption windows")


if __name__ == "__main__":
    assert not clean_line("Hi, I'm transcribing this call with my Tactiq AI Extension.")
    assert clean_line("Interviews are a two-way conversation.")
    main()
