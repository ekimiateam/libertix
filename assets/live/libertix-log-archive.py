#!/usr/bin/env python3
"""Archive public live diagnostics without traversing private runtime state."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import stat
from pathlib import Path

PUBLIC_FILES = frozenset(
    {
        "stage",
        "failure",
        "result.env",
        "windows-partition",
        "context-load-error",
        "installation-plan.json",
        "installation-state.json",
        "mbr-before-grub.bin",
        "log-copy-status.txt",
        "tty1-screen",
        "tty1-screen.last",
        "gui-ready",
        "gui-heartbeat",
        "dev-terminal",
        "SHA256SUMS",
    }
)


def is_public_diagnostic(name: str) -> bool:
    return name in PUBLIC_FILES or bool(
        re.fullmatch(r"(?:[A-Za-z0-9_.-]+\.log(?:\.old)?|[0-9]{3}-[a-z0-9-]+\.started)", name)
    )


def copy_diagnostics(source: Path, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for path in sorted(source.iterdir()):
        # Never recurse into plan probes or follow links to mounted media or secrets.
        if not is_public_diagnostic(path.name) or not stat.S_ISREG(path.lstat().st_mode):
            continue
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as incoming:
            if not stat.S_ISREG(os.fstat(incoming.fileno()).st_mode):
                raise ValueError("A diagnostic changed type while being archived")
            output = destination / path.name
            descriptor = os.open(
                output, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600
            )
            with os.fdopen(descriptor, "wb") as outgoing:
                shutil.copyfileobj(incoming, outgoing)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    copy_diagnostics(args.source, args.destination)


if __name__ == "__main__":
    main()
