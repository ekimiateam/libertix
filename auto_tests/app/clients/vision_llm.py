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
from app.clients.vision_models import contains_warning_screen as _contains_warning_screen
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
        logger.info("LLM vision analysis started", extra={"step": "llm.analyze", "target": vm_name})
        image = self._optimized_image(image_path)
        user_prompt = (
            f"Classify the visible Libertix welcome screen on {vm_name} ({vm_os}). "
            "Return only the required JSON object."
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
                    raise ValueError("The LLM produced no visible JSON content")
                verdict = VisionVerdict.model_validate(json.loads(content))
                logger.info(
                    "LLM vision analysis completed",
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
        raise WorkflowError("llm.analyze", "Maximum LLM attempt count exceeded")

    def analyze_install_progress(
        self, image_path: Path, vm_name: str, vm_os: str
    ) -> InstallProgressVerdict:
        logger.info(
            "Installation progress analysis started",
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
                                f"{verdict.summary} Verdict normalized from visible evidence: "
                                "100%, final state, and Restart button."
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
                                "Final verdict ignored because active progress is visible."
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
        raise WorkflowError("llm.install_progress", "Maximum LLM attempt count exceeded")

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
            "the account page with the exact username and both password fields filled"
            if expected_screen == "account"
            else "the final warning page shown immediately before installation"
        )
        payload = self._with_reasoning(
            {
                "model": self.model,
                "messages": [
                    {
                        "role": "system",
                        "content": (
                            "Classify the current Libertix wizard page from visible evidence only. "
                            "Return only the required JSON object. detected_screen must name the "
                            "visible page. expected_screen_visible must be true exactly when "
                            "detected_screen equals the requested page. Set "
                            "no_blocking_error=false "
                            "only when visible_text copies a concrete Libertix validation or error "
                            "message. A blank, partial, black, white, or transitioning window is "
                            "detected_screen=other, expected_screen_visible=false, and "
                            "no_blocking_error=true. If two chronological captures are supplied, "
                            "classify the second one. Valid screens: welcome, compatibility, "
                            "distro, resize, sharing, account, warning, apply, other. A visible "
                            "COMPAT_E_* error or disabled Continue button on compatibility is "
                            "blocking."
                        ),
                    },
                    {
                        "role": "user",
                        "content": [
                            {
                                "type": "text",
                                "text": (
                                    f"Current screen for {vm_name} ({vm_os}). Verify "
                                    f"{screen_instruction}. The exact expected username is "
                                    f"{expected_username!r}. On the warning page, username_visible "
                                    "and password_fields_filled may be false because those fields "
                                    "are no longer shown. Copy all decisive Libertix text into "
                                    "visible_text, especially titles, controls, validation "
                                    "messages, "
                                    "and errors. If no Libertix text is readable, use an empty "
                                    "visible_text and classify a transient state without inventing "
                                    "an error."
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
                content = message.get("content")
                if not isinstance(content, str) or not content.strip():
                    raise ValueError("The LLM produced no screen verdict")
                verdict = WizardStateVerdict.model_validate(self._load_wizard_json(content))
                visible_evidence = f"{verdict.summary}\n{verdict.visible_text}"
                if (
                    expected_screen == "warning"
                    and verdict.expected_screen_visible
                    and verdict.detected_screen != "warning"
                    and verdict.no_blocking_error
                    and _contains_warning_screen(verdict.visible_text)
                ):
                    # The localized title and confirmation control are stronger
                    # evidence than a contradictory enum emitted by the model.
                    verdict = verdict.model_copy(update={"detected_screen": "warning"})
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
                                f"{verdict.summary} Verdict normalized: the screen and critical "
                                "fields are confirmed with no visible Libertix error."
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
        raise WorkflowError("llm.wizard_state", "Maximum LLM attempt count exceeded")

    _load_wizard_json = staticmethod(load_wizard_json)
    _optimized_image = staticmethod(optimize_image)
    _load_progress_message_json = staticmethod(load_progress_message_json)
    _load_progress_json = staticmethod(load_progress_json)
    _load_json_object = staticmethod(load_json_object)

    def _wait_before_retry(
        self, response: httpx.Response | None, attempt: int, vm_name: str
    ) -> None:
        retry_after = 0.0
        if response is not None:
            with suppress(ValueError):
                retry_after = float(response.headers.get("retry-after", "0"))
        delay = max(retry_after, self.retry_base_seconds * (2 ** (attempt - 1)))
        logger.warning(
            "Retrying LLM request in %.1fs (%s/%s)",
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
            "LLM response is missing, invalid, or does not match the strict JSON schema",
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
            "LLM progress response is missing, invalid, or non-conforming",
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
            "The LLM did not confirm the critical wizard state",
            details={
                "vm": vm_name,
                "attempt": attempt,
                "http_status": response.status_code if response is not None else None,
                "response_body": response.text[-4000:] if response is not None else "",
                "exception_type": type(exc).__name__,
                "error": str(exc),
            },
        )
