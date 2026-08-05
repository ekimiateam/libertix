#!/usr/bin/env python3
"""Render live boot templates from the shared kernel-argument contract."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

TOKENS = {
    "normal": "@LIBERTIX_NORMAL_KERNEL_ARGUMENTS@",
    "verbose": "@LIBERTIX_VERBOSE_KERNEL_ARGUMENTS@",
}
GRUB_MENU_TOKEN = "@LIBERTIX_GRUB_MENU_ENTRIES@"


def single_line_argument(value: object, name: str) -> str:
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise ValueError(f"{name} must be a non-empty single-line string")
    return value


def replace_argument_tokens(rendered: str, arguments: dict[str, object]) -> str:
    for name, token in TOKENS.items():
        if token in rendered:
            rendered = rendered.replace(token, single_line_argument(arguments.get(name), name))
    return rendered


def render(
    arguments_path: Path,
    template_path: Path,
    grub_menu_template_path: Path,
    output_path: Path,
) -> None:
    arguments = json.loads(arguments_path.read_text(encoding="utf-8"))
    rendered = template_path.read_text(encoding="utf-8")
    if GRUB_MENU_TOKEN in rendered:
        grub_menu = replace_argument_tokens(
            grub_menu_template_path.read_text(encoding="utf-8").rstrip(),
            arguments,
        )
        rendered = rendered.replace(GRUB_MENU_TOKEN, grub_menu)
    rendered = replace_argument_tokens(rendered, arguments)

    unresolved = [token for token in (*TOKENS.values(), GRUB_MENU_TOKEN) if token in rendered]
    if unresolved:
        raise ValueError(f"unresolved boot template tokens: {', '.join(unresolved)}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arguments", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--grub-menu-template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    render(args.arguments, args.template, args.grub_menu_template, args.output)


if __name__ == "__main__":
    main()
