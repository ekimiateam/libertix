"""Parsing and image helpers for local vision-model responses."""

from __future__ import annotations

import base64
import io
import json
import re
from pathlib import Path
from typing import Literal

from PIL import Image
from pydantic import ValidationError

from app.clients.vision_models import InstallProgressVerdict
from app.clients.vision_models import (
    contains_active_install_progress as _contains_active_install_progress,
)
from app.clients.vision_models import (
    contains_final_reboot_prompt as _contains_final_reboot_prompt,
)
from app.clients.vision_models import (
    contains_install_blocker as _contains_install_blocker,
)
from app.clients.vision_models import (
    contains_live_install_success as _contains_live_install_success,
)
from app.errors import WorkflowError


def _load_wizard_json(content: str) -> dict[str, object]:
    """Read only a complete wizard verdict object from model output.

    The local thinking model may put its final JSON in ``reasoning`` and leave
    ``content`` empty. Scanning valid JSON objects avoids treating prose or the
    repeated prompt as visual evidence.
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
    verdict.setdefault(
        "summary",
        f"Wizard screen detected as {verdict.get('detected_screen', 'other')}",
    )
    return verdict


def _optimized_image(image_path: Path) -> str:
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
            "Lecture ou optimisation de la capture impossible",
            details={"path": str(image_path), "error": str(exc)},
        ) from exc


def _load_progress_message_json(
    message: dict[str, object],
) -> tuple[dict[str, object], Literal["strict_json", "reasoning_json"]]:
    """Extract only a complete schema-shaped final verdict.

    The local Thinking endpoint currently returns ``content=null`` and puts
    both its private reasoning and final answer in ``reasoning``. We may
    therefore locate a complete JSON object in that field, but we never
    infer state from its surrounding prose.
    """

    fields: tuple[tuple[str, Literal["strict_json", "reasoning_json"]], ...] = (
        ("content", "strict_json"),
        ("reasoning_content", "reasoning_json"),
        ("reasoning", "reasoning_json"),
    )
    searched: list[str] = []
    for field, source in fields:
        content = message.get(field)
        if not isinstance(content, str) or not content.strip():
            continue
        searched.append(field)
        try:
            return _load_progress_json(content), source
        except json.JSONDecodeError:
            continue

    field_list = ", ".join(searched) if searched else "no text field"
    raise json.JSONDecodeError(
        f"No complete install-progress verdict in {field_list}",
        str(message),
        0,
    )


def _load_progress_json(content: str) -> dict[str, object]:
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


def _load_json_object(content: str) -> object:
    """Parse a JSON object, tolerating noisy local thinking-model output."""

    try:
        return json.loads(content)
    except json.JSONDecodeError:
        start = content.find("{")
        end = content.rfind("}")
        if start == -1 or end <= start:
            raise
        return json.loads(content[start : end + 1])


def _progress_from_reasoning_text(content: str) -> dict[str, object]:
    """Derive the progress schema from thinking text when visible JSON is absent.

    Some local thinking models put the useful visual conclusion in ``reasoning`` and leave the
    visible ``content`` empty. This fallback intentionally ignores schema/tutorial phrases such
    as ``error_visible=true si...`` because those describe the contract, not the screenshot.
    """

    def evidence_excerpt() -> str:
        markers = (
            "visible text",
            "image shows",
            "scene:",
            "text:",
            "downloading",
            "télécharge",
            "copying",
            "extracting",
            "redemarrer",
            "redémarrer",
            "partitionnement",
            "espace insuffisant",
            "insufficient space",
            "additional space",
            "failed",
            "error",
            "erreur",
            "stage:",
            "%",
            "mb",
        )
        skipped = (
            "schema",
            "task:",
            "rules:",
            "conditions:",
            "respond",
            "contrat",
            "accidentally",
            "required output",
            "fields to determine",
            "key question",
        )
        lines: list[str] = []
        for raw_line in content.splitlines():
            line = raw_line.strip()
            lowered = line.lower()
            if not line or any(token in lowered for token in skipped):
                continue
            if any(marker in lowered for marker in markers):
                lines.append(line)
        return " ".join(lines)[:1200] or "No strict JSON returned by the vision model."

    evidence = evidence_excerpt()
    # Only extracted image evidence is trusted. The full reasoning often
    # repeats the prompt/schema and must never drive state transitions.
    analysis_source = evidence
    blocking_problem = _contains_install_blocker(analysis_source)
    final_reboot_prompt = _contains_final_reboot_prompt(analysis_source)
    active_install_progress = _contains_active_install_progress(analysis_source)
    evidence_text = evidence.lower()
    active_iso_copy = any(
        marker in evidence_text
        for marker in (
            "copying iso contents",
            "mounting iso and copying",
            "copie du contenu iso",
        )
    ) and not re.search(r"\b100\s*%", evidence_text)

    iso_finished = any(
        marker in evidence_text
        for marker in (
            "iso download completed",
            "téléchargement de l'iso est terminé",
            "téléchargement iso terminé",
            "mint iso ready",
            "(ok):download completed",
        )
    )

    if active_iso_copy:
        iso_finished = False

    live_install_success = _contains_live_install_success(analysis_source)
    installation_finished = final_reboot_prompt or live_install_success
    if any(
        marker in evidence_text
        for marker in (
            "not finished",
            "not complete",
            "pas terminée",
            "n'est pas terminée",
        )
    ):
        installation_finished = False

    reboot_prompt_visible = final_reboot_prompt
    if any(
        marker in evidence_text
        for marker in (
            "no reboot",
            "aucune invite",
            "no mention of a restart",
        )
    ):
        reboot_prompt_visible = False

    if final_reboot_prompt or live_install_success:
        iso_finished = True
        installation_finished = True
        reboot_prompt_visible = final_reboot_prompt
        active_install_progress = False

    if active_install_progress:
        installation_finished = False
        reboot_prompt_visible = False

    negative_error_evidence = any(
        marker in evidence_text
        for marker in (
            "aucun message d'erreur",
            "aucune erreur",
            "no error",
            "no blocking error",
            "error_visible: false",
        )
    )
    error_visible = blocking_problem or (
        not negative_error_evidence
        and any(
            marker in evidence_text
            for marker in (
                "erreur bloquante visible",
                "impossible de charger la liste",
                "impossible de télécharger",
                "failed to download",
                "error dialog",
                "message d'erreur",
            )
        )
    )
    if blocking_problem:
        error_visible = True
        iso_finished = False
        installation_finished = False
        reboot_prompt_visible = False

    still_in_progress = (
        (
            "downloading" in evidence_text
            or "télécharge" in evidence_text
            or "téléchargement" in evidence_text
            or "en cours" in evidence_text
            or active_iso_copy
            or active_install_progress
        )
        and not installation_finished
        and not final_reboot_prompt
    )

    if blocking_problem:
        summary = "Fallback LLM: blocking installer problem detected from visible evidence."
    elif final_reboot_prompt:
        summary = "Fallback LLM: final reboot screen detected from visible evidence."
    elif active_install_progress or active_iso_copy or still_in_progress:
        summary = "Fallback LLM: active installer progress detected from visible evidence."
    else:
        summary = "Fallback LLM: no strict JSON returned; final state is not confidently detected."

    return {
        "iso_download_finished": bool(iso_finished),
        "installation_finished": bool(installation_finished),
        "reboot_prompt_visible": bool(reboot_prompt_visible),
        "still_in_progress": bool(still_in_progress),
        "error_visible": bool(error_visible),
        "summary": summary,
        "visible_text": evidence,
        "analysis_source": "reasoning_fallback",
    }
