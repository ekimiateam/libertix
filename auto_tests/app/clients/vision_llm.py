from __future__ import annotations

import base64
import io
import json
import logging
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
        "linuxgate_running": {"type": "boolean"},
        "welcome_message_ok": {"type": "boolean"},
        "summary": {"type": "string", "minLength": 1},
        "visible_problems": {"type": "array", "items": {"type": "string"}},
    },
    "required": [
        "no_visible_problem",
        "linuxgate_running",
        "welcome_message_ok",
        "summary",
        "visible_problems",
    ],
    "additionalProperties": False,
}

SYSTEM_PROMPT = """Tu es un auditeur visuel strict chargé de valider l'écran de LinuxGate.

CONTRAT DE SORTIE ABSOLU ET OBLIGATOIRE :
- Ta réponse visible entière doit être UN SEUL objet JSON valide.
- Elle doit respecter exactement le JSON Schema fourni par response_format.
- N'ajoute aucun texte avant ou après l'objet JSON.
- N'utilise jamais de bloc Markdown, de balises, de commentaire ou de clé supplémentaire.
- Les cinq clés obligatoires sont : no_visible_problem, linuxgate_running,
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
- Le verdict concerne uniquement la fenêtre LinuxGate, son lancement et son écran de bienvenue.
- Ignore les icônes du bureau Windows, raccourcis, croix rouges sur icônes réseau, barre des tâches,
  notifications système ou fond d'écran, sauf si ces éléments couvrent LinuxGate ou empêchent
  clairement de lire/utiliser l'application.
- no_visible_problem doit donc être false uniquement si un problème est visible dans LinuxGate
  lui-même, si LinuxGate est masqué/illisible, ou si une erreur bloque son écran d'accueil."""


class VisionVerdict(BaseModel):
    no_visible_problem: bool
    linuxgate_running: bool
    welcome_message_ok: bool
    summary: str = Field(min_length=1)
    visible_problems: list[str]

    @property
    def valid(self) -> bool:
        return self.no_visible_problem and self.linuxgate_running and self.welcome_message_ok


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
            "dans la fenêtre LinuxGate ; "
            "(2) que l'application LinuxGate est réellement ouverte ; "
            "(3) que le message de bienvenue LinuxGate est affiché correctement. "
            "Ignore les problèmes du bureau Windows qui ne touchent pas LinuxGate. "
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
                    "name": "linuxgate_visual_verdict",
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
