#!/usr/bin/env python3
"""Recover burned-in Zoom captions from a silent screen recording."""

import argparse
import json
import re
import subprocess
import sys
from difflib import SequenceMatcher
from io import BytesIO
from pathlib import Path

import numpy as np
from PIL import Image


def clean(text: str) -> str:
    lines = [" ".join(line.split()) for line in text.splitlines()]
    return "\n".join(line for line in lines if len(re.sub(r"\W", "", line)) >= 3)


def normalized_words(text: str) -> list[str]:
    return [re.sub(r"\W+", "", word).lower() for word in text.split() if re.sub(r"\W+", "", word)]


def new_tail(previous: str, current: str) -> str:
    """Return only words newly exposed by a rolling caption window."""
    old = normalized_words(previous)[-100:]
    new = current.split()
    norm_new = normalized_words(current)
    if not old:
        return current
    match = SequenceMatcher(None, old, norm_new, autojunk=False).find_longest_match()
    if match.size >= 3 and match.b <= 12:
        return " ".join(new[match.b + match.size :])
    if SequenceMatcher(None, " ".join(old), " ".join(norm_new), autojunk=False).ratio() > 0.72:
        return ""
    return current


def stamp(seconds: float) -> str:
    whole = int(seconds)
    return f"{whole // 3600:02d}:{whole % 3600 // 60:02d}:{whole % 60:02d}"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("video", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--fps", type=float, default=0.5)
    parser.add_argument("--start", type=float, default=0)
    parser.add_argument("--duration", type=float)
    args = parser.parse_args()

    width, height = 610, 95
    command = ["ffmpeg", "-hide_banner", "-loglevel", "error"]
    if args.start:
        command += ["-ss", str(args.start)]
    command += ["-i", str(args.video)]
    if args.duration:
        command += ["-t", str(args.duration)]
    command += [
        "-vf",
        f"fps={args.fps},crop={width}:{height}:180:585,format=gray",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "gray",
        "pipe:1",
    ]

    args.output.parent.mkdir(parents=True, exist_ok=True)
    merged_path = args.output.with_suffix(".merged.txt")
    process = subprocess.Popen(command, stdout=subprocess.PIPE)
    assert process.stdout

    previous_mask = None
    previous_text = ""
    frame_bytes = width * height
    frame_index = 0
    with args.output.open("w", encoding="utf-8") as raw, merged_path.open("w", encoding="utf-8") as merged:
        while frame := process.stdout.read(frame_bytes):
            if len(frame) != frame_bytes:
                break
            gray = np.frombuffer(frame, dtype=np.uint8).reshape(height, width)
            mask = gray > 150
            changed = previous_mask is None or np.mean(mask != previous_mask) > 0.0015
            previous_mask = mask
            timestamp = args.start + frame_index / args.fps
            frame_index += 1
            if not changed:
                continue

            image = Image.fromarray(gray)
            image = image.resize((width * 3, height * 3), Image.Resampling.LANCZOS)
            image = image.point(lambda value: 255 if value >= 150 else 0)
            buffer = BytesIO()
            image.save(buffer, "PNG")
            ocr = subprocess.run(
                ["tesseract", "stdin", "stdout", "-l", "eng", "--psm", "6"],
                input=buffer.getvalue(),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            text = clean(ocr.stdout.decode("utf-8", errors="replace"))
            if not text or SequenceMatcher(None, previous_text, text, autojunk=False).ratio() > 0.97:
                continue

            record = {"time": timestamp, "timestamp": stamp(timestamp), "text": text}
            raw.write(json.dumps(record, ensure_ascii=False) + "\n")
            tail = new_tail(previous_text, text)
            if tail:
                merged.write(f"[{record['timestamp']}] {tail}\n")
            previous_text = text
            if frame_index % max(1, int(args.fps * 120)) == 0:
                print(f"processed {stamp(timestamp)}", file=sys.stderr, flush=True)

    return process.wait()


if __name__ == "__main__":
    assert new_tail("one two three four five", "three four five six seven") == "six seven"
    raise SystemExit(main())
