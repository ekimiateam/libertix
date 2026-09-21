from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass, field
from typing import Literal

from app.config import Settings, VMConfig
from app.errors import WorkflowError
from app.models import BootGuardianFault, DistributionId
from app.services.validation import ValidationService
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
    distribution: DistributionId = "mint"
    first_boot: Literal["windows", "linux"] = "windows"
    installation_target: Literal["windows", "secondary"] = "windows"
    snapshot_mode: Literal["default", "secondary-disk"] = "default"
    storage_fixture: StorageFixtureRequest = field(default_factory=StorageFixtureRequest)
    boot_guardian_fault: BootGuardianFault = "none"
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


def _fleet_profiles(spec: ScenarioSpec, fleet: Sequence[VMConfig]) -> set[str]:
    return {
        vm.os
        for vm in fleet
        if vm.automation_enabled and _vm_compatible(vm, spec.requirements)
    }


def _resolve_specs(
    matrix: Sequence[ScenarioSpec],
    scenario_ids: list[str] | None,
    fleet: Sequence[VMConfig],
) -> list[ScenarioSpec]:
    by_id = {spec.id: spec for spec in matrix}
    if scenario_ids is None:
        candidates = list(matrix)
        explicit = False
    else:
        unknown = [sid for sid in scenario_ids if sid not in by_id]
        if unknown:
            raise WorkflowError(
                "campaign.unknown_scenario_id",
                "Unknown scenario id in scenario_ids filter",
                details={"unknown": unknown, "known": sorted(by_id)},
            )
        candidates = [by_id[sid] for sid in scenario_ids]
        explicit = True

    resolved: list[ScenarioSpec] = []
    for spec in candidates:
        if _fleet_profiles(spec, fleet):
            resolved.append(spec)
        elif explicit:
            raise WorkflowError(
                "campaign.scenario_unrunnable",
                f"No VM in the fleet can ever run scenario '{spec.id}'",
                details={"scenario_id": spec.id},
            )
    if not resolved:
        raise WorkflowError(
            "campaign.empty_scenario_matrix",
            "No scenarios resolved for this campaign",
            details={"scenario_ids": scenario_ids},
        )
    return resolved


def _resolve_worker_pool(configured: Settings, selectors: list[str] | None) -> list[VMConfig]:
    # None and [] both mean "no filter": ValidationService.select_vms([]) would
    # otherwise return every configured VM (including automation-disabled ones),
    # which is inconsistent with the None case below.
    if not selectors:
        return [vm for vm in configured.vms if vm.automation_enabled]
    selected = ValidationService(configured).select_vms(selectors)
    disabled = [vm.name for vm in selected if not vm.automation_enabled]
    if disabled:
        raise WorkflowError(
            "campaign.vm_not_automation_enabled",
            "The campaign worker pool must contain only automation-enabled VMs",
            details={"disabled": disabled},
        )
    return list(selected)


def _expand_runs(
    specs: Sequence[ScenarioSpec],
    fleet: Sequence[VMConfig],
    vm_pool: Sequence[VMConfig],
) -> list[ScenarioRun]:
    """Expand each spec into one ScenarioRun per fleet-wide compatible profile.

    `fleet` must be the same VM set `specs` was resolved against (via
    `_resolve_specs`) -- it defines required coverage; `vm_pool` only narrows
    which of those profiles currently have an eligible physical worker.
    """

    runs: list[ScenarioRun] = []
    for spec in specs:
        fleet_profiles = _fleet_profiles(spec, fleet)
        pool_profiles = _fleet_profiles(spec, vm_pool)
        missing = fleet_profiles - pool_profiles
        if missing:
            raise WorkflowError(
                "campaign.vm_filter_drops_coverage",
                f"VM filter removes every worker for a profile required by '{spec.id}'",
                details={"scenario_id": spec.id, "missing_profiles": sorted(missing)},
            )
        for profile in sorted(fleet_profiles):
            runs.append(
                ScenarioRun(run_id=f"{spec.id}::{profile}", scenario_id=spec.id, profile=profile)
            )
    if not runs:
        raise WorkflowError(
            "campaign.empty_run_matrix",
            "No scenario runs resolved for this campaign",
            details={"scenario_ids": [spec.id for spec in specs]},
        )
    return runs
