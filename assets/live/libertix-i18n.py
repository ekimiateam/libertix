#!/usr/bin/env python3
"""Load the shared Libertix live-environment translation catalogue."""

from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path


def resolve_catalogue_path() -> Path:
    adjacent = Path(__file__).with_name("Libertix.Translations.json")
    source_tree = Path(__file__).resolve().parents[2] / "Resources/Libertix.Translations.json"
    return adjacent if adjacent.is_file() else source_tree


CATALOGUE_PATH = resolve_catalogue_path()


def load_translation_catalogue() -> dict[str, object]:
    catalogue = json.loads(CATALOGUE_PATH.read_text(encoding="utf-8"))
    if not isinstance(catalogue, dict):
        raise ValueError("Libertix translation catalogue must be an object")
    return catalogue


CATALOGUE = load_translation_catalogue()
SUPPORTED_LANGUAGES = frozenset(CATALOGUE["supportedLanguages"])


def normalize_language(language: str | None) -> str:
    candidate = (language or "en").strip().lower().split("_", 1)[0]
    return candidate if candidate in SUPPORTED_LANGUAGES else "en"


def load_catalogue(language: str | None) -> dict[str, str]:
    selected = normalize_language(language)
    languages = CATALOGUE["languages"]
    translations = languages[selected]["live"]
    fallback = languages["en"]["live"]
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
