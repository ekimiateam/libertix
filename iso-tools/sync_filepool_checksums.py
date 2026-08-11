#!/usr/bin/env python3
"""Generate a runtime catalog with hashes from built mini-ISO images."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TEMPLATE = REPOSITORY_ROOT / "auto_tests" / "app" / "filepool" / "catalog.json"
DEFAULT_METADATA = REPOSITORY_ROOT / "auto_tests" / "runtime" / "filepool" / "catalog.json"


def load_catalog(path: Path) -> dict[str, object]:
    source = json.loads(path.read_text(encoding="utf-8"))
    if (
        not isinstance(source, dict)
        or set(source) != {"schemaVersion", "artifacts", "distributions"}
        or source.get("schemaVersion") != 1
        or not isinstance(source.get("artifacts"), dict)
        or not isinstance(source.get("distributions"), list)
        or not source["distributions"]
    ):
        raise ValueError("Catalog must contain schemaVersion, artifacts and distributions.")
    return source


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
    *,
    template_path: Path | None = None,
) -> None:
    catalog = load_catalog(template_path or metadata_path)
    existing_catalog: dict[str, object] | None = None
    if template_path is not None and metadata_path.is_file():
        try:
            existing_catalog = load_catalog(metadata_path)
        except (OSError, ValueError, json.JSONDecodeError):
            existing_catalog = None

    artifacts = catalog.get("artifacts")
    if not isinstance(artifacts, dict) or not isinstance(artifacts.get("miniIso"), dict):
        raise ValueError("Catalog artifacts must define miniIso.bios and miniIso.uefi.")
    mini_iso = artifacts["miniIso"]
    assert isinstance(mini_iso, dict)

    updates = (("bios", bios_iso), ("uefi", uefi_iso))
    for key, artifact in updates:
        entry = mini_iso.get(key)
        if not isinstance(entry, dict):
            raise ValueError(f"Catalog miniIso.{key} metadata is missing.")
        if artifact is None:
            if existing_catalog is not None:
                existing_artifacts = existing_catalog.get("artifacts")
                existing_mini_iso = (
                    existing_artifacts.get("miniIso")
                    if isinstance(existing_artifacts, dict)
                    else None
                )
                existing_entry = (
                    existing_mini_iso.get(key) if isinstance(existing_mini_iso, dict) else None
                )
                if isinstance(existing_entry, dict):
                    mini_iso[key] = existing_entry
            continue
        artifact = artifact.resolve(strict=True)
        if entry.get("fileName") != artifact.name:
            raise ValueError(
                f"Catalog miniIso.{key} expects {entry.get('fileName')}, not {artifact.name}."
            )
        entry["url"] = artifact.name
        entry["sha256"] = sha256(artifact)
        entry["sizeBytes"] = artifact.stat().st_size

    metadata_path.parent.mkdir(parents=True, exist_ok=True)
    # Readers must see either the previous complete catalogue or the new one.
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=metadata_path.parent,
        prefix=f".{metadata_path.name}.",
        suffix=".tmp",
        delete=False,
    ) as temporary:
        json.dump(catalog, temporary, ensure_ascii=False, indent=2)
        temporary.write("\n")
        temporary.flush()
        os.fsync(temporary.fileno())
        temporary_path = Path(temporary.name)
    os.replace(temporary_path, metadata_path)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--metadata", type=Path, default=DEFAULT_METADATA)
    parser.add_argument("--template", type=Path, default=DEFAULT_TEMPLATE)
    parser.add_argument("--bios", type=Path)
    parser.add_argument("--uefi", type=Path)
    args = parser.parse_args()
    if args.bios is None and args.uefi is None:
        parser.error("at least one of --bios or --uefi is required")
    return args


def main() -> None:
    args = parse_args()
    update_metadata(
        args.metadata,
        args.bios,
        args.uefi,
        template_path=args.template,
    )


if __name__ == "__main__":
    main()
