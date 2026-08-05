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


def single_line_argument(value: object, name: str) -> str:
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise ValueError(f"{name} must be a non-empty single-line string")
    return value


def render(arguments_path: Path, template_path: Path, output_path: Path) -> None:
    arguments = json.loads(arguments_path.read_text(encoding="utf-8"))
    rendered = template_path.read_text(encoding="utf-8")
    for name, token in TOKENS.items():
        if rendered.count(token) == 0:
            continue
        rendered = rendered.replace(token, single_line_argument(arguments.get(name), name))

    unresolved = [token for token in TOKENS.values() if token in rendered]
    if unresolved:
        raise ValueError(f"unresolved boot template tokens: {', '.join(unresolved)}")
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--arguments", required=True, type=Path)
    parser.add_argument("--template", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    render(args.arguments, args.template, args.output)


if __name__ == "__main__":
    main()
