from __future__ import annotations

import json
import logging
import os
import queue as queue_module
import threading
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path, PureWindowsPath
from typing import Literal

from app.config import Settings, VMConfig
from app.errors import WorkflowError
from app.models import (
    AutomationCampaignRequest,
    AutomationRequest,
    BootGuardianFault,
    DistributionId,
    OperationResult,
    StepResult,
)
from app.services.common import ResultBuilder
from app.services.validation import ValidationService
from app.storage_fixtures import StorageFixtureRequest
from app.stream_events import StreamEventProjector

logger = logging.getLogger(__name__)

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
        "requested": {
            "scenario_ids": getattr(request, "scenario_ids", None),
            "vms": request.selectors(),
        },
        "resolved": {
            "scenario_ids": [spec.id for spec in specs],
            "vm_pool": [vm.name for vm in vm_pool],
        },
        "runs": {run.run_id: _pending_run_entry(run) for run in runs},
        "started_at": _now_iso(),
        "finished_at": None,
    }


def _counts(runs: dict[str, dict[str, object]]) -> dict[str, int]:
    counts: dict[str, int] = dict.fromkeys(_COUNT_KEYS, 0)
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
        vm=result.vm,
        status=result.outcome,
        reason=result.reason,
        message=result.message,
        errors=result.errors,
        log=result.log,
        captures=result.captures,
        finished_at=result.finished_at,
    )


# Temporary name collision: app/services/automation_campaign.py (still live,
# used by main.py today) exports a same-named read_interrupted_campaign_summary/
# _persist_summary pair with a different on-disk schema (a bare list, no
# format_version). This one supersedes it and replaces the old module's wiring
# in a later task in this plan; until then the two coexist under different
# module names and this function's format_version check is what keeps them
# from misreading each other's files.
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
    if (
        not isinstance(runs, list)
        or not isinstance(resolved, dict)
        or not isinstance(requested, dict)
    ):
        return []
    required_keys = {"run_id", "scenario_id", "profile", "vm", "status"}
    for entry in runs:
        if (
            not isinstance(entry, dict)
            or not required_keys.issubset(entry)
            or not isinstance(entry["status"], str)
        ):
            return []
    for entry in runs:
        if entry["status"] == "running":
            entry["status"] = "interrupted"
    return runs


RunScenario = Callable[
    [AutomationRequest, Path, Callable[[StepResult], None], PureWindowsPath],
    OperationResult,
]


@dataclass
class _SchedulerState:
    pending: list[ScenarioRun]
    lock: threading.Lock = field(default_factory=threading.Lock)
    quarantined: set[str] = field(default_factory=set)
    stop_claiming: bool = False


def _sweep_pending(
    summary: dict[str, object],
    vm_pool: Sequence[VMConfig],
    spec_by_id: dict[str, ScenarioSpec],
    state: _SchedulerState,
) -> None:
    for entry in summary["runs"].values():  # type: ignore[union-attr]
        if entry["status"] != "pending":
            continue
        spec = spec_by_id[str(entry["scenario_id"])]
        has_worker = any(
            vm.name not in state.quarantined
            and vm.os == entry["profile"]
            and _vm_compatible(vm, spec.requirements)
            for vm in vm_pool
        )
        entry["status"] = (
            "stopped-after-failure" if has_worker else "no-compatible-worker-after-quarantine"
        )


def _aggregate_result(summary: dict[str, object]) -> OperationResult:
    entries = list(summary["runs"].values())  # type: ignore[union-attr]
    passed = all(entry["status"] == "passed" for entry in entries)
    counts = _counts(summary["runs"])  # type: ignore[arg-type]
    return OperationResult(
        status="ok" if passed else "error",
        operation="automation",
        message="Campaign passed" if passed else f"Campaign incomplete: {counts}",
        steps=[],
        campaign_summary=entries,
    )


class CampaignDispatcher:
    def __init__(
        self, configured: Settings, matrix: Sequence[ScenarioSpec] = SCENARIO_MATRIX
    ) -> None:
        self._configured = configured
        self._matrix = matrix

    def run(
        self,
        request: AutomationCampaignRequest,
        run_scenario: RunScenario,
        workspace: Path,
        on_step: Callable[[StepResult], None] | None = None,
    ) -> OperationResult:
        fleet = self._configured.vms
        # AutomationCampaignRequest.scenario_ids doesn't exist yet (added in a
        # later task); getattr keeps this buildable until then, consistent
        # with _build_summary's own tolerance for the missing field.
        scenario_ids = getattr(request, "scenario_ids", None)
        specs = _resolve_specs(self._matrix, scenario_ids, fleet)
        spec_by_id = {spec.id: spec for spec in specs}
        vm_pool = _resolve_worker_pool(self._configured, request.selectors())
        runs = _expand_runs(specs, fleet, vm_pool)

        validation = ValidationService(self._configured)
        build_result = ResultBuilder("automation")
        posix_path = validation.prepare_server(build_result, source=request.source)
        windows_path = validation.to_windows_share_path(posix_path)

        summary = _build_summary(request, specs, vm_pool, runs)
        _persist_summary(workspace, summary)

        state = _SchedulerState(pending=list(runs))
        updates: queue_module.Queue = queue_module.Queue()
        threads = [
            threading.Thread(
                target=self._worker,
                args=(
                    vm,
                    state,
                    updates,
                    spec_by_id,
                    request,
                    run_scenario,
                    on_step,
                    windows_path,
                    workspace,
                ),
            )
            for vm in vm_pool
        ]
        for thread in threads:
            thread.start()

        active = len(threads)
        while active > 0:
            kind, payload = updates.get()
            if kind == "claimed":
                run_id, vm_name, when, ack = payload
                try:
                    _mark_running(summary, run_id, vm_name, when)
                    _persist_summary(workspace, summary)
                finally:
                    # A worker is blocked on ack.wait() with no timeout --
                    # guarantee it unblocks even if _persist_summary raises
                    # (disk full, share unavailable, AV lock), then let the
                    # original exception still propagate: fail loudly rather
                    # than hang.
                    ack.set()
            elif kind == "completed":
                _mark_completed(summary, payload)
                _persist_summary(workspace, summary)
            elif kind == "worker_done":
                active -= 1

        for thread in threads:
            thread.join()

        _sweep_pending(summary, vm_pool, spec_by_id, state)
        summary["finished_at"] = _now_iso()
        _persist_summary(workspace, summary)
        return _aggregate_result(summary)

    @staticmethod
    def _worker(
        vm: VMConfig,
        state: _SchedulerState,
        updates: queue_module.Queue,
        spec_by_id: dict[str, ScenarioSpec],
        request: AutomationCampaignRequest,
        run_scenario: RunScenario,
        on_step: Callable[[StepResult], None] | None,
        windows_path: PureWindowsPath,
        workspace: Path,
    ) -> None:
        try:
            while True:
                claimed: ScenarioRun | None = None
                with state.lock:
                    if vm.name not in state.quarantined and not state.stop_claiming:
                        for candidate in state.pending:
                            spec = spec_by_id[candidate.scenario_id]
                            if candidate.profile == vm.os and _vm_compatible(
                                vm, spec.requirements
                            ):
                                claimed = candidate
                                state.pending.remove(candidate)
                                break
                if claimed is None:
                    return

                ack = threading.Event()
                updates.put(("claimed", (claimed.run_id, vm.name, _now_iso(), ack)))
                ack.wait()

                spec = spec_by_id[claimed.scenario_id]
                scenario_workspace = (
                    workspace / "scenarios" / f"{claimed.run_id.replace('::', '__')}-{vm.name}"
                )
                scenario_workspace.mkdir(parents=True, exist_ok=True)
                projector = StreamEventProjector("automation", scenario_workspace)

                def publish(
                    step: StepResult,
                    *,
                    scenario_id: str = claimed.scenario_id,
                    projector: StreamEventProjector = projector,
                ) -> None:
                    tagged = step.model_copy(
                        update={"context": {**step.context, "scenario": scenario_id}}
                    )
                    projector.project_step(tagged)
                    if on_step is not None:
                        on_step(tagged)

                child_request = AutomationRequest(
                    vms=[vm.name],
                    source=request.source,
                    apply=True,
                    linux_username=request.linux_username,
                    linux_password=request.linux_password,
                    linux_size_gib=request.linux_size_gib,
                    migrate_windows_preferences=request.migrate_windows_preferences,
                    distribution=spec.distribution,
                    first_boot=spec.first_boot,
                    installation_target=spec.installation_target,
                    snapshot_mode=spec.snapshot_mode,
                    storage_fixture=spec.storage_fixture,
                    boot_guardian_fault=spec.boot_guardian_fault,
                    simulate_stale_firmware_entries=spec.simulate_stale_firmware_entries,
                    force_offline_ntfs_resize=spec.force_offline_ntfs_resize,
                    share_windows_files_in_linux=spec.share_windows_files_in_linux,
                    share_linux_files_in_windows=spec.share_linux_files_in_windows,
                    preference_wallpaper=spec.preference_wallpaper,
                    verify_uninstall=spec.verify_uninstall,
                )

                claimed_at = _now_iso()
                # Narrowly scoped: run_scenario() and _classify() are the only
                # calls that decide the run's outcome. Logging/persistence I/O
                # (projector.project_result, and publish() in the except
                # branch) is handled separately below so a secondary I/O fault
                # there can never misreport a real pass as "failed", nor
                # prevent a "completed" message from ever being sent (which
                # would otherwise leave the run's summary entry stuck at
                # "running" forever -- _sweep_pending only touches "pending").
                try:
                    outcome_result = run_scenario(
                        child_request, scenario_workspace, publish, windows_path
                    )
                except Exception as exc:
                    error_step = StepResult(
                        step="automation.campaign_exception",
                        status="error",
                        message="Scenario terminated unexpectedly",
                        context={"exception_type": type(exc).__name__},
                    )
                    outcome, reason = "failed", None
                    errors = [error_step.model_dump(mode="json")]
                    message = error_step.message
                    log_target: OperationResult = OperationResult(
                        status="error",
                        operation="automation",
                        message=message,
                        steps=[error_step],
                    )
                    try:
                        publish(error_step)
                    except Exception:
                        logger.exception("Failed to publish the campaign_exception step")
                else:
                    outcome, reason = _classify(outcome_result, vm.name)
                    errors = [
                        step.model_dump(mode="json")
                        for step in outcome_result.steps
                        if step.status == "error"
                    ]
                    message = outcome_result.message
                    log_target = outcome_result

                try:
                    projector.project_result(log_target)
                except Exception:
                    logger.exception("Failed to persist the scenario's detailed log")

                with state.lock:
                    if outcome == "retryable" and reason in {"restore_failed", "preflight_failed"}:
                        state.quarantined.add(vm.name)
                    if outcome in {"failed", "retryable"} and not request.continue_after_failure:
                        state.stop_claiming = True

                updates.put(
                    (
                        "completed",
                        ScenarioRunResult(
                            run_id=claimed.run_id,
                            scenario_id=claimed.scenario_id,
                            profile=claimed.profile,
                            vm=vm.name,
                            outcome=outcome,
                            reason=reason,
                            message=message,
                            errors=errors,
                            log=str(projector.log_path),
                            captures=str(scenario_workspace / "captures"),
                            claimed_at=claimed_at,
                            finished_at=_now_iso(),
                        ),
                    )
                )
        finally:
            updates.put(("worker_done", vm.name))
