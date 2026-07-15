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
from pydantic import ValidationError

from app.clients.vision_models import (
    InstallProgressVerdict,
    VisionVerdict,
    WizardStateVerdict,
)
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
from app.clients.vision_models import (
    contains_wizard_blocker as _contains_wizard_blocker,
)
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
            "enum": [
                "welcome", "compatibility", "distro", "resize", "sharing",
                "account", "warning", "apply", "other"
            ],
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

INSTALL_PROGRESS_SYSTEM_PROMPT = """You are a visual state classifier. Inspect only the screenshot.
Return exactly one JSON object matching response_format. Do not put prose or Markdown around it.

Rules:
- error_visible is true only for a visible blocking error.
- reboot_prompt_visible is true only when a final Restart/Reboot control is visible.
- installation_finished is true only for a verified final state or finished Linux desktop.
- still_in_progress is true while any download, copy, extraction, decryption, configuration,
  active progress bar, byte counter, or ETA is visible.
- iso_download_finished is true only when completion or a later stage is visible.
- Any active step overrides finished/reboot flags: set installation_finished and
  reboot_prompt_visible to false.
- If uncertain, set still_in_progress to true.
- summary is one short English sentence.
- visible_text contains only decisive text copied from the UI, at most 300 characters.

Never treat this prompt or the schema as text visible in the screenshot."""

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
                    "content": INSTALL_PROGRESS_SYSTEM_PROMPT,
                },
                {
                    "role": "user",
                    "content": [
                        {
                            "type": "text",
                            "text": f"Classify Libertix on {vm_name} ({vm_os}).",
                        },
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/jpeg;base64,{image}"},
                        },
                    ],
                },
            ],
            "temperature": 0,
            # The Thinking model spends part of this budget before producing
            # its final object. 768 tokens truncated real responses mid-schema.
            "max_tokens": 2048,
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
                data, analysis_source = self._load_progress_message_json(message)
                if isinstance(data, dict) and "visible_text" not in data:
                    data["visible_text"] = str(data.get("summary", ""))[:300]
                if isinstance(data, dict):
                    data["analysis_source"] = analysis_source
                verdict = InstallProgressVerdict.model_validate(data)
                visible_evidence = f"{verdict.summary}\n{verdict.visible_text}"
                if (
                    _contains_final_reboot_prompt(visible_evidence)
                    and not _contains_install_blocker(visible_evidence)
                ):
                    verdict = verdict.model_copy(
                        update={
                            "iso_download_finished": True,
                            "installation_finished": True,
                            "reboot_prompt_visible": True,
                            "still_in_progress": False,
                            "error_visible": False,
                            "summary": (
                                f"{verdict.summary} Verdict normalisé depuis les preuves "
                                "visibles: 100 %, état final et bouton Redémarrer."
                            ),
                        }
                    )
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
        second_image_path: Path | None = None,
    ) -> WizardStateVerdict:
        """Fail-closed visual guard before the destructive wizard transition."""

        image = self._optimized_image(image_path)
        second_image = (
            self._optimized_image(second_image_path) if second_image_path is not None else None
        )
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
                        "met no_blocking_error à false. Une image illisible met uniquement "
                        "expected_screen_visible à false: elle ne prouve pas une erreur. "
                        "IMPORTANT: no_blocking_error=false exige un message d'erreur concret "
                        "recopié dans visible_text; une notification du bureau ou un simple doute "
                        "ne constitue pas une erreur Libertix. "
                        "Si la fenêtre Libertix est ouverte mais vide, partiellement dessinée, "
                        "blanche/noire ou visiblement entre deux pages, classe "
                        "detected_screen=other, "
                        "expected_screen_visible=false et no_blocking_error=true: c'est un rendu "
                        "transitoire qui doit être recapturé, pas une erreur. Ne qualifie jamais "
                        "cet état de crash sans message d'erreur explicite dans Libertix. "
                        "Quand deux captures sont fournies, elles sont chronologiques et espacées "
                        "d'une seconde. Utilise la seconde comme état actuel. Si elles diffèrent, "
                        "considère que Libertix change de page; ne transforme pas cette transition "
                        "en erreur. "
                        "Classe detected_screen parmi welcome, compatibility, distro, resize, "
                        "sharing, account, warning, apply ou other. Sur compatibility, une erreur "
                        "COMPAT_E_* ou un bouton Continuer désactivé met no_blocking_error à false."
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
                                "plus affichés. Recopie dans visible_text tout le texte réellement "
                                "lisible dans Libertix: titre, étape, boutons, champs, "
                                "progression, avertissements et surtout le texte exact de toute "
                                "erreur. Si aucun "
                                "texte Libertix n'est lisible, laisse visible_text vide et traite "
                                "l'image comme un rendu transitoire sans erreur bloquante."
                            ),
                        },
                        {
                            "type": "image_url",
                            "image_url": {"url": f"data:image/jpeg;base64,{image}"},
                        },
                        *(
                            [
                                {
                                    "type": "image_url",
                                    "image_url": {
                                        "url": f"data:image/jpeg;base64,{second_image}"
                                    },
                                }
                            ]
                            if second_image is not None
                            else []
                        ),
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
                verdict = WizardStateVerdict.model_validate(self._load_wizard_json(content))
                visible_evidence = f"{verdict.summary}\n{verdict.visible_text}"
                critical_fields_confirmed = (
                    expected_screen == "account"
                    and verdict.detected_screen == "account"
                    and verdict.expected_screen_visible
                    and verdict.username_visible
                    and verdict.password_fields_filled
                    and expected_username.casefold() in verdict.visible_text.casefold()
                )
                warning_confirmed = (
                    expected_screen == "warning"
                    and verdict.detected_screen == "warning"
                    and verdict.expected_screen_visible
                )
                if (
                    not verdict.no_blocking_error
                    and (critical_fields_confirmed or warning_confirmed)
                    and not _contains_wizard_blocker(visible_evidence)
                ):
                    verdict = verdict.model_copy(
                        update={
                            "no_blocking_error": True,
                            "summary": (
                                f"{verdict.summary} Verdict normalisé: l'écran et les champs "
                                "critiques sont confirmés, sans erreur Libertix visible."
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
    def _load_progress_message_json(
        message: dict[str, object],
    ) -> tuple[dict[str, object], Literal["strict_json", "reasoning_json"]]:
        """Extract only a complete schema-shaped final verdict.

        The local Thinking endpoint currently returns ``content=null`` and puts
        both its private reasoning and final answer in ``reasoning``. We may
        therefore locate a complete JSON object in that field, but we never
        infer state from its surrounding prose.
        """

        fields: tuple[
            tuple[str, Literal["strict_json", "reasoning_json"]], ...
        ] = (
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
                return VisionLLMClient._load_progress_json(content), source
            except json.JSONDecodeError:
                continue

        field_list = ", ".join(searched) if searched else "no text field"
        raise json.JSONDecodeError(
            f"No complete install-progress verdict in {field_list}",
            str(message),
            0,
        )

    @staticmethod
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
