from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

SourceMode = Literal["remote", "local", "published"]
DistributionId = Literal["mint", "zorin"]


class StepResult(BaseModel):
    step: str
    status: Literal["ok", "error"]
    message: str
    context: dict[str, Any] = Field(default_factory=dict)


class OperationResult(BaseModel):
    status: Literal["ok", "error"]
    operation: Literal["validation", "reset", "automation"]
    message: str
    steps: list[StepResult] = Field(default_factory=list)


class ValidationRequest(BaseModel):
    """Optional validation scope.

    Empty body means: validate every VM enabled for the default scope.
    Accepted selectors include vm names, IPs, OS labels and common aliases.
    """

    vms: list[str] | None = Field(default=None, description="VM selectors, e.g. vm2")
    vm: str | None = Field(default=None, description="Single VM selector shortcut")
    source: SourceMode = Field(
        default="local",
        description=(
            "Build source: remote clones and builds the configured branch, local builds this "
            "working tree, published downloads the latest signed dev release"
        ),
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
    distribution: DistributionId = Field(
        default="mint", description="Distribution catalog id selected in the Libertix wizard"
    )
    linux_username: str = Field(
        default="test",
        min_length=1,
        max_length=32,
        pattern=r"^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$",
    )
    linux_password: str = Field(min_length=8, max_length=128)
    monitor_iso: bool = Field(default=True)
    share_windows_files_in_linux: bool = Field(default=True)
    share_linux_files_in_windows: bool = Field(default=True)
    simulate_fog_clone_boot_entries: bool = Field(
        default=False,
        description="Inject one stale UEFI Libertix entry before launch for clone regression tests",
    )
