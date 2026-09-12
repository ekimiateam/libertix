from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from app.storage_fixtures import StorageFixtureRequest

_INSTALLATION_POLICY = json.loads(
    (
        Path(__file__).resolve().parents[2]
        / "Scripts"
        / "config"
        / "Libertix.InstallationPolicy.json"
    ).read_text(encoding="utf-8")
)
_MINIMUM_LINUX_SIZE_GIB = int(_INSTALLATION_POLICY["storage"]["minimumFinalSizeGiB"])
PARTITION_ALIGNMENT_BYTES = int(_INSTALLATION_POLICY["storage"]["partitionAlignmentBytes"])
_RESERVED_LINUX_USERNAMES = frozenset(
    str(value).casefold() for value in _INSTALLATION_POLICY["account"]["reservedUsernames"]
)
STAGING_VOLUME_LABELS = (
    str(_INSTALLATION_POLICY["volumeLabels"]["staging"]),
    *(str(value) for value in _INSTALLATION_POLICY["volumeLabels"]["legacyStagingForRecovery"]),
)

SourceMode = Literal["remote", "local", "published"]
DistributionId = Literal["mint", "zorin"]
FirstBoot = Literal["windows", "linux"]
BootGuardianFault = Literal[
    "none",
    "bios-rollback",
    "bios-controller-disconnect",
    "bios-postinstall-rollback",
    "uefi-postinstall-rollback",
    "boot-order",
    "bootnext-fallback",
    "bootnext-rollback",
    "preferred-path",
    "preferred-path-rollback",
]


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
    campaign_summary: list[dict[str, Any]] = Field(default_factory=list)


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


class AutomationCampaignRequest(ValidationRequest):
    """Four nominal installation scenarios, with one shared three-VM scope."""

    model_config = ConfigDict(extra="forbid")
    apply: Literal[True]
    linux_username: str = "test"
    linux_password: str = Field(min_length=4, max_length=128)
    linux_size_gib: int = Field(default=20, ge=_MINIMUM_LINUX_SIZE_GIB, le=16384)
    migrate_windows_preferences: bool = False
    continue_after_failure: bool = False

    @model_validator(mode="after")
    def validate_installation_options(self) -> AutomationCampaignRequest:
        AutomationRequest(
            apply=True,
            linux_username=self.linux_username,
            linux_password=self.linux_password,
            linux_size_gib=self.linux_size_gib,
        )
        return self


class AutomationRequest(ValidationRequest):
    """Destructive unattended Libertix installation request.

    The explicit true literal prevents callers from confusing this endpoint
    with the non-destructive validation endpoint.
    """

    apply: Literal[True] = Field(description="Explicitly authorize the complete installation")
    snapshot_mode: Literal["default", "secondary-disk"] = Field(
        default="default",
        description=(
            "Restore RESET_SNAPSHOT by default, or SECONDARY_DISK_RESET_SNAPSHOT "
            "for the explicitly requested secondary-disk test baseline"
        ),
    )
    storage_fixture: StorageFixtureRequest = Field(default_factory=StorageFixtureRequest)
    installation_target: Literal["windows", "secondary"] = "windows"

    @model_validator(mode="after")
    def validate_storage_fixture_snapshot(self) -> AutomationRequest:
        if self.storage_fixture.secondary_data and self.snapshot_mode != "secondary-disk":
            raise ValueError("secondary_data requires snapshot_mode=secondary-disk")
        if self.storage_fixture.decrypt_secondary_volume and self.snapshot_mode != "secondary-disk":
            raise ValueError("decrypt_secondary_volume requires snapshot_mode=secondary-disk")
        if self.installation_target == "secondary" and self.snapshot_mode != "secondary-disk":
            raise ValueError("secondary installation requires snapshot_mode=secondary-disk")
        return self

    distribution: DistributionId = Field(
        default="mint", description="Distribution catalog id selected in the Libertix wizard"
    )
    linux_username: str = Field(
        default="test",
        min_length=1,
        max_length=32,
        pattern=r"^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$",
    )
    linux_password: str = Field(min_length=4, max_length=128)
    linux_size_gib: int = Field(
        default=100,
        ge=_MINIMUM_LINUX_SIZE_GIB,
        le=16384,
        description="Requested final Linux partition size in GiB",
    )
    first_boot: FirstBoot = Field(
        default="windows",
        description=(
            "Installed operating system verified first; both Windows and Linux are always tested"
        ),
    )
    monitor_iso: bool = Field(default=True)
    share_windows_files_in_linux: bool = Field(default=True)
    share_linux_files_in_windows: bool = Field(default=True)
    migrate_windows_preferences: bool = Field(default=False)
    preference_wallpaper: Literal["custom", "windows-default"] = "custom"
    simulate_stale_firmware_entries: bool = Field(
        default=False,
        description=(
            "Inject one stale UEFI Libertix entry before launch for ownership regression tests"
        ),
    )
    force_offline_ntfs_resize: bool = Field(
        default=False,
        description=(
            "Force the development-only live offline NTFS resize path for regression testing"
        ),
    )
    boot_guardian_fault: BootGuardianFault = Field(
        default="none",
        description=("Development-only recovery scenario used to prove rollback or boot repair"),
    )
    verify_uninstall: bool = Field(
        default=False,
        description=(
            "Relaunch Libertix after successful post-install verification and prove the "
            "interactive installed-Linux uninstall path"
        ),
    )

    @field_validator("linux_username")
    @classmethod
    def reject_reserved_linux_username(cls, value: str) -> str:
        if value.casefold() in _RESERVED_LINUX_USERNAMES:
            raise ValueError("Linux username is reserved by Debian/Ubuntu")
        return value
