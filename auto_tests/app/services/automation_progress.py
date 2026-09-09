"""Progress clocks ignore camera activity, repeated polling and observer wording."""

from __future__ import annotations

import re
import unicodedata

from app.errors import WorkflowError
from app.models import StepResult


def assert_installation_progress(
    now: float,
    last_progress: float,
    timeout: float,
    *,
    vm: str,
    target: str,
    phase: str,
    capture: str,
) -> None:
    if now - last_progress >= timeout:
        raise WorkflowError(
            "automation.progress_stalled",
            f"No installation progress on {vm} during {phase}",
            details={
                "vm": vm,
                "target": target,
                "phase": phase,
                "capture": capture,
                "stalled_seconds": round(now - last_progress, 3),
                "stall_timeout_seconds": timeout,
            },
        )


class InstallationProgress:
    def __init__(self) -> None:
        self.generation = 0
        self.phase = "unclassified"
        self._seen: set[str] = set()
        self._amounts: dict[str, tuple[float, float]] = {}

    def observe(self, visible_text: str) -> bool:
        text = "".join(
            char
            for char in unicodedata.normalize("NFKD", visible_text.casefold())
            if not unicodedata.combining(char)
        )
        stages = re.findall(r"\b\d{3}-[a-z][a-z0-9-]*", text)
        if stages:
            phase = stages[-1]
        else:
            phase = "unclassified"
            for line in reversed(text.splitlines()):
                for expression, label in (
                    (r"decrypt|dechiffr|descifr", "decryption"),
                    (r"download|telecharg|descarg", "download"),
                    (r"extract|unsquash", "extraction"),
                    (r"configur", "configuration"),
                    (r"copy|copie|copiando", "copy"),
                    (r"rollback|restaur", "rollback"),
                ):
                    if re.search(expression, line):
                        phase = label
                        break
                if phase != "unclassified":
                    break
        filenames = re.findall(r"\b[a-z0-9][a-z0-9._-]*\.iso\b", text)
        if phase in {"download", "copy"} and filenames:
            phase += ":" + filenames[-1]
        self.phase = phase
        changed = phase not in self._seen
        self._seen.add(phase)
        percentages = [
            float(value.replace(",", "."))
            for value in re.findall(r"(?<![\d.])(\d{1,3}(?:[.,]\d+)?)\s*%", text)
        ]
        percentages = [value for value in percentages if 0 <= value <= 100]
        if percentages:
            low, high = min(percentages), max(percentages)
            previous_low, previous_high = self._amounts.get(phase, (101, -1))
            if low < previous_low or high > previous_high:
                self._amounts[phase] = (min(low, previous_low), max(high, previous_high))
                changed = True
        if changed:
            self.generation += 1
        return changed


class OperationProgress:
    def __init__(self, now: float) -> None:
        self.global_at = now
        self.active: dict[str, float] = {}
        self._seen: set[tuple[object, ...]] = set()

    def observe(self, step: StepResult, now: float) -> bool:
        vm = str(step.context.get("vm") or "global")
        if step.step == "automation.vm_started":
            self.active.setdefault(vm, now)
        if step.step == "automation.vm_finished":
            self.active.pop(vm, None)
            self.global_at = now
            return True
        if step.step in {
            "automation.capture",
            "automation.monitor_unchanged",
            "automation.display_temporarily_unavailable",
            "automation.display_transition",
            "automation.rollback_in_progress",
        }:
            return False
        if step.step in {
            "automation.monitor_installation",
            "automation.windows_preparation_progress",
        }:
            token = step.context.get("progress_generation")
            if not isinstance(token, int) or isinstance(token, bool):
                return False
        else:
            token = tuple(
                str(step.context.get(key, "")) for key in ("test", "stage", "phase", "sequence")
            )
        signature = (str(step.context.get("scenario", "")), vm, step.step, token)
        if signature in self._seen:
            return False
        self._seen.add(signature)
        if vm in self.active:
            self.active[vm] = now
        elif not self.active:
            self.global_at = now
        return True

    def oldest(self) -> tuple[str, float]:
        return (
            min(self.active.items(), key=lambda item: item[1])
            if self.active
            else ("global", self.global_at)
        )
