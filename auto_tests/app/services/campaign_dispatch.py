from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

from app.config import VMConfig
from app.storage_fixtures import StorageFixtureRequest

FORMAT_VERSION = 1

ScenarioOutcome = Literal["passed", "failed", "retryable"]
RunStatus = Literal[
    "pending",
    "running",
    "passed",
    "failed",
    "retryable",
    "interrupted",
    "stopped-after-failure",
    "no-compatible-worker-after-quarantine",
]


@dataclass(frozen=True)
class ScenarioRequirements:
    firmware: Literal["bios", "uefi"] | None = None
    requires_secondary_disk: bool = False


def _vm_compatible(vm: VMConfig, requirements: ScenarioRequirements) -> bool:
    if requirements.firmware is not None and vm.firmware != requirements.firmware:
        return False
    return not (requirements.requires_secondary_disk and not vm.secondary_disk_boot_order)


@dataclass(frozen=True)
class ScenarioSpec:
    """Scenario-owned AutomationRequest/AutomationOptions fields only.

    Never source/apply/credentials/VM selectors/migrate_windows_preferences --
    those stay campaign-owned on AutomationCampaignRequest. See the design
    spec's "Option ownership" section.
    """

    id: str
    tags: tuple[str, ...]
    requirements: ScenarioRequirements
    distribution: str = "mint"
    first_boot: Literal["windows", "linux"] = "windows"
    installation_target: Literal["windows", "secondary"] = "windows"
    snapshot_mode: Literal["default", "secondary-disk"] = "default"
    storage_fixture: StorageFixtureRequest = field(default_factory=StorageFixtureRequest)
    boot_guardian_fault: str = "none"
    simulate_stale_firmware_entries: bool = False
    force_offline_ntfs_resize: bool = False
    share_windows_files_in_linux: bool = True
    share_linux_files_in_windows: bool = True
    preference_wallpaper: Literal["custom", "windows-default"] = "custom"
    verify_uninstall: bool = False


SCENARIO_MATRIX: tuple[ScenarioSpec, ...] = (
    ScenarioSpec(
        id="mint-windows-first",
        tags=("nominal",),
        requirements=ScenarioRequirements(),
        distribution="mint",
        first_boot="windows",
        verify_uninstall=True,
    ),
    ScenarioSpec(
        id="mint-linux-first",
        tags=("nominal",),
        requirements=ScenarioRequirements(),
        distribution="mint",
        first_boot="linux",
        verify_uninstall=True,
    ),
    ScenarioSpec(
        id="zorin-windows-first",
        tags=("nominal",),
        requirements=ScenarioRequirements(),
        distribution="zorin",
        first_boot="windows",
        verify_uninstall=True,
    ),
    ScenarioSpec(
        id="zorin-linux-first",
        tags=("nominal",),
        requirements=ScenarioRequirements(),
        distribution="zorin",
        first_boot="linux",
        verify_uninstall=True,
    ),
    ScenarioSpec(
        id="mint-secondary-install",
        tags=("secondary-disk",),
        requirements=ScenarioRequirements(requires_secondary_disk=True),
        distribution="mint",
        first_boot="windows",
        snapshot_mode="secondary-disk",
        installation_target="secondary",
        verify_uninstall=True,
    ),
)


@dataclass(frozen=True)
class ScenarioRun:
    run_id: str  # f"{scenario_id}::{profile}"
    scenario_id: str
    profile: str


@dataclass
class ScenarioRunResult:
    run_id: str
    scenario_id: str
    profile: str
    vm: str
    outcome: ScenarioOutcome
    reason: str | None
    message: str
    errors: list[dict[str, object]]
    log: str
    captures: str
    claimed_at: str
    finished_at: str
