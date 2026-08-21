#!/usr/bin/env python3
"""Verify and stage the runtime support files published with Libertix."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
from pathlib import Path
from typing import NamedTuple

SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


class SupportArtifact(NamedTuple):
    file_name: str
    sha256: str


def _require_file_name(value: object, field: str) -> str:
    if not isinstance(value, str) or not value or Path(value).name != value:
        raise ValueError(f"{field} must be a file name")
    return value


def _require_sha256(value: object, field: str) -> str:
    if not isinstance(value, str) or not SHA256_PATTERN.fullmatch(value):
        raise ValueError(f"{field} must be a lowercase SHA-256 hash")
    return value


def load_support_artifacts(catalog_path: Path) -> tuple[SupportArtifact, ...]:
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    try:
        definitions = (
            (
                catalog["aria2"]["archiveFileName"],
                catalog["aria2"]["archiveSha256"],
                "aria2.archiveFileName",
                "aria2.archiveSha256",
            ),
            (
                catalog["ext4Driver"]["fileName"],
                catalog["ext4Driver"]["sha256"],
                "ext4Driver.fileName",
                "ext4Driver.sha256",
            ),
            (
                catalog["grub4Dos"]["loaderFileName"],
                catalog["grub4Dos"]["loaderSha256"],
                "grub4Dos.loaderFileName",
                "grub4Dos.loaderSha256",
            ),
            (
                catalog["grub4Dos"]["mbrLoaderFileName"],
                catalog["grub4Dos"]["mbrLoaderSha256"],
                "grub4Dos.mbrLoaderFileName",
                "grub4Dos.mbrLoaderSha256",
            ),
        )
    except (KeyError, TypeError) as error:
        raise ValueError("artifact catalogue is incomplete") from error

    artifacts = tuple(
        SupportArtifact(
            _require_file_name(file_name, file_field),
            _require_sha256(sha256, sha_field),
        )
        for file_name, sha256, file_field, sha_field in definitions
    )
    names = [artifact.file_name.casefold() for artifact in artifacts]
    if len(names) != len(set(names)):
        raise ValueError("support artifact file names must be unique")
    return artifacts


def file_sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def stage_support_artifacts(
    catalog_path: Path,
    source_dir: Path,
    output_dir: Path,
) -> tuple[Path, ...]:
    artifacts = load_support_artifacts(catalog_path)
    output_dir.mkdir(parents=True, exist_ok=True)
    staged: list[Path] = []
    for artifact in artifacts:
        source = (source_dir / artifact.file_name).resolve(strict=True)
        if not source.is_file():
            raise ValueError(f"support artifact is not a regular file: {source}")
        actual_sha256 = file_sha256(source)
        if actual_sha256 != artifact.sha256:
            raise ValueError(
                f"support artifact SHA-256 mismatch for {artifact.file_name}: "
                f"expected {artifact.sha256}, got {actual_sha256}"
            )
        destination = output_dir / artifact.file_name
        shutil.copyfile(source, destination)
        staged.append(destination)
    return tuple(staged)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    for path in stage_support_artifacts(args.catalog, args.source_dir, args.output_dir):
        print(path.name)


if __name__ == "__main__":
    main()
