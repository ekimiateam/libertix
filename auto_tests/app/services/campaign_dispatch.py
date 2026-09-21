from __future__ import annotations

import json
import os
from collections.abc import Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Literal

from app.config import Settings, VMConfig
from app.errors import WorkflowError
from app.models import AutomationCampaignRequest, BootGuardianFault, DistributionId, OperationResult
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


_RECOGNIZED_INFRA_STEPS = frozenset(
    {
        "automation.rollback_preflight",
        "automation.reset_vm_done",
        "automation.guest_network_ready",
        "automation.guest_network_discovery",
        "automation.guest_network_configure",
        "automation.guest_network_verify",
        "automation.vm_status",
    }
)

RetryReason = Literal["restore_failed", "preflight_failed"]


def _is_infra_step(step: str) -> bool:
    return step in _RECOGNIZED_INFRA_STEPS or step.startswith("automation.rollback_")


def _classify(outcome: OperationResult, vm_name: str) -> tuple[ScenarioOutcome, RetryReason | None]:
    error_steps = [step.step for step in outcome.steps if step.status == "error"]
    if outcome.status == "error":
        # Conservative by design: only retryable if EVERY error step is
        # recognized infra noise. A single real failure step among them
        # (even alongside infra errors) must still fail the run -- never let
        # a genuine Libertix/install/validation bug get silently retried.
        if error_steps and all(_is_infra_step(step) for step in error_steps):
            reason: RetryReason = (
                "restore_failed"
                if any(
                    step.startswith("automation.rollback_") or step == "automation.reset_vm_done"
                    for step in error_steps
                )
                else "preflight_failed"
            )
            return "retryable", reason
        return "failed", None
    verdicts = {
        str(step.context.get("vm")): step.context.get("vm_status")
        for step in outcome.steps
        if step.step == "automation.vm_finished" and "vm" in step.context
    }
    if verdicts.get(vm_name) != "ok":
        return "failed", None
    return "passed", None


_COUNT_KEYS = (
    "pending", "running", "passed", "failed", "retryable",
    "interrupted", "stopped_after_failure", "no_compatible_worker_after_quarantine",
)


def _now_iso() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def _pending_run_entry(run: ScenarioRun) -> dict[str, object]:
    return {
        "run_id": run.run_id,
        "scenario_id": run.scenario_id,
        "profile": run.profile,
        "vm": None,
        "status": "pending",
        "reason": None,
        "message": None,
        "errors": [],
        "log": None,
        "captures": None,
        "claimed_at": None,
        "finished_at": None,
    }


def _build_summary(
    request: AutomationCampaignRequest,
    specs: Sequence[ScenarioSpec],
    vm_pool: Sequence[VMConfig],
    runs: Sequence[ScenarioRun],
) -> dict[str, object]:
    return {
        "format_version": FORMAT_VERSION,
        # AutomationCampaignRequest.scenario_ids doesn't exist yet (added in a
        # later task); getattr keeps this file buildable until then and is a
        # no-op once the field lands.
        "requested": {"scenario_ids": getattr(request, "scenario_ids", None), "vms": request.selectors()},
        "resolved": {
            "scenario_ids": [spec.id for spec in specs],
            "vm_pool": [vm.name for vm in vm_pool],
        },
        "runs": {run.run_id: _pending_run_entry(run) for run in runs},
        "started_at": _now_iso(),
        "finished_at": None,
    }


def _counts(runs: dict[str, dict[str, object]]) -> dict[str, int]:
    counts = dict.fromkeys(_COUNT_KEYS, 0)
    for entry in runs.values():
        key = str(entry["status"]).replace("-", "_")
        counts[key] = counts.get(key, 0) + 1
    return counts


def _persist_summary(workspace: Path, summary: dict[str, object]) -> None:
    runs: dict[str, dict[str, object]] = summary["runs"]  # type: ignore[assignment]
    payload = {**summary, "runs": list(runs.values()), "counts": _counts(runs)}
    temporary = workspace / "campaign-summary.json.tmp"
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(payload, output, ensure_ascii=False)
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(workspace / "campaign-summary.json")


def _mark_running(summary: dict[str, object], run_id: str, vm_name: str, when: str) -> None:
    entry = summary["runs"][run_id]  # type: ignore[index]
    entry["status"] = "running"
    entry["vm"] = vm_name
    entry["claimed_at"] = when


def _mark_completed(summary: dict[str, object], result: ScenarioRunResult) -> None:
    entry = summary["runs"][result.run_id]  # type: ignore[index]
    entry.update(
        status=result.outcome,
        reason=result.reason,
        message=result.message,
        errors=result.errors,
        log=result.log,
        captures=result.captures,
        finished_at=result.finished_at,
    )


def read_interrupted_campaign_summary(workspace: Path) -> list[dict[str, object]]:
    path = workspace / "campaign-summary.json"
    try:
        if path.stat().st_size > 1024 * 1024:
            return []
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return []
    if not isinstance(raw, dict) or raw.get("format_version") != FORMAT_VERSION:
        return []
    runs = raw.get("runs")
    resolved = raw.get("resolved")
    requested = raw.get("requested")
    if not isinstance(runs, list) or not isinstance(resolved, dict) or not isinstance(requested, dict):
        return []
    required_keys = {"run_id", "scenario_id", "profile", "vm", "status"}
    for entry in runs:
        if not isinstance(entry, dict) or not required_keys.issubset(entry):
            return []
    for entry in runs:
        if entry["status"] == "running":
            entry["status"] = "interrupted"
    return runs
