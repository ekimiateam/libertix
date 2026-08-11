#!/usr/bin/env python3
"""Load the shared Libertix live-environment translation catalogue."""

from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path

SUPPORTED_LANGUAGES = {"en", "fr", "es", "ja"}
CATALOGUE_PATH = Path(__file__).with_name("libertix-translations.json")


def normalize_language(language: str | None) -> str:
    candidate = (language or "en").strip().lower().split("_", 1)[0]
    return candidate if candidate in SUPPORTED_LANGUAGES else "en"


def load_catalogue(language: str | None) -> dict[str, str]:
    catalogue = json.loads(CATALOGUE_PATH.read_text(encoding="utf-8"))
    selected = normalize_language(language)
    translations = catalogue[selected]
    fallback = catalogue["en"]
    return {key: translations.get(key, value) for key, value in fallback.items()}


def translate(catalogue: dict[str, str], key: str, **values: object) -> str:
    text = catalogue.get(key, key)
    return text.format(**values) if values else text


def export_shell(language: str | None) -> None:
    for key, value in sorted(load_catalogue(language).items()):
        variable = "LIBERTIX_I18N_" + key.upper()
        print(f"{variable}={shlex.quote(value)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("export-shell",))
    parser.add_argument("language", nargs="?", default="en")
    arguments = parser.parse_args()
    if arguments.command == "export-shell":
        export_shell(arguments.language)


if __name__ == "__main__":
    main()
