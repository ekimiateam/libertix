#!/usr/bin/env python3
"""Preserve Windows permissions on files published by Linux."""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path

NTFS_SECURITY_ATTRIBUTE = "system.ntfs_acl"
MAX_XATTR_BYTES = 65536


def read_permissions(path: Path) -> bytes:
    # NTFS-3G can return an oversized reply instead of ERANGE for Python's
    # initial 128-byte buffer. Reserve the Linux xattr limit before reading.
    libc = ctypes.CDLL(None, use_errno=True)
    read_attribute = libc.lgetxattr
    read_attribute.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t]
    read_attribute.restype = ctypes.c_ssize_t
    buffer = ctypes.create_string_buffer(MAX_XATTR_BYTES)
    size = read_attribute(os.fsencode(path), NTFS_SECURITY_ATTRIBUTE.encode(), buffer, len(buffer))
    if size < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(path))
    return buffer.raw[:size]


def inherit_permissions(path: Path, *, recursive: bool = False) -> None:
    if path.is_symlink() or path.parent.is_symlink():
        raise ValueError(f"Cannot inherit Windows permissions through a symbolic link: {path}")
    # Linux modes alone do not restrict Windows access on an unmapped NTFS mount.
    # The parent was protected by Windows before the installation reboot.
    descriptor = read_permissions(path.parent)
    os.setxattr(path, NTFS_SECURITY_ATTRIBUTE, descriptor, follow_symlinks=False)
    if read_permissions(path) != descriptor:
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
