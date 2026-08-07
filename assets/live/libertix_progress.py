#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

StageCatalogue = dict[str, tuple[str, int, int]]


def load_stage_catalogue(path: Path) -> StageCatalogue:
    stages: StageCatalogue = {}
    for line_number, line in enumerate(path.read_text(encoding="ascii").splitlines(), start=1):
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) not in (3, 4):
            raise RuntimeError(f"invalid stage catalogue line {line_number}")
        stage, translation_key, raw_percent = fields[:3]
        percent = int(raw_percent)
        end_percent = int(fields[3]) if len(fields) == 4 else percent
        if not stage or not translation_key or not 0 <= percent <= end_percent <= 100:
            raise RuntimeError(f"invalid stage catalogue line {line_number}")
        stages[stage] = (translation_key, percent, end_percent)
    return stages


def stage_subpercent(log_path: Path, stage: str) -> int | None:
    try:
        lines = log_path.read_text(errors="replace").replace("\r", "\n").splitlines()
    except OSError:
        return None

    start = -1
    for index, line in enumerate(lines):
        if line.strip() == f"STAGE: {stage}":
            start = index
    if start < 0:
        return None

    values: list[int] = []
    for line in lines[start + 1 :]:
        if line.startswith("STAGE: "):
            break
        for match in re.finditer(r"(?<!\d)(\d{1,3})\s*%", line):
            value = int(match.group(1))
            if 0 <= value <= 100:
                values.append(value)
        for match in re.finditer(r"(?<!\d)(\d+)\s*/\s*(\d+)(?!\d)", line):
            done = int(match.group(1))
            total = int(match.group(2))
            if total > 0:
                values.append(max(0, min(100, done * 100 // total)))
    return max(values) if values else None


def stage_progress(
    log_path: Path,
    stage: str,
    stages: StageCatalogue,
) -> tuple[int, int | None]:
    _translation_key, start, end = stages.get(stage, ("", 1, 1))
    if end == start:
        return start, None
    subpercent = stage_subpercent(log_path, stage)
    if subpercent is None:
        return start, None
    return start + (end - start) * subpercent // 100, subpercent


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalogue", type=Path, required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--stage", required=True)
    args = parser.parse_args()
    percent, subpercent = stage_progress(
        args.log,
        args.stage,
        load_stage_catalogue(args.catalogue),
    )
    print(f"{percent}\t{'' if subpercent is None else subpercent}")


if __name__ == "__main__":
    main()
