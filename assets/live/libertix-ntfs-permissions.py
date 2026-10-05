#!/usr/bin/env python3
"""Preserve Windows permissions on files published by Linux."""

from __future__ import annotations

import argparse
import os
from pathlib import Path

NTFS_SECURITY_ATTRIBUTE = "system.ntfs_acl"


def inherit_permissions(path: Path, *, recursive: bool = False) -> None:
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError(f"Cannot inherit Windows permissions through a symbolic link: {path}")
    # Linux modes alone do not restrict Windows access on an unmapped NTFS mount.
    # The parent was protected by Windows before the installation reboot.
    descriptor = os.getxattr(path.parent, NTFS_SECURITY_ATTRIBUTE, follow_symlinks=False)
    os.setxattr(path, NTFS_SECURITY_ATTRIBUTE, descriptor, follow_symlinks=False)
    if os.getxattr(path, NTFS_SECURITY_ATTRIBUTE, follow_symlinks=False) != descriptor:
        raise OSError(f"Windows permissions were not preserved: {path}")
    if recursive and path.is_dir():
        for child in sorted(path.iterdir()):
            inherit_permissions(child, recursive=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recursive", action="store_true")
    parser.add_argument("paths", nargs="+", type=Path)
    args = parser.parse_args()
    for path in args.paths:
        inherit_permissions(path, recursive=args.recursive)


if __name__ == "__main__":
    main()
