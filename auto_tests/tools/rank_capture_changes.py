#!/usr/bin/env python3
from __future__ import annotations

import argparse
from pathlib import Path

from PIL import Image, ImageChops, ImageStat


def image_score(previous: Path, current: Path) -> float:
    with Image.open(previous) as left, Image.open(current) as right:
        left = left.convert("RGB").resize((320, 180))
        right = right.convert("RGB").resize((320, 180))
        diff = ImageChops.difference(left, right)
        stat = ImageStat.Stat(diff)
        return sum(stat.mean) / len(stat.mean)


def ranked_changes(directory: Path, pattern: str) -> list[tuple[float, Path, Path]]:
    frames = sorted(directory.glob(pattern))
    changes: list[tuple[float, Path, Path]] = []
    for previous, current in zip(frames, frames[1:], strict=False):
        try:
            changes.append((image_score(previous, current), previous, current))
        except OSError as exc:
            print(f"skip {current}: {exc}")
    return sorted(changes, reverse=True, key=lambda item: item[0])


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Rank VNC screenshots by frame-to-frame visual change."
    )
    parser.add_argument("directory", type=Path)
    parser.add_argument("--pattern", default="*.png")
    parser.add_argument("--top", type=int, default=20)
    args = parser.parse_args()

    for score, previous, current in ranked_changes(args.directory, args.pattern)[: args.top]:
        print(f"{score:8.3f}  {previous.name} -> {current.name}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
