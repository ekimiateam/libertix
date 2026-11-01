#!/usr/bin/env python3
"""Remove only the Windows boot files declared by this installation."""

import argparse
import hashlib
import json
import os
import re
from pathlib import Path

NAMES = {"grldr", "grldr.mbr", "menu.lst"}


def remove_payload(windows_root: Path, plan_id: str) -> None:
    manifest_path = windows_root / "LibertixInstallRecovery/bios-boot-payload.json"
    if manifest_path.is_symlink() or manifest_path.parent.is_symlink():
        raise ValueError("BIOS boot ownership manifest cannot be a symlink")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    files = manifest.get("files")
    if (
        not re.fullmatch(r"[0-9a-f]{32}", plan_id)
        or manifest.get("version") != 1
        or manifest.get("planId") != plan_id
        or not isinstance(files, dict)
        or set(files) != NAMES
    ):
        raise ValueError("BIOS boot ownership manifest is invalid")
    owned = []
    for name, expected_hash in files.items():
        if not isinstance(expected_hash, str) or not re.fullmatch(r"[0-9a-f]{64}", expected_hash):
            raise ValueError("Invalid BIOS boot payload hash")
        path = windows_root / name
        if path.is_symlink():
            raise ValueError(f"BIOS boot file cannot be a symlink: {name}")
        if not path.exists():
            continue
        with path.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() != expected_hash:
                raise ValueError(f"Refusing to delete an unverified BIOS boot file: {name}")
        owned.append(path)
    for path in owned:
        path.unlink()
    descriptor = os.open(windows_root, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("windows_root", type=Path)
    parser.add_argument("plan_id")
    args = parser.parse_args()
    remove_payload(args.windows_root, args.plan_id)
