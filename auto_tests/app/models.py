from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field


class StepResult(BaseModel):
    step: str
    status: Literal["ok", "problème"]
    message: str
    context: dict[str, Any] = Field(default_factory=dict)


class OperationResult(BaseModel):
    status: Literal["ok", "problème"]
    operation: Literal["validation", "reset"]
    message: str
    steps: list[StepResult] = Field(default_factory=list)


class ValidationRequest(BaseModel):
    """Optional validation scope.

    Empty body means: validate every configured VM.
    Accepted selectors include vm names, IPs, OS labels and common aliases.
    """

    vms: list[str] | None = Field(default=None, description="VM selectors, e.g. vm2")
    vm: str | None = Field(default=None, description="Single VM selector shortcut")

    def selectors(self) -> list[str] | None:
        values: list[str] = []
        if self.vm:
            values.append(self.vm)
        if self.vms:
            values.extend(self.vms)
        return values or None
