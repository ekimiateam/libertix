from __future__ import annotations

import base64
import io
import json
import logging
import re
import time
from contextlib import suppress
from pathlib import Path

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

    @property
    def done(self) -> bool:
        return (
            self.iso_download_finished or self.installation_finished or self.reboot_prompt_visible
        )

    @property
    def blocking_problem_visible(self) -> bool:
        """Return true for known Libertix blockers even if the LLM booleans are wrong."""

        return _contains_install_blocker(f"{self.summary}\n{self.visible_text}")


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
                        "redémarrage final est visible. "
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
                try:
                    data = self._load_json_object(content)
                except json.JSONDecodeError:
                    data = self._progress_from_reasoning_text(content)
                return InstallProgressVerdict.model_validate(data)
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

        text = content.lower()

        def conclusion_true(name: str) -> bool:
            """Accept only answer-like assignments, not prompt explanations like "true si/if"."""

            pattern = rf'(?<![a-z0-9_])["`]?{re.escape(name)}["`]?\s*[:=]\s*true\b'
            for match in re.finditer(pattern, text):
                tail = text[match.end() : match.end() + 40]
                if tail.lstrip().startswith(("si ", "if ", "when ", "lorsque ")):
                    continue
                return True
            return False

        def explicit_false(name: str) -> bool:
            pattern = rf'(?<![a-z0-9_])["`]?{re.escape(name)}["`]?\s*[:=]\s*false\b'
            return re.search(pattern, text) is not None

        blocking_problem = _contains_install_blocker(content)

        iso_finished = (
            conclusion_true("iso_download_finished")
            or "iso download completed" in text
            or "téléchargement de l'iso est terminé" in text
            or "téléchargement iso terminé" in text
            or "étape suivante a commencé" in text
            or "next step has begun" in text
        ) and not explicit_false("iso_download_finished")

        installation_finished = conclusion_true("installation_finished")
        if any(
            marker in text
            for marker in (
                "not finished",
                "not complete",
                "pas terminée",
                "n'est pas terminée",
                "installation_finished`: false",
            )
        ):
            installation_finished = False

        reboot_prompt_visible = conclusion_true("reboot_prompt_visible")
        if any(
            marker in text
            for marker in (
                "no reboot",
                "aucune invite",
                "no mention of a restart",
                "reboot_prompt_visible`: false",
            )
        ):
            reboot_prompt_visible = False

        error_visible = blocking_problem or any(
            marker in text
            for marker in (
                "erreur bloquante visible",
                "impossible de charger la liste",
                "impossible de télécharger",
                "failed to download",
                "error dialog",
                "message d'erreur",
            )
        )
        if any(
            marker in text
            for marker in (
                "no errors",
                "aucune erreur",
                "aucun message d'erreur",
                "pas d'erreur",
                "error_visible`: false",
                '"error_visible": false',
            )
        ):
            error_visible = False

        if blocking_problem:
            error_visible = True
            iso_finished = False
            installation_finished = False

        still_in_progress = (
            conclusion_true("still_in_progress")
            or "downloading" in text
            or "téléchargement" in text
            or "progress" in text
            or "en cours" in text
        ) and not installation_finished

        compact = content.replace("\n", " ").strip()
        return {
            "iso_download_finished": bool(iso_finished),
            "installation_finished": bool(installation_finished),
            "reboot_prompt_visible": bool(reboot_prompt_visible),
            "still_in_progress": bool(still_in_progress),
            "error_visible": bool(error_visible),
            "summary": "Fallback depuis le raisonnement LLM: " + compact[:900],
            "visible_text": compact[:1200],
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
