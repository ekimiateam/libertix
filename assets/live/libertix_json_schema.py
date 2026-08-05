#!/usr/bin/env python3
"""Validate Libertix runtime documents against their versioned JSON schemas."""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

from jsonschema import Draft202012Validator, FormatChecker

MODULE_DIRECTORY = Path(__file__).resolve().parent
SCHEMA_DIRECTORIES = (
    MODULE_DIRECTORY / "schemas",
    MODULE_DIRECTORY.parents[1] / "schemas",
)


def _schema_path(schema_name: str) -> Path:
    for directory in SCHEMA_DIRECTORIES:
        candidate = directory / schema_name
        if candidate.is_file():
            return candidate
    searched = ", ".join(str(directory) for directory in SCHEMA_DIRECTORIES)
    raise FileNotFoundError(f"cannot find {schema_name}; searched: {searched}")


@lru_cache(maxsize=2)
def _validator(schema_name: str) -> Draft202012Validator:
    schema_path = _schema_path(schema_name)
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema, format_checker=FormatChecker())


def validate_json_schema(schema_name: str, value: Any) -> None:
    """Raise ValueError with the first stable validation error, if any."""

    errors = sorted(
        _validator(schema_name).iter_errors(value),
        key=lambda error: tuple(str(part) for part in error.absolute_path),
    )
    if not errors:
        return

    error = errors[0]
    location = ".".join(str(part) for part in error.absolute_path) or "document"
    raise ValueError(f"{location}: {error.message}")
