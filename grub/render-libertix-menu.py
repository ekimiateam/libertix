#!/usr/bin/env python3
"""Reorder Mint's generated GRUB entries without freezing kernel versions."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines()


def extract_top_level_block(lines: list[str], prefix: str) -> tuple[int, int]:
    start = next((index for index, line in enumerate(lines) if line.startswith(prefix)), -1)
    if start < 0:
        raise ValueError(f"missing generated GRUB block: {prefix}")

    depth = 0
    for index in range(start, len(lines)):
        depth += lines[index].count("{") - lines[index].count("}")
        if depth == 0:
            return start, index + 1

    raise ValueError(f"unterminated generated GRUB block: {prefix}")


def indent(lines: list[str]) -> list[str]:
    return [f"\t{line}" if line else "" for line in lines]


def add_invisible_icon_class(lines: list[str]) -> list[str]:
    """Give submenu entries a valid transparent icon for GRUB gfxmenu.

    The theme reserves icon space. Entries without any loadable class icon can
    make GRUB attempt to scale a null bitmap when a submenu is first painted.
    ``find.none.png`` is the theme's transparent 48x48 icon.
    """
    entry = re.compile(r"^(\s*(?:menuentry|submenu)\s+(?:'[^']*'|\"[^\"]*\"))(.*)$")
    return [entry.sub(r"\1 --class find.none\2", line) for line in lines]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--linux", type=Path, required=True)
    parser.add_argument("--windows", type=Path, required=True)
    parser.add_argument("--firmware", type=Path)
    args = parser.parse_args()

    linux = read_lines(args.linux)
    simple_start, simple_end = extract_top_level_block(linux, "menuentry ")
    advanced_start, advanced_end = extract_top_level_block(linux, "submenu ")
    if advanced_start < simple_end:
        raise ValueError("unexpected Mint GRUB generator ordering")

    simple = linux[simple_start:simple_end]
    if "--class " not in simple[0]:
        raise ValueError("Mint GRUB entry has no class marker")
    simple[0] = simple[0].replace("--class ", "--class linuxmint --class ", 1)

    advanced = add_invisible_icon_class(linux[advanced_start:advanced_end])
    windows = read_lines(args.windows)
    firmware = (
        add_invisible_icon_class(read_lines(args.firmware))
        if args.firmware and args.firmware.exists()
        else []
    )

    output: list[str] = []
    output.extend(linux[:simple_start])
    output.extend(simple)
    output.extend(windows)
    output.extend(
        [
            "menuentry 'Shutdown' --class shutdown --id libertix-shutdown {",
            "\thalt",
            "}",
            "submenu 'Advanced options' --class efi --id libertix-advanced {",
        ]
    )
    output.extend(indent(advanced))
    if firmware:
        output.extend(indent(firmware))
    output.append("}")
    output.extend(linux[advanced_end:])

    print("\n".join(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
