from __future__ import annotations

import json
import logging
import time
from contextlib import suppress
from pathlib import Path
from typing import Literal

import httpx
from pydantic import ValidationError

from app.clients.vision_contracts import (
    INSTALL_PROGRESS_SCHEMA,
    INSTALL_PROGRESS_SYSTEM_PROMPT,
    SYSTEM_PROMPT,
    VERDICT_SCHEMA,
    WIZARD_STATE_SCHEMA,
)
from app.clients.vision_models import (
    InstallProgressVerdict,
    VisionVerdict,
    WizardStateVerdict,
)
from app.clients.vision_models import (
    contains_final_reboot_prompt as _contains_final_reboot_prompt,
)
from app.clients.vision_models import (
    contains_install_blocker as _contains_install_blocker,
)
from app.clients.vision_models import (
    contains_wizard_blocker as _contains_wizard_blocker,
)
from app.clients.vision_parsing import _load_json_object as load_json_object
from app.clients.vision_parsing import _load_progress_json as load_progress_json
from app.clients.vision_parsing import (
    _load_progress_message_json as load_progress_message_json,
)
from app.clients.vision_parsing import _load_wizard_json as load_wizard_json
from app.clients.vision_parsing import _optimized_image as optimize_image
from app.clients.vision_parsing import (
    _progress_from_reasoning_text as progress_from_reasoning_text,
)
from app.errors import WorkflowError

logger = logging.getLogger(__name__)


class VisionLLMClient:
    def __init__(
        self,
        api_key: str,
        api_url: str,
        model: str,
        timeout: float,
        *,
        reasoning_effort: Literal["minimal", "low", "medium", "high"] | None = None,
        max_attempts: int = 3,
        retry_base_seconds: float = 3,
    ) -> None:
        self.api_key = api_key
        self.url = api_url.rstrip("/") + "/chat/completions"
        self.model = model
        self.timeout = timeout
        self.reasoning_effort = reasoning_effort
        self.max_attempts = max_attempts
        self.retry_base_seconds = retry_base_seconds

    def _with_reasoning(self, payload: dict[str, object]) -> dict[str, object]:
        """Add provider-neutral reasoning controls only when explicitly configured."""

        if self.reasoning_effort is not None:
            payload["reasoning"] = {"effort": self.reasoning_effort}
        return payload

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
        payload = self._with_reasoning(
            {
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
        )
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
        payload = self._with_reasoning(
            {
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
        )
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
                if _contains_final_reboot_prompt(
                    visible_evidence
                ) and not _contains_install_blocker(visible_evidence):
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
        payload = self._with_reasoning(
            {
                "model": self.model,
                "messages": [
                    {
                        "role": "system",
                        "content": (
                            "Tu vérifies une étape critique de l'assistant Libertix. "
                            "Réponds uniquement avec l'objet JSON strict demandé. "
                            "Ne déduis rien qui n'est pas visible. Un mauvais écran met "
                            "uniquement expected_screen_visible à false. Une erreur ou un champ "
                            "invalide visible "
                            "met no_blocking_error à false. Une image illisible met uniquement "
                            "expected_screen_visible à false: elle ne prouve pas une erreur. "
                            "IMPORTANT: no_blocking_error=false exige un message d'erreur concret "
                            "recopié dans visible_text; une notification du bureau ou un simple "
                            "doute "
                            "ne constitue pas une erreur Libertix. "
                            "Si la fenêtre Libertix est ouverte mais vide, partiellement dessinée, "
                            "blanche/noire ou visiblement entre deux pages, classe "
                            "detected_screen=other, "
                            "expected_screen_visible=false et no_blocking_error=true: c'est un "
                            "rendu transitoire qui doit être recapturé, pas une erreur. Ne "
                            "qualifie jamais "
                            "cet état de crash sans message d'erreur explicite dans Libertix. "
                            "Quand deux captures sont fournies, elles sont chronologiques et "
                            "espacées d'une seconde. Utilise la seconde comme état actuel. "
                            "Si elles diffèrent, considère que Libertix change de page; "
                            "ne transforme pas "
                            "cette transition "
                            "en erreur. "
                            "Classe detected_screen parmi welcome, compatibility, distro, resize, "
                            "sharing, account, warning, apply ou other. Sur compatibility, une "
                            "erreur COMPAT_E_* ou un bouton Continuer désactivé met "
                            "no_blocking_error à false."
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
                                    f"{expected_username!r}. Pour l'écran warning, "
                                    "username_visible et "
                                    "password_fields_filled peuvent rester false car les champs "
                                    "ne sont "
                                    "plus affichés. Recopie dans visible_text tout le texte "
                                    "réellement "
                                    "lisible dans Libertix: titre, étape, boutons, champs, "
                                    "progression, avertissements et surtout le texte exact de "
                                    "toute "
                                    "erreur. Si aucun "
                                    "texte Libertix n'est lisible, laisse visible_text vide et "
                                    "traite "
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
        )
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

    _load_wizard_json = staticmethod(load_wizard_json)
    _optimized_image = staticmethod(optimize_image)
    _load_progress_message_json = staticmethod(load_progress_message_json)
    _load_progress_json = staticmethod(load_progress_json)
    _load_json_object = staticmethod(load_json_object)
    _progress_from_reasoning_text = staticmethod(progress_from_reasoning_text)

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
