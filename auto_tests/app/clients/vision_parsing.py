"""Parsing and image helpers for local vision-model responses."""

from __future__ import annotations

import base64
import io
import json
from pathlib import Path
from typing import Literal

from PIL import Image
from pydantic import ValidationError

from app.clients.vision_models import InstallProgressVerdict
from app.errors import WorkflowError


def load_wizard_json(content: str) -> dict[str, object]:
    """Read only a complete wizard verdict object from model output.

    Scanning complete JSON objects tolerates harmless transport noise without
    treating prose or a repeated prompt as visual evidence.
    """

    decoder = json.JSONDecoder()
    candidates: list[dict[str, object]] = []
    for index, character in enumerate(content):
        if character != "{":
            continue
        try:
            value, _end = decoder.raw_decode(content[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict) and "detected_screen" in value:
            candidates.append(value)
    if not candidates:
        raise json.JSONDecodeError("No complete wizard verdict", content, 0)

    verdict = dict(candidates[-1])
    visible_text = verdict.get("visible_text", "")
    if isinstance(visible_text, list):
        verdict["visible_text"] = "\n".join(str(item) for item in visible_text)
    normalized_text = str(verdict.get("visible_text", "")).casefold()
    screen_markers = (
        (("vérification de compatibilité", "compatibility check"), "compatibility"),
        (("choisissez votre version de linux", "choose a distribution"), "distro"),
        (("redimensionnez votre disque", "resize your disk"), "resize"),
        (("partage des fichiers", "file sharing"), "sharing"),
        (("créez votre compte linux", "create your linux account"), "account"),
        (("vous allez effectuer des modifications importantes",), "warning"),
    )
    for markers, screen in screen_markers:
        if any(marker in normalized_text for marker in markers):
            verdict["detected_screen"] = screen
            break
    verdict.setdefault("expected_screen_visible", False)
    verdict.setdefault("no_blocking_error", False)
    verdict.setdefault("username_visible", False)
    verdict.setdefault("password_fields_filled", False)
    verdict.setdefault("warning_acknowledged", False)
    verdict.setdefault(
        "summary",
        f"Wizard screen detected as {verdict.get('detected_screen', 'other')}",
    )
    return verdict


def optimize_image(image_path: Path) -> str:
    try:
        with Image.open(image_path) as screenshot:
            screenshot = screenshot.convert("RGB")
            screenshot.thumbnail((1024, 768), Image.Resampling.LANCZOS)
            buffer = io.BytesIO()
            screenshot.save(buffer, format="JPEG", quality=85, optimize=True)
        return base64.b64encode(buffer.getvalue()).decode("ascii")
    except (OSError, ValueError) as exc:
        raise WorkflowError(
            "llm.image",
            "Capture reading or optimization failed",
            details={"path": str(image_path), "error": str(exc)},
        ) from exc


def load_progress_message_json(
    message: dict[str, object],
) -> tuple[dict[str, object], Literal["strict_json"]]:
    """Read the final JSON answer without exposing private model reasoning."""

    content = message.get("content")
    if not isinstance(content, str) or not content.strip():
        raise json.JSONDecodeError("No final install-progress verdict", str(message), 0)
    return load_progress_json(content), "strict_json"


def load_progress_json(content: str) -> dict[str, object]:
    """Return the last complete, valid progress object from noisy output."""

    core_keys = {
        "iso_download_finished",
        "installation_finished",
        "reboot_prompt_visible",
        "still_in_progress",
        "error_visible",
        "summary",
    }
    decoder = json.JSONDecoder()
    candidates: list[dict[str, object]] = []
    for index, character in enumerate(content):
        if character != "{":
            continue
        try:
            value, _end = decoder.raw_decode(content[index:])
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict) or not core_keys.issubset(value):
            continue

        candidate = dict(value)
        candidate.setdefault("visible_text", str(candidate.get("summary", ""))[:300])
        try:
            InstallProgressVerdict.model_validate(candidate)
        except ValidationError:
            continue
        candidates.append(candidate)

    if not candidates:
        raise json.JSONDecodeError("No complete install-progress verdict", content, 0)
    return candidates[-1]
