from __future__ import annotations

import json
import re
import threading
import unicodedata
import uuid
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from app.models import OperationResult, StepResult


class StreamEventProjector:
    """Persist complete events while exposing only useful stream transitions."""

    def __init__(self, operation: str, log_dir: Path) -> None:
        timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
        self.log_path = log_dir / f"{operation}-{timestamp}-{uuid.uuid4().hex[:8]}.txt"
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.Lock()
        self._emitted: set[tuple[str, ...]] = set()

    def project_step(self, step: StepResult) -> dict[str, Any] | None:
        full_event = {"event": "step", "data": step.model_dump(mode="json")}
        self._write(full_event)

        if step.status == "error":
            return full_event
        if step.step == "automation.capture":
            return None
        if step.step == "automation.monitor_installation":
            return self._project_installation_phase(step)
        if step.step.startswith("automation.test."):
            return self._compact_step(step, keep_context=("vm", "test"))

        visible_steps = {
            "automation.reset_vm_done",
            "build_vm.compile",
            "automation.deploy",
            "automation.preparation_finished",
            "automation.reboot_requested",
            "automation.installed_boot_menu_seen",
            "automation.installation_finished",
            "automation.post_install_phase",
        }
        if step.step not in visible_steps:
            return None

        signature = (step.step, self._vm_identity(step))
        if signature in self._emitted:
            return None
        self._emitted.add(signature)
        return self._compact_step(step)

    def project_result(self, result: OperationResult) -> dict[str, Any]:
        self._write({"event": "result", "data": result.model_dump(mode="json")})
        data = result.model_dump(mode="json")
        data["steps"] = [
            step.model_dump(mode="json") for step in result.steps if step.status == "error"
        ]
        data["detailed_log"] = str(self.log_path)
        return {"event": "result", "data": data}

    @staticmethod
    def render(event: dict[str, Any], *, stream_format: str) -> str:
        if stream_format == "ndjson":
            return json.dumps(event, ensure_ascii=False) + "\n"

        data = event["data"]
        if event["event"] == "result":
            status = "OK" if data["status"] == "ok" else "ERROR"
            return f"RESULT {status} log={data['detailed_log']}\n"

        vm = str(data.get("context", {}).get("vm") or "global")
        if data["status"] == "error":
            return "ERROR " + json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n"
        if data["step"].startswith("automation.test."):
            name = str(data.get("context", {}).get("test") or data["step"])
            return f"TEST {vm} {name} OK\n"
        phase = data.get("context", {}).get("phase")
        label = str(phase or data["step"])
        return f"PHASE {vm} {label}\n"

    def _project_installation_phase(self, step: StepResult) -> dict[str, Any] | None:
        source = str(step.context.get("analysis_source", "strict_json"))
        vm = self._vm_identity(step)
        if source != "strict_json":
            signature = ("llm-response-format", vm, source)
            if signature not in self._emitted:
                self._emitted.add(signature)
                return {
                    "event": "step",
                    "data": {
                        "step": "automation.llm_response_normalized",
                        "status": "ok",
                        "message": (
                            "Non-strict LLM response normalized; details retained in the log"
                        ),
                        "context": {"vm": vm, "analysis_source": source},
                    },
                }

        phase = self._installation_phase(step)
        if phase is None:
            return None
        phase_id, message = phase
        signature = ("installation-phase", vm, phase_id)
        if signature in self._emitted:
            return None
        self._emitted.add(signature)
        return {
            "event": "step",
            "data": {
                "step": "automation.installation_phase",
                "status": "ok",
                "message": message,
                "context": {"vm": vm, "phase": phase_id},
            },
        }

    @classmethod
    def _installation_phase(cls, step: StepResult) -> tuple[str, str] | None:
        text = cls._normalized(
            "\n".join(
                (
                    str(step.context.get("visible_text", "")),
                    str(step.context.get("summary", "")),
                )
            )
        )
        phases = (
            (("decrypt", "dechiffr"), "windows-decryption", "Windows decryption"),
            (("uefi iso", "iso uefi"), "uefi-installer-download", "UEFI live download"),
            (
                ("mint iso", "iso mint", "linux iso", "iso d installation linux"),
                "linux-iso-download",
                "Linux ISO download",
            ),
            (("extract", "extraction"), "linux-extraction", "Linux system extraction"),
            (
                ("configur", "installed system"),
                "target-configuration",
                "Installed system configuration",
            ),
            (("cleaning", "nettoyage"), "filesystem-cleanup", "Filesystem cleanup"),
            (("boot menu", "windows boot manager"), "installed-boot", "Dual-boot menu detected"),
        )
        for markers, phase_id, message in phases:
            if any(marker in text for marker in markers):
                return phase_id, message
        return None

    @staticmethod
    def _normalized(value: str) -> str:
        decomposed = unicodedata.normalize("NFKD", value.casefold())
        ascii_text = "".join(char for char in decomposed if not unicodedata.combining(char))
        return re.sub(r"\s+", " ", ascii_text)

    @staticmethod
    def _vm_identity(step: StepResult) -> str:
        return str(step.context.get("vm") or step.context.get("target") or "global")

    @staticmethod
    def _compact_step(
        step: StepResult,
        *,
        keep_context: tuple[str, ...] = ("vm", "target"),
    ) -> dict[str, Any]:
        context = {key: step.context[key] for key in keep_context if key in step.context}
        return {
            "event": "step",
            "data": {
                "step": step.step,
                "status": step.status,
                "message": step.message,
                "context": context,
            },
        }

    def _write(self, event: dict[str, Any]) -> None:
        line = json.dumps(event, ensure_ascii=False) + "\n"
        with self._lock, self.log_path.open("a", encoding="utf-8") as stream:
            stream.write(line)
            stream.flush()
