from __future__ import annotations

import base64
import io
import json
import logging
import re
import time
from contextlib import suppress
from pathlib import Path
from typing import Literal

import httpx
from PIL import Image
from pydantic import BaseModel, Field, ValidationError

from app.errors import WorkflowError

logger = logging.getLogger(__name__)

VERDICT_SCHEMA = {
    "type": "object",
    "properties": {
        "no_visible_problem": {"type": "boolean"},
        "libertix_running": {"type": "boolean"},
        "welcome_message_ok": {"type": "boolean"},
        "summary": {"type": "string", "minLength": 1},
        "visible_problems": {"type": "array", "items": {"type": "string"}},
    },
    "required": [
        "no_visible_problem",
        "libertix_running",
        "welcome_message_ok",
        "summary",
        "visible_problems",
    ],
    "additionalProperties": False,
}

INSTALL_PROGRESS_SCHEMA = {
    "type": "object",
    "properties": {
        "iso_download_finished": {"type": "boolean"},
        "installation_finished": {"type": "boolean"},
        "reboot_prompt_visible": {"type": "boolean"},
        "still_in_progress": {"type": "boolean"},
        "error_visible": {"type": "boolean"},
        "summary": {"type": "string", "minLength": 1},
        "visible_text": {"type": "string"},
    },
    "required": [
        "iso_download_finished",
        "installation_finished",
        "reboot_prompt_visible",
        "still_in_progress",
        "error_visible",
        "summary",
        "visible_text",
    ],
    "additionalProperties": False,
}

WIZARD_STATE_SCHEMA = {
    "type": "object",
    "properties": {
        "detected_screen": {
            "type": "string",
            "enum": ["welcome", "distro", "resize", "account", "warning", "apply", "other"],
        },
        "expected_screen_visible": {"type": "boolean"},
        "no_blocking_error": {"type": "boolean"},
        "username_visible": {"type": "boolean"},
        "password_fields_filled": {"type": "boolean"},
        "summary": {"type": "string", "minLength": 1},
        "visible_text": {"type": "string"},
    },
    "required": [
        "detected_screen",
        "expected_screen_visible",
        "no_blocking_error",
        "username_visible",
        "password_fields_filled",
        "summary",
        "visible_text",
    ],
    "additionalProperties": False,
}

SYSTEM_PROMPT = """Tu es un auditeur visuel strict chargé de valider l'écran de Libertix.

CONTRAT DE SORTIE ABSOLU ET OBLIGATOIRE :
- Ta réponse visible entière doit être UN SEUL objet JSON valide.
- Elle doit respecter exactement le JSON Schema fourni par response_format.
- N'ajoute aucun texte avant ou après l'objet JSON.
- N'utilise jamais de bloc Markdown, de balises, de commentaire ou de clé supplémentaire.
- Les cinq clés obligatoires sont : no_visible_problem, libertix_running,
  welcome_message_ok, summary et visible_problems.
- Les trois premières valeurs sont obligatoirement des booléens JSON true ou false,
  jamais des chaînes.
- visible_problems est obligatoirement un tableau JSON de chaînes.
- En cas de doute, d'écran illisible ou d'information non visible, utilise false et explique
  précisément le doute dans summary et visible_problems.

Inspecte réellement l'image. Ne déduis jamais qu'une application fonctionne uniquement parce que la
question le prétend. Le raisonnement interne peut être détaillé, mais la réponse visible finale doit
rester exclusivement l'objet JSON demandé.

PÉRIMÈTRE DE VALIDATION :
- Le verdict concerne uniquement la fenêtre Libertix, son lancement et son écran de bienvenue.
- Ignore les icônes du bureau Windows, raccourcis, croix rouges sur icônes réseau, barre des tâches,
  notifications système ou fond d'écran, sauf si ces éléments couvrent Libertix ou empêchent
  clairement de lire/utiliser l'application.
- no_visible_problem doit donc être false uniquement si un problème est visible dans Libertix
  lui-même, si Libertix est masqué/illisible, ou si une erreur bloque son écran d'accueil."""


class VisionVerdict(BaseModel):
    no_visible_problem: bool
    libertix_running: bool
    welcome_message_ok: bool
    summary: str = Field(min_length=1)
    visible_problems: list[str]

    @property
    def valid(self) -> bool:
        return self.no_visible_problem and self.libertix_running and self.welcome_message_ok


class InstallProgressVerdict(BaseModel):
    iso_download_finished: bool
    installation_finished: bool
    reboot_prompt_visible: bool
    still_in_progress: bool
    error_visible: bool
    summary: str = Field(min_length=1)
    visible_text: str
    analysis_source: Literal["strict_json", "reasoning_fallback"] = "strict_json"

    @property
    def done(self) -> bool:
        return (
            self.iso_download_finished or self.installation_finished or self.reboot_prompt_visible
        )

    @property
    def blocking_problem_visible(self) -> bool:
        """Return true for known Libertix blockers even if the LLM booleans are wrong."""

        return _contains_install_blocker(f"{self.summary}\n{self.visible_text}")

    @property
    def active_install_progress_visible(self) -> bool:
        """Return true when the screen still shows active download/copy/install work."""

        return _contains_active_install_progress(f"{self.summary}\n{self.visible_text}")


class WizardStateVerdict(BaseModel):
    detected_screen: Literal["welcome", "distro", "resize", "account", "warning", "apply", "other"]
    expected_screen_visible: bool
    no_blocking_error: bool
    username_visible: bool
    password_fields_filled: bool
    summary: str = Field(min_length=1)
    visible_text: str


def _contains_install_blocker(content: str) -> bool:
    """Detect concrete blocking UI text from Libertix installation screens."""

    text = content.lower()
    return any(
        marker in text
        for marker in (
            "espace insuffisant",
            "insufficient space",
            "additional space needed",
            "size cannot exceed",
            "failed to download",
            "failed to obtain",
            "impossible de télécharger",
            "impossible de charger",
            "no iso url found",
            "failed to copy iso",
            "installation échouée",
            "installation echouee",
            "installer-failed",
        )
    )


def _contains_final_reboot_prompt(content: str) -> bool:
    """Detect the final Libertix reboot screen from concrete UI text."""

    text = content.lower()
    reboot_button = "redemarrer" in text or "redémarrer" in text
    final_state = any(
        marker in text
        for marker in (
            "partitionnement termine",
            "partitionnement terminé",
            "next reboot will automatically boot",
            "boot entry configured",
            "grub4dos installed",
        )
    )
    return reboot_button and final_state and re.search(r"\b100\s*%", text) is not None


def _contains_active_install_progress(content: str) -> bool:
    """Detect concrete in-progress text that must block final reboot clicks."""

    if _contains_final_reboot_prompt(content):
        return False

    text = content.lower()
    progress_pattern = (
        r"\b(downloading|copying|extracting|copie|téléchargement).{0,80}"
        r"\b[0-9]{1,2}\s*%"
    )
    if re.search(progress_pattern, text):
        return True
    if re.search(r"\b[0-9][0-9\s]*/[0-9][0-9\s]*\s*mb\b", text) and any(
        marker in text for marker in ("downloading", "télécharg", "linux iso", "mint.iso")
    ):
        return True
    if any(
        marker in text
        for marker in (
            "decryptioninprogress",
            "decryption in progress",
            "décryptage en cours",
            "dechiffrement de windows",
            "déchiffrement de windows",
            "waiting for c: decryption",
        )
    ):
        return True
    return any(
        marker in text
        for marker in (
            "copying iso contents",
            "mounting iso and copying",
            "extracting system",
            "stage: 120-unsquashfs",
            "stage: 130-target-system-config",
            "extraction de mint",
            "configuration du systeme installe",
            "configuration du système installé",
        )
    )


def _contains_live_install_success(content: str) -> bool:
    """Detect the final live ISO success screen without relying on LLM wording."""

    text = content.lower()
    return any(
        marker in text
        for marker in (
            "installer-success",
            "installation terminée et vérifiée",
            "installation terminee et verifiee",
            "libertix_install_success=true",
        )
    )


class VisionLLMClient:
    def __init__(
        self,
        api_key: str,
        api_url: str,
        model: str,
        timeout: float,
        *,
        max_attempts: int = 3,
        retry_base_seconds: float = 3,
    ) -> None:
        self.api_key = api_key
        self.url = api_url.rstrip("/") + "/chat/completions"
        self.model = model
        self.timeout = timeout
        self.max_attempts = max_attempts
        self.retry_base_seconds = retry_base_seconds

    def analyze(self, image_path: Path, vm_name: str, vm_os: str) -> VisionVerdict:
        logger.info("Analyse vision LLM démarrée", extra={"step": "llm.analyze", "target": vm_name})
        image = self._optimized_image(image_path)
        user_prompt = (
            f"Analyse la capture jointe de {vm_name}, système {vm_os}. Vérifie séparément : "
            "(1) qu'aucun problème, message d'erreur ou anomalie visuelle n'est visible "
            "dans la fenêtre Libertix ; "
            "(2) que l'application Libertix est réellement ouverte ; "
            "(3) que le message de bienvenue Libertix est affiché correctement. "
            "Ignore les problèmes du bureau Windows qui ne touchent pas Libertix. "
            "RAPPEL FINAL : réponds uniquement avec l'objet JSON strict imposé, "
            "sans aucun autre texte."
        )
        payload = {
            "model": self.model,
            "messages": [
                {"role": "system", "content": SYSTEM_PROMPT},
                {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": user_prompt},
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/jpeg;base64,{image}"},
                        },
                    ],
                },
            ],
            "temperature": 0,
            "max_tokens": 4096,
            "stream": False,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "libertix_visual_verdict",
                    "strict": True,
                    "schema": VERDICT_SCHEMA,
                },
            },
        }
        response: httpx.Response | None = None
        for attempt in range(1, self.max_attempts + 1):
            try:
                response = httpx.post(
                    self.url,
                    headers={"Authorization": f"Bearer {self.api_key}"},
                    json=payload,
                    timeout=self.timeout,
                )
                response.raise_for_status()
                message = response.json()["choices"][0]["message"]
                content = message["content"]
                if not isinstance(content, str) or not content.strip():
                    raise ValueError("Le LLM n'a produit aucun contenu JSON visible")
                verdict = VisionVerdict.model_validate(json.loads(content))
                logger.info(
                    "Analyse vision LLM terminée",
                    extra={"step": "llm.analyze", "target": vm_name},
                )
                return verdict
            except httpx.HTTPStatusError as exc:
                if (
                    exc.response.status_code in (429, 500, 502, 503, 504)
                    and attempt < self.max_attempts
                ):
                    self._wait_before_retry(exc.response, attempt, vm_name)
                    continue
                raise self._error(exc, vm_name, response, attempt) from exc
            except (
                httpx.HTTPError,
                json.JSONDecodeError,
                KeyError,
                IndexError,
                TypeError,
                ValueError,
                ValidationError,
            ) as exc:
                if attempt < self.max_attempts:
                    self._wait_before_retry(response, attempt, vm_name)
                    continue
                raise self._error(exc, vm_name, response, attempt) from exc
        raise WorkflowError("llm.analyze", "Nombre maximal de tentatives LLM dépassé")

    def analyze_install_progress(
        self, image_path: Path, vm_name: str, vm_os: str
    ) -> InstallProgressVerdict:
        logger.info(
            "Analyse progression installation démarrée",
            extra={"step": "llm.install_progress", "target": vm_name},
        )
        image = self._optimized_image(image_path)
        payload = {
            "model": self.model,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "Tu surveilles visuellement Libertix pendant une installation. "
                        "Réponds uniquement avec un objet JSON strict conforme au schéma. "
                        "iso_download_finished=true si l'écran montre clairement que le "
                        "téléchargement de l'ISO est terminé ou que l'étape suivante a commencé. "
                        "installation_finished=true si l'installation est terminée. "
                        "reboot_prompt_visible=true si un dialogue ou bouton de "
                        "redémarrage final est réellement visible. "
                        "Si l'écran affiche encore un téléchargement, une copie, "
                        "une extraction, une barre de progression active ou un statut "
                        "du type x/y MB, alors reboot_prompt_visible=false, "
                        "installation_finished=false et still_in_progress=true. "
                        "error_visible=true si une erreur bloquante est visible. "
                        "En cas de doute, still_in_progress=true et explique dans summary."
                    ),
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                f"Capture de {vm_name}, {vm_os}. Dis si le téléchargement ISO "
                                "Libertix est fini, si l'installation est finie, "
                                "ou si ça continue."
                            ),
                        },
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/jpeg;base64,{image}"},
                        },
                    ],
                },
            ],
            "temperature": 0,
            "max_tokens": 768,
            "stream": False,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "libertix_install_progress",
                    "strict": True,
                    "schema": INSTALL_PROGRESS_SCHEMA,
                },
            },
        }
        response: httpx.Response | None = None
        for attempt in range(1, self.max_attempts + 1):
            try:
                response = httpx.post(
                    self.url,
                    headers={"Authorization": f"Bearer {self.api_key}"},
                    json=payload,
                    timeout=self.timeout,
                )
                response.raise_for_status()
                message = response.json()["choices"][0]["message"]
                content = message.get("content") or message.get("reasoning")
                if not isinstance(content, str) or not content.strip():
                    raise ValueError("Le LLM n'a produit aucun JSON de progression")
                analysis_source: Literal["strict_json", "reasoning_fallback"] = "strict_json"
                try:
                    data = self._load_json_object(content)
                except json.JSONDecodeError:
                    data = self._progress_from_reasoning_text(content)
                    analysis_source = "reasoning_fallback"
                if isinstance(data, dict) and "visible_text" not in data:
                    data["visible_text"] = content.replace("\n", " ").strip()[:1200]
                if isinstance(data, dict):
                    data["analysis_source"] = analysis_source
                verdict = InstallProgressVerdict.model_validate(data)
                if verdict.done and verdict.active_install_progress_visible:
                    verdict = verdict.model_copy(
                        update={
                            "iso_download_finished": False,
                            "installation_finished": False,
                            "reboot_prompt_visible": False,
                            "still_in_progress": True,
                            "summary": (
                                f"{verdict.summary} "
                                "Verdict de fin ignore: une progression active est visible."
                            ),
                        }
                    )
                return verdict
            except httpx.HTTPStatusError as exc:
                if (
                    exc.response.status_code in (429, 500, 502, 503, 504)
                    and attempt < self.max_attempts
                ):
                    self._wait_before_retry(exc.response, attempt, vm_name)
                    continue
                raise self._progress_error(exc, vm_name, response, attempt) from exc
            except (
                httpx.HTTPError,
                json.JSONDecodeError,
                KeyError,
                IndexError,
                TypeError,
                ValueError,
                ValidationError,
            ) as exc:
                if attempt < self.max_attempts:
                    self._wait_before_retry(response, attempt, vm_name)
                    continue
                raise self._progress_error(exc, vm_name, response, attempt) from exc
        raise WorkflowError("llm.install_progress", "Nombre maximal de tentatives LLM dépassé")

    def analyze_wizard_state(
        self,
        image_path: Path,
        vm_name: str,
        vm_os: str,
        *,
        expected_screen: Literal["account", "warning"],
        expected_username: str,
    ) -> WizardStateVerdict:
        """Fail-closed visual guard before the destructive wizard transition."""

        image = self._optimized_image(image_path)
        screen_instruction = (
            "l'écran de création du compte, avec le nom utilisateur exact visible et les deux "
            "champs de mot de passe visiblement remplis"
            if expected_screen == "account"
            else "l'écran final d'avertissement avant application, sans erreur de validation"
        )
        payload = {
            "model": self.model,
            "messages": [
                {
                    "role": "system",
                    "content": (
                        "Tu vérifies une étape critique de l'assistant Libertix. "
                        "Réponds uniquement avec l'objet JSON strict demandé. "
                        "Ne déduis rien qui n'est pas visible. Un mauvais écran met uniquement "
                        "expected_screen_visible à false. Une erreur ou un champ invalide visible "
                        "met no_blocking_error à false. Une image illisible met les deux à false. "
                        "Classe detected_screen parmi welcome, distro, resize, account, warning, "
                        "apply ou other."
                    ),
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": (
                                f"Capture de {vm_name}, {vm_os}. Vérifie que l'image montre "
                                f"{screen_instruction}. Le nom attendu est exactement "
                                f"{expected_username!r}. Pour l'écran warning, username_visible et "
                                "password_fields_filled peuvent rester false car les champs "
                                "ne sont "
                                "plus affichés. Recopie seulement le texte réellement lisible dans "
                                "visible_text."
                            ),
                        },
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/jpeg;base64,{image}"},
                        },
                    ],
                },
            ],
            "temperature": 0,
            "max_tokens": 2048,
            "stream": False,
            "response_format": {
                "type": "json_schema",
                "json_schema": {
                    "name": "libertix_wizard_state",
                    "strict": True,
                    "schema": WIZARD_STATE_SCHEMA,
                },
            },
        }
        response: httpx.Response | None = None
        for attempt in range(1, self.max_attempts + 1):
            try:
                response = httpx.post(
                    self.url,
                    headers={"Authorization": f"Bearer {self.api_key}"},
                    json=payload,
                    timeout=self.timeout,
                )
                response.raise_for_status()
                message = response.json()["choices"][0]["message"]
                content = message.get("content") or message.get("reasoning")
                if not isinstance(content, str) or not content.strip():
                    raise ValueError("Le LLM n'a produit aucun verdict d'écran")
                return WizardStateVerdict.model_validate(self._load_wizard_json(content))
            except httpx.HTTPStatusError as exc:
                if (
                    exc.response.status_code in (429, 500, 502, 503, 504)
                    and attempt < self.max_attempts
                ):
                    self._wait_before_retry(exc.response, attempt, vm_name)
                    continue
                raise self._wizard_error(exc, vm_name, response, attempt) from exc
            except (
                httpx.HTTPError,
                json.JSONDecodeError,
                KeyError,
                IndexError,
                TypeError,
                ValueError,
                ValidationError,
            ) as exc:
                if attempt < self.max_attempts:
                    self._wait_before_retry(response, attempt, vm_name)
                    continue
                raise self._wizard_error(exc, vm_name, response, attempt) from exc
        raise WorkflowError("llm.wizard_state", "Nombre maximal de tentatives LLM dépassé")

    @staticmethod
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
        verdict.setdefault("expected_screen_visible", False)
        verdict.setdefault("no_blocking_error", False)
        verdict.setdefault("username_visible", False)
        verdict.setdefault("password_fields_filled", False)
        verdict.setdefault(
            "summary",
            f"Wizard screen detected as {verdict.get('detected_screen', 'other')}",
        )
        return verdict

    @staticmethod
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

    @staticmethod
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

    @staticmethod
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

        error_visible = blocking_problem or any(
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
            summary = (
                "Fallback LLM: no strict JSON returned; final state is not confidently detected."
            )

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

    def _wait_before_retry(
        self, response: httpx.Response | None, attempt: int, vm_name: str
    ) -> None:
        retry_after = 0.0
        if response is not None:
            with suppress(ValueError):
                retry_after = float(response.headers.get("retry-after", "0"))
        delay = max(retry_after, self.retry_base_seconds * (2 ** (attempt - 1)))
        logger.warning(
            "Nouvelle tentative LLM dans %.1fs (%s/%s)",
            delay,
            attempt,
            self.max_attempts,
            extra={"step": "llm.retry", "target": vm_name},
        )
        time.sleep(delay)

    @staticmethod
    def _error(
        exc: Exception, vm_name: str, response: httpx.Response | None, attempt: int
    ) -> WorkflowError:
        return WorkflowError(
            "llm.analyze",
            "Réponse LLM absente, invalide ou non conforme au schéma JSON strict",
            details={
                "vm": vm_name,
                "attempt": attempt,
                "http_status": response.status_code if response is not None else None,
                "response_body": response.text[-4000:] if response is not None else "",
                "exception_type": type(exc).__name__,
                "error": str(exc),
            },
        )

    @staticmethod
    def _progress_error(
        exc: Exception, vm_name: str, response: httpx.Response | None, attempt: int
    ) -> WorkflowError:
        return WorkflowError(
            "llm.install_progress",
            "Réponse LLM de progression absente, invalide ou non conforme",
            details={
                "vm": vm_name,
                "attempt": attempt,
                "http_status": response.status_code if response is not None else None,
                "response_body": response.text[-4000:] if response is not None else "",
                "exception_type": type(exc).__name__,
                "error": str(exc),
            },
        )

    @staticmethod
    def _wizard_error(
        exc: Exception, vm_name: str, response: httpx.Response | None, attempt: int
    ) -> WorkflowError:
        return WorkflowError(
            "llm.wizard_state",
            "État critique de l'assistant non confirmé par le LLM",
            details={
                "vm": vm_name,
                "attempt": attempt,
                "http_status": response.status_code if response is not None else None,
                "response_body": response.text[-4000:] if response is not None else "",
                "exception_type": type(exc).__name__,
                "error": str(exc),
            },
        )
