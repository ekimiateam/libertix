#!/usr/bin/env python3
"""Render one distribution-neutral Libertix GRUB menu."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def resolve_translation_catalogue_path() -> Path:
    adjacent = Path(__file__).with_name("Libertix.Translations.json")
    source_tree = Path(__file__).resolve().parents[1] / "Resources/Libertix.Translations.json"
    return adjacent if adjacent.is_file() else source_tree


TRANSLATION_CATALOGUE_PATH = resolve_translation_catalogue_path()


def load_grub_labels(language: object) -> dict[str, str]:
    catalogue = json.loads(TRANSLATION_CATALOGUE_PATH.read_text(encoding="utf-8"))
    if language not in catalogue["supportedLanguages"]:
        raise ValueError("installation plan has an unsupported GRUB language")
    return catalogue["languages"][language]["grub"]


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


# A title may be several quoted pieces, e.g. grub_quote's 'l'\''OS'.
MENU_ENTRY = re.compile(
    r"^(\s*(?:menuentry|submenu)\s+(?:'[^']*'|\"[^\"]*\"|\\.)+)(.*?)(\s*\{)?\s*$"
)
MENU_ENTRY_ID = re.compile(r"(?:\$menuentry_id_option|--id)\s+(?:'([^']*)'|\"([^\"]*)\")")


def add_icon_classes(lines: list[str], distribution_icon: str) -> list[str]:
    """Give generated advanced entries an icon for what they do.

    GRUB shows the icon of the first class that has one, so a known function
    goes first. Menu ids are matched instead of titles because titles are
    translated. Ids follow the Ubuntu 24.04 10_linux, 20_memtest86+ and
    30_uefi-firmware generators.

    Every entry also ends with ``find.none``, a transparent icon. The theme
    reserves icon space, and an entry with no loadable class icon can make GRUB
    try to scale a null bitmap when a submenu is first painted. Putting it last
    keeps that guard without hiding the generator's own classes.
    """
    functions = (
        ("gnulinux-advanced-", "submenu"),
        # "recovery" is also used by the live installer menu, for diagnostics.
        ("gnulinux-.+-recovery-", "recovery-mode"),
        ("gnulinux-.+-advanced-", distribution_icon),
        ("memtest86", "memtest"),
        ("uefi-firmware$", "firmware"),
    )
    result = []
    for line in lines:
        entry = MENU_ENTRY.match(line)
        if entry is None:
            result.append(line)
            continue
        head, options, brace = entry.groups()
        entry_id = MENU_ENTRY_ID.search(options)
        menu_id = (entry_id[1] or entry_id[2] or "") if entry_id else ""
        icon = next((icon for prefix, icon in functions if re.match(prefix, menu_id)), None)
        if icon:
            head += f" --class {icon}"
        result.append(f"{head}{options} --class find.none{brace or ''}")
    return result


def read_distribution_presentation(path: Path) -> tuple[str, str, dict[str, str]]:
    plan = json.loads(path.read_text(encoding="utf-8"))
    distribution = plan.get("distribution")
    if not isinstance(distribution, dict):
        raise ValueError("installation plan has no distribution object")
    display_name = distribution.get("grubDisplayName")
    icon = distribution.get("grubIcon")
    if not isinstance(display_name, str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}", display_name
    ):
        raise ValueError("installation plan has an unsafe GRUB display name")
    if not isinstance(icon, str) or not re.fullmatch(
        r"[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?", icon
    ):
        raise ValueError("installation plan has an unsafe GRUB icon")
    locale = plan.get("locale")
    if not isinstance(locale, dict):
        raise ValueError("installation plan has no locale object")
    language = locale.get("languageCode")
    return display_name, icon, load_grub_labels(language)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--linux", type=Path, required=True)
    parser.add_argument("--windows", type=Path, required=True)
    parser.add_argument("--firmware", type=Path)
    parser.add_argument("--extra", type=Path, action="append", default=[])
    parser.add_argument("--plan", type=Path, required=True)
    args = parser.parse_args()
    display_name, icon, labels = read_distribution_presentation(args.plan)

    linux = read_lines(args.linux)
    simple_start, simple_end = extract_top_level_block(linux, "menuentry ")
    advanced_start, advanced_end = extract_top_level_block(linux, "submenu ")
    if advanced_start < simple_end:
        raise ValueError("unexpected Linux GRUB generator ordering")

    simple = linux[simple_start:simple_end]
    if "--class " not in simple[0]:
        raise ValueError("Linux GRUB entry has no class marker")
    simple[0], replacements = re.subn(
        r"^(menuentry\s+)(?:'[^']*'|\"[^\"]*\")",
        rf"\1'{display_name}'",
        simple[0],
        count=1,
    )
    if replacements != 1:
        raise ValueError("Linux GRUB entry title could not be replaced")
    simple[0] = simple[0].replace("--class ", f"--class {icon} --class ", 1)

    advanced = add_icon_classes(linux[advanced_start:advanced_end], icon)
    windows = read_lines(args.windows)
    firmware = (
        add_icon_classes(read_lines(args.firmware), icon)
        if args.firmware and args.firmware.exists()
        else []
    )
    extra = [
        line
        for path in args.extra
        if path.exists()
        for line in add_icon_classes(read_lines(path), icon)
    ]

    output: list[str] = []
    output.extend(linux[:simple_start])
    output.extend(simple)
    output.extend(windows)
    output.extend(
        [
            f"menuentry '{labels['shutdown']}' --class shutdown --id libertix-shutdown {{",
            "\thalt",
            "}",
            f"submenu '{labels['advanced']}' --class efi --id libertix-advanced {{",
        ]
    )
    output.extend(indent(advanced))
    if firmware:
        output.extend(indent(firmware))
    if extra:
        output.extend(indent(extra))
    output.append("}")
    output.extend(linux[advanced_end:])

    print("\n".join(output))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
