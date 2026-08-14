from __future__ import annotations

import json
import logging
import time
from collections.abc import Callable
from contextlib import suppress
from pathlib import Path
from typing import Literal, TypeVar

import httpx
from pydantic import ValidationError

from app.clients.vision_contracts import (
    INSTALL_PROGRESS_SCHEMA,
    INSTALL_PROGRESS_SYSTEM_PROMPT,
)
from app.clients.vision_models import InstallProgressVerdict
from app.clients.vision_models import (
    contains_final_reboot_prompt as _contains_final_reboot_prompt,
)
from app.clients.vision_models import (
    contains_install_blocker as _contains_install_blocker,
)
from app.clients.vision_parsing import (
    load_progress_message_json,
    optimize_image,
)
from app.errors import WorkflowError

logger = logging.getLogger(__name__)
VerdictT = TypeVar("VerdictT")


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

    def _request_verdict(
        self,
        payload: dict[str, object],
        vm_name: str,
        step: str,
        failure_message: str,
        decode: Callable[[dict[str, object]], VerdictT],
    ) -> VerdictT:
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
                if not isinstance(message, dict):
                    raise TypeError("The LLM response message is not an object")
                return decode(message)
            except httpx.HTTPStatusError as exc:
                retryable = exc.response.status_code in (429, 500, 502, 503, 504)
                if retryable and attempt < self.max_attempts:
                    self._wait_before_retry(exc.response, attempt, vm_name)
                    continue
                raise self._request_error(
                    step, failure_message, exc, vm_name, response, attempt
                ) from exc
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
                raise self._request_error(
                    step, failure_message, exc, vm_name, response, attempt
                ) from exc
        raise WorkflowError(step, "Maximum LLM attempt count exceeded")

    def analyze_install_progress(
        self, image_path: Path, vm_name: str, vm_os: str
    ) -> InstallProgressVerdict:
        logger.info(
            "Installation progress analysis started",
            extra={"step": "llm.install_progress", "target": vm_name},
        )
        image = optimize_image(image_path)
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

        def decode(message: dict[str, object]) -> InstallProgressVerdict:
            data, analysis_source = load_progress_message_json(message)
            data.setdefault("visible_text", str(data.get("summary", ""))[:300])
            data["analysis_source"] = analysis_source
            verdict = InstallProgressVerdict.model_validate(data)
            visible_evidence = f"{verdict.summary}\n{verdict.visible_text}"
            if _contains_final_reboot_prompt(visible_evidence) and not _contains_install_blocker(
                visible_evidence
            ):
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

        return self._request_verdict(
            payload,
            vm_name,
            "llm.install_progress",
            "LLM progress response is missing, invalid, or non-conforming",
            decode,
        )

    def _wait_before_retry(
        self, response: httpx.Response | None, attempt: int, vm_name: str
    ) -> None:
        retry_after = 0.0
        if response is not None:
            with suppress(ValueError):
                retry_after = float(response.headers.get("retry-after", "0"))
        delay = min(
            60.0,
            max(retry_after, self.retry_base_seconds * (2 ** (attempt - 1))),
        )
        logger.warning(
            "Retrying LLM request in %.1fs (%s/%s)",
            delay,
            attempt,
            self.max_attempts,
            extra={"step": "llm.retry", "target": vm_name},
        )
        time.sleep(delay)

    @staticmethod
    def _request_error(
        step: str,
        message: str,
        exc: Exception,
        vm_name: str,
        response: httpx.Response | None,
        attempt: int,
    ) -> WorkflowError:
        return WorkflowError(
            step,
            message,
            details={
                "vm": vm_name,
                "attempt": attempt,
                "http_status": response.status_code if response is not None else None,
                "response_body": response.text[-4000:] if response is not None else "",
                "exception_type": type(exc).__name__,
                "error": str(exc),
            },
        )
