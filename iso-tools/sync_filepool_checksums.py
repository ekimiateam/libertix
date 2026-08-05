#!/usr/bin/env python3
"""Synchronize mini-ISO hashes in the filepool distribution metadata."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_METADATA = REPOSITORY_ROOT / "auto_tests" / "app" / "filepool" / "distros.json"


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def update_metadata(
    metadata_path: Path,
    bios_iso: Path | None,
    uefi_iso: Path | None,
) -> None:
    distributions = json.loads(metadata_path.read_text(encoding="utf-8"))
    if not isinstance(distributions, list) or not distributions:
        raise ValueError("Distribution metadata must contain at least one entry.")

    updates = (
        ("isoUrl", "isoSha256", bios_iso),
        ("uefiIsoUrl", "uefiIsoSha256", uefi_iso),
    )
    for url_key, hash_key, artifact in updates:
        if artifact is None:
            continue
        artifact = artifact.resolve(strict=True)
        matches = [entry for entry in distributions if entry.get(url_key) == artifact.name]
        if len(matches) != 1:
            raise ValueError(
                f"Expected exactly one distribution for {artifact.name}, found {len(matches)}."
            )
        matches[0][hash_key] = sha256(artifact)

    # Readers must see either the previous complete catalogue or the new one.
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=metadata_path.parent,
        prefix=f".{metadata_path.name}.",
        suffix=".tmp",
        delete=False,
    ) as temporary:
        json.dump(distributions, temporary, ensure_ascii=False, indent=2)
        temporary.write("\n")
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, metadata_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--bios", type=Path)
    parser.add_argument("--uefi", type=Path)
    args = parser.parse_args()
    if args.bios is None and args.uefi is None:
        parser.error("at least one of --bios or --uefi is required")
    return args


def main() -> None:
    args = parse_args()
    update_metadata(args.metadata, args.bios, args.uefi)


if __name__ == "__main__":
    main()
