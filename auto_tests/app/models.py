from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

SourceMode = Literal["remote", "local"]


class StepResult(BaseModel):
    step: str
    status: Literal["ok", "problème"]
    message: str
    context: dict[str, Any] = Field(default_factory=dict)


class OperationResult(BaseModel):
    status: Literal["ok", "problème"]
    operation: Literal["validation", "reset", "automation"]
    message: str
    steps: list[StepResult] = Field(default_factory=list)


class ValidationRequest(BaseModel):
    """Optional validation scope.

    Empty body means: validate every configured VM.
    Accepted selectors include vm names, IPs, OS labels and common aliases.
    """

    vms: list[str] | None = Field(default=None, description="VM selectors, e.g. vm2")
    vm: str | None = Field(default=None, description="Single VM selector shortcut")
    source: SourceMode = Field(
        default="remote",
        description="Build source: remote clones origin/branch, local copies this working tree",
    )

    def selectors(self) -> list[str] | None:
        values: list[str] = []
        if self.vm:
            values.append(self.vm)
        if self.vms:
            values.extend(self.vms)
        return values or None


class AutomationRequest(ValidationRequest):
    """Libertix UI automation scope and safety options.

    By default, the automation only launches the visible Libertix interface.
    Set apply=true only when the test may really start the Linux installation.
    """

    apply: bool = Field(default=False, description="Run the full installer UI and click Apply")
    linux_username: str = Field(default="test", min_length=1)
    linux_password: str = Field(default="linux", min_length=1)
    monitor_iso: bool = Field(default=True)
