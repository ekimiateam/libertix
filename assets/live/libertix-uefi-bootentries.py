#!/usr/bin/env python3
"""Select UEFI boot entries that target one exact GPT ESP and loader."""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass

BOOT_LINE = re.compile(r"^Boot(?P<number>[0-9A-Fa-f]{4})(?:\*)?\s+(?P<body>.+)$")
HARD_DRIVE_NODE = re.compile(
    r"HD\(\s*(?P<partition>[0-9]+)\s*,\s*GPT\s*,\s*"
    r"(?P<guid>[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})\s*,",
    re.IGNORECASE,
)
FILE_PATH_NODE = re.compile(r"File\((?P<path>[^)]*)\)", re.IGNORECASE)
GPT_GUID = re.compile(r"^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$")


@dataclass(frozen=True)
class BootEntry:
    number: str
    description: str
    partition_number: int
    partition_guid: str
    loader_path: str


def normalize_loader_path(value: str) -> str:
    normalized = value.strip().replace("/", "\\")
    return re.sub(r"\\+", r"\\", normalized).casefold()


def parse_boot_entry(line: str) -> BootEntry | None:
    boot_match = BOOT_LINE.match(line.strip())
    if not boot_match:
        return None
    body = boot_match.group("body")
    hard_drive_match = HARD_DRIVE_NODE.search(body)
    file_path_match = FILE_PATH_NODE.search(body)
    if not hard_drive_match or not file_path_match:
        return None
    description = body[: hard_drive_match.start()].strip()
    return BootEntry(
        number=boot_match.group("number").upper(),
        description=description,
        partition_number=int(hard_drive_match.group("partition")),
        partition_guid=hard_drive_match.group("guid").casefold(),
        loader_path=normalize_loader_path(file_path_match.group("path")),
    )


def find_matching_boot_numbers(
    text: str,
    *,
    description: str,
    loader_path: str,
    partition_number: int,
    partition_guid: str,
) -> list[str]:
    expected_loader = normalize_loader_path(loader_path)
    expected_guid = partition_guid.casefold()
    matches: list[str] = []
    for line in text.splitlines():
        entry = parse_boot_entry(line)
        if entry is None:
            continue
        if (
            entry.description == description
            and entry.loader_path == expected_loader
            and entry.partition_number == partition_number
            and entry.partition_guid == expected_guid
        ):
            matches.append(entry.number)
    return matches


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--description", required=True)
    parser.add_argument("--loader-path", required=True)
    parser.add_argument("--partition-number", required=True, type=int)
    parser.add_argument("--partition-guid", required=True)
    args = parser.parse_args()
    args.partition_guid = args.partition_guid.casefold()
    if args.partition_number <= 0:
        parser.error("partition number must be positive")
    if not GPT_GUID.fullmatch(args.partition_guid):
        parser.error("partition GUID must use canonical GPT format")
    return args


def main() -> int:
    args = parse_args()
    for boot_number in find_matching_boot_numbers(
        sys.stdin.read(),
        description=args.description,
        loader_path=args.loader_path,
        partition_number=args.partition_number,
        partition_guid=args.partition_guid,
    ):
        print(boot_number)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
