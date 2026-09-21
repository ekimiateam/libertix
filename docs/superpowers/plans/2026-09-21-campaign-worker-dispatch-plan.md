# Campaign Worker Dispatcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `automation_campaign.py`'s fixed sequential 4-scenario/3-VM loop with a `CampaignDispatcher` that treats (scenario config x logical platform profile) as the schedulable unit, letting any compatible physical VM clone claim the next pending run independently, inside the existing `operation="automation"` / `AutomationCampaignRequest` / `/api/v1/automation/full[/stream]` boundary.

**Architecture:** New module `auto_tests/app/services/campaign_dispatch.py` holds `ScenarioSpec`/`ScenarioRun`/`ScenarioRunResult` data types, a code-defined starter matrix, resolve/compatibility/classification pure functions, and `CampaignDispatcher`. `CampaignDispatcher.run()` builds the shared executable once, then runs one `threading.Thread` per physical worker VM, each claiming compatible pending runs from a lock-guarded scheduler state and calling a fresh `AutomationService` per run via the existing `run_scenario` callback shape. A single `queue.Queue` reports state to the one thread (the caller of `.run()`) that persists `campaign-summary.json`. `main.py` and `models.py` get minimal wiring changes; `automation_campaign.py` and its test file are deleted and replaced.

**Tech Stack:** Python 3.12+, FastAPI, Pydantic, pytest, stdlib `threading`/`queue`/`dataclasses`.

**Full design reference:** `docs/superpowers/specs/2026-09-21-campaign-worker-dispatch-design.md` (approved at commit `e20cdc8`). Every task below cites the relevant spec section; if implementation reveals a genuine contradiction with the spec, stop and flag it rather than silently deviating.

---

## Pre-flight: stale fixed-campaign assumptions audit

Confirmed during planning (do not re-derive; use this list directly):

| Location | Assumption | Disposition |
|---|---|---|
| `auto_tests/app/services/automation_campaign.py` (whole file, 148 lines) | `SCENARIOS` tuple, `run_campaign()`, old `read_interrupted_campaign_summary()`/`_persist_summary()` | **Delete entire file** in Task 9. Nothing outside this file and its test imports from it except `main.py` (`run_campaign`) and `test_automation_campaign.py`. |
| `auto_tests/app/main.py:151-166` | `len(selected) != 3 or not all(vm.automation_enabled ...)` before calling `run_campaign` | **Removed** in Task 9; replaced by `CampaignDispatcher`'s own `_resolve_worker_pool`/`_expand_runs` validation. |
| `auto_tests/app/models.py:88` | `AutomationCampaignRequest` docstring: `"""Four nominal installation scenarios, with one shared three-VM scope."""` | **Rewritten** in Task 9 to describe the new scenario-matrix-x-profile model. |
| `auto_tests/tests/test_automation_campaign.py` (whole file, 139 lines) | Every test imports `SCENARIOS`, `run_campaign`, `read_interrupted_campaign_summary` from `automation_campaign.py`; asserts `len(outcome.campaign_summary) == 4`, `child.vms == names` (all 3 VMs per call), nested `campaign_summary[i]["vms"][name]` shape, `"three distinct"` VM-count error | **Deleted and replaced** by `auto_tests/tests/test_campaign_dispatch.py` in Task 10. |
| `auto_tests/tests/test_api_runtime.py:647-699` (`test_full_campaign_endpoint_keeps_one_lock_and_returns_all_scenario_logs`) | Asserts `selectors == ["vm1","vm2","vm3"]` per `AutomationService.run()` call (today: one call per scenario selecting all 3 VMs at once), `len(data["campaign_summary"]) == 4`, nested `item["vms"].values()` | **Rewritten** in Task 11 for one call per (scenario, VM) pair and the new flat per-run `campaign_summary` shape; expect `len(data["campaign_summary"]) == 12` (4 nominal scenarios x 3 configured profiles in the default test fixture; the fifth starter-matrix scenario needs `secondary_disk_boot_order` which no default fixture VM has, so it silently contributes 0 runs — this is intended matrix behavior, not a test gap). |
| `auto_tests/tests/test_api.py:189` | `"campaignSummary"` referenced only as a static web-UI HTML element id (`id="campaignSummary"`) | **No change** — unrelated to the backend response shape; out of scope for this PR. |

**VM selector semantics (spec gap closed during planning):** `ValidationService.select_vms()` (`auto_tests/app/services/validation.py:109-153`) resolves selectors against **aliases** (VM name, host, OS string, normalized OS variants, vmid, `vm{vmid}`, plus BIOS/UEFI-specific aliases like `"win10-uefi"`), not just exact `VMConfig.name`. It also raises `WorkflowError("validation.select_vms", "Unknown VM selector", ...)` on any unresolvable selector, and — critically — `select_vms(None)` returns **every** configured VM (`self.settings.vms`), not just `automation_enabled` ones. `CampaignDispatcher`'s worker-pool resolution (Task 2) must call `ValidationService(configured).select_vms(selectors)` whenever `request.selectors()` is non-`None` (preserving alias resolution and the existing "Unknown VM selector" error), but must **not** call `select_vms(None)` for the omitted-filter case, because that would include non-`automation_enabled` VMs in the default worker pool — a correctness regression against today's `not all(vm.automation_enabled for vm in selected): raise` check. The omitted case instead filters `configured.vms` to `automation_enabled` directly. See Task 2 for the exact function.

---

## File Structure

- **Create** `auto_tests/app/services/campaign_dispatch.py` — all new types, pure resolve/classification functions, summary persistence, and `CampaignDispatcher`.
- **Create** `auto_tests/tests/test_campaign_dispatch.py` — full test coverage for the new module.
- **Modify** `auto_tests/app/services/automation.py` — `AutomationService.run()` gains `windows_path` parameter.
- **Modify** `auto_tests/app/main.py` — `_run_operation()` gains `windows_path` parameter (automation branch only); `AutomationCampaignRequest` branch calls `CampaignDispatcher` instead of `run_campaign`.
- **Modify** `auto_tests/app/models.py` — `AutomationCampaignRequest` gains `scenario_ids`; docstring rewritten.
- **Delete** `auto_tests/app/services/automation_campaign.py`.
- **Delete** `auto_tests/tests/test_automation_campaign.py`.
- **Modify** `auto_tests/tests/test_api_runtime.py` — rewrite the one full-campaign end-to-end test.

All commands below assume the working directory is the repo root (`C:\Workspace\libertix`) and use the project's existing test runner: `cd auto_tests && python -m pytest <path> -v` (matches how `auto_tests/tests/` is already run; confirm the exact invocation via `auto_tests/pyproject.toml`/`pytest.ini` if a step's expected output looks wrong — do not guess a different runner).

---

### Task 1: Scenario data model, compatibility predicate, starter matrix

**Spec reference:** "Logical profiles, physical workers, and option ownership", "Data model", "Starter matrix".

**Files:**
- Create: `auto_tests/app/services/campaign_dispatch.py`
- Test: `auto_tests/tests/test_campaign_dispatch.py`

- [ ] **Step 1: Write the failing tests**

```python
# auto_tests/tests/test_campaign_dispatch.py
from __future__ import annotations

from app.config import VMConfig
from app.services.campaign_dispatch import (
    SCENARIO_MATRIX,
    ScenarioRequirements,
    ScenarioSpec,
    _vm_compatible,
)


def _vm(**overrides: object) -> VMConfig:
    values = {
        "name": "vm1",
        "host": "192.0.2.10",
        "os": "Windows 10 UEFI",
        "vnc": "192.0.2.10:5900",
        "screen_width": 1280,
        "screen_height": 800,
        "vmid": 500,
        "firmware": "uefi",
        "automation_enabled": True,
    }
    values.update(overrides)
    return VMConfig(**values)


def test_vm_compatible_requires_matching_firmware_when_constrained() -> None:
    bios_requirement = ScenarioRequirements(firmware="bios")
    assert not _vm_compatible(_vm(firmware="uefi"), bios_requirement)
    assert _vm_compatible(_vm(firmware="bios"), bios_requirement)


def test_vm_compatible_requires_secondary_disk_when_constrained() -> None:
    requirement = ScenarioRequirements(requires_secondary_disk=True)
    assert not _vm_compatible(_vm(secondary_disk_boot_order=()), requirement)
    assert _vm_compatible(_vm(secondary_disk_boot_order=("scsi1",)), requirement)


def test_vm_compatible_with_no_requirements_accepts_any_vm() -> None:
    assert _vm_compatible(_vm(firmware="bios"), ScenarioRequirements())
    assert _vm_compatible(_vm(firmware="uefi"), ScenarioRequirements())


def test_starter_matrix_preserves_four_nominal_scenarios_with_verify_uninstall() -> None:
    nominal = [spec for spec in SCENARIO_MATRIX if "nominal" in spec.tags]
    assert len(nominal) == 4
    assert {(spec.distribution, spec.first_boot) for spec in nominal} == {
        ("mint", "windows"), ("mint", "linux"), ("zorin", "windows"), ("zorin", "linux"),
    }
    assert all(spec.verify_uninstall for spec in nominal)
    assert all(spec.requirements == ScenarioRequirements() for spec in nominal)


def test_starter_matrix_secondary_scenario_is_a_real_secondary_install() -> None:
    secondary = next(spec for spec in SCENARIO_MATRIX if "secondary-disk" in spec.tags)
    assert secondary.requirements.requires_secondary_disk is True
    assert secondary.snapshot_mode == "secondary-disk"
    assert secondary.installation_target == "secondary"
    assert secondary.verify_uninstall is True


def test_scenario_spec_storage_fixture_defaults_to_concrete_instance() -> None:
    from app.storage_fixtures import StorageFixtureRequest

    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    assert isinstance(spec.storage_fixture, StorageFixtureRequest)
```

- [ ] **Step 2: Run the tests to verify they fail with an import error**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'app.services.campaign_dispatch'`

- [ ] **Step 3: Write the module**

```python
# auto_tests/app/services/campaign_dispatch.py
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
    if requirements.requires_secondary_disk and not vm.secondary_disk_boot_order:
        return False
    return True


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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add auto_tests/app/services/campaign_dispatch.py auto_tests/tests/test_campaign_dispatch.py
git commit -m "Add campaign scenario data model, compatibility predicate, starter matrix"
```

---

### Task 2: Resolve logic — specs, worker pool, run expansion

**Spec reference:** "Dispatch algorithm" steps 1-3.

**Files:**
- Modify: `auto_tests/app/services/campaign_dispatch.py`
- Test: `auto_tests/tests/test_campaign_dispatch.py`

- [ ] **Step 1: Write the failing tests**

```python
# append to auto_tests/tests/test_campaign_dispatch.py
import pytest

from app.errors import WorkflowError
from app.services.campaign_dispatch import (
    SCENARIO_MATRIX,
    ScenarioRequirements,
    ScenarioSpec,
    _expand_runs,
    _fleet_profiles,
    _resolve_specs,
    _resolve_worker_pool,
)


def _settings_with_vms(*vm_overrides: dict) -> object:
    from tests.test_core import settings

    return settings(vms=tuple(_vm(**overrides) for overrides in vm_overrides))


def test_fleet_profiles_returns_every_automation_enabled_profile_for_unconstrained_spec() -> None:
    fleet = (
        _vm(name="a", os="Windows 10 BIOS", firmware="bios"),
        _vm(name="b", os="Windows 10 UEFI", firmware="uefi"),
        _vm(name="c", os="Windows 10 UEFI", firmware="uefi", automation_enabled=False),
    )
    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    assert _fleet_profiles(spec, fleet) == {"Windows 10 BIOS", "Windows 10 UEFI"}


def test_resolve_specs_defaults_to_full_matrix() -> None:
    fleet = (
        _vm(name="a", os="Windows 10 BIOS", firmware="bios"),
        _vm(name="b", os="Windows 10 UEFI", firmware="uefi"),
        _vm(name="c", os="Windows 11 UEFI", firmware="uefi"),
    )
    resolved = _resolve_specs(SCENARIO_MATRIX, None, fleet)
    assert {spec.id for spec in resolved} == {
        "mint-windows-first", "mint-linux-first", "zorin-windows-first", "zorin-linux-first",
    }  # secondary scenario silently dropped: no fleet VM has secondary_disk_boot_order


def test_resolve_specs_rejects_unknown_scenario_id() -> None:
    fleet = (_vm(name="a"),)
    with pytest.raises(WorkflowError, match="Unknown"):
        _resolve_specs(SCENARIO_MATRIX, ["not-a-real-scenario"], fleet)


def test_resolve_specs_rejects_explicit_id_with_zero_fleet_wide_compatible_profiles() -> None:
    fleet = (_vm(name="a", os="Windows 10 UEFI", secondary_disk_boot_order=()),)
    with pytest.raises(WorkflowError, match="No VM"):
        _resolve_specs(SCENARIO_MATRIX, ["mint-secondary-install"], fleet)


def test_resolve_specs_raises_when_nothing_resolves() -> None:
    with pytest.raises(WorkflowError, match="No scenarios"):
        _resolve_specs((), None, (_vm(name="a"),))


def test_resolve_worker_pool_omitted_filter_uses_automation_enabled_only() -> None:
    configured = _settings_with_vms(
        {"name": "a", "automation_enabled": True},
        {"name": "b", "automation_enabled": False},
    )
    pool = _resolve_worker_pool(configured, None)
    assert [vm.name for vm in pool] == ["a"]


def test_resolve_worker_pool_explicit_filter_resolves_aliases_via_select_vms() -> None:
    configured = _settings_with_vms(
        {"name": "vm1", "os": "Windows 10 UEFI", "firmware": "uefi", "automation_enabled": True},
    )
    pool = _resolve_worker_pool(configured, ["win10-uefi"])
    assert [vm.name for vm in pool] == ["vm1"]


def test_resolve_worker_pool_rejects_explicitly_selected_disabled_vm() -> None:
    configured = _settings_with_vms({"name": "vm1", "automation_enabled": False})
    with pytest.raises(WorkflowError, match="automation-enabled"):
        _resolve_worker_pool(configured, ["vm1"])


def test_resolve_worker_pool_propagates_unknown_selector_error() -> None:
    configured = _settings_with_vms({"name": "vm1", "automation_enabled": True})
    with pytest.raises(WorkflowError, match="Unknown VM selector"):
        _resolve_worker_pool(configured, ["does-not-exist"])


def test_expand_runs_produces_one_run_per_profile_per_spec() -> None:
    fleet = (
        _vm(name="a", os="Windows 10 BIOS", firmware="bios"),
        _vm(name="b", os="Windows 10 UEFI", firmware="uefi"),
    )
    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    runs = _expand_runs([spec], fleet, list(fleet))
    assert {run.profile for run in runs} == {"Windows 10 BIOS", "Windows 10 UEFI"}
    assert all(run.run_id == f"x::{run.profile}" for run in runs)


def test_expand_runs_rejects_vm_filter_that_drops_required_coverage() -> None:
    fleet = (
        _vm(name="a", os="Windows 10 BIOS", firmware="bios"),
        _vm(name="b", os="Windows 10 UEFI", firmware="uefi"),
    )
    pool = [vm for vm in fleet if vm.name == "a"]  # filtered pool drops the UEFI profile
    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    with pytest.raises(WorkflowError, match="VM filter"):
        _expand_runs([spec], fleet, pool)


def test_expand_runs_two_vms_sharing_a_profile_still_produce_one_run() -> None:
    fleet = (
        _vm(name="a", os="Windows 11 UEFI", firmware="uefi"),
        _vm(name="b", os="Windows 11 UEFI", firmware="uefi"),
    )
    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    runs = _expand_runs([spec], fleet, list(fleet))
    assert len(runs) == 1
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v -k "resolve or expand or fleet_profiles"`
Expected: FAIL — `ImportError` (names not defined yet)

- [ ] **Step 3: Implement the resolve functions**

```python
# append to auto_tests/app/services/campaign_dispatch.py
from collections.abc import Sequence

from app.config import Settings
from app.errors import WorkflowError
from app.services.validation import ValidationService


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
            "campaign.empty_matrix", "No scenarios resolved for this campaign"
        )
    return resolved


def _resolve_worker_pool(configured: Settings, selectors: list[str] | None) -> list[VMConfig]:
    if selectors is None:
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
    runs: list[ScenarioRun] = []
    for spec in specs:
        fleet_profiles = _fleet_profiles(spec, fleet)
        pool_profiles = {
            vm.os for vm in vm_pool if vm.automation_enabled and _vm_compatible(vm, spec.requirements)
        }
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
            "campaign.empty_matrix", "No scenario runs resolved for this campaign"
        )
    return runs
```

Also add the `_vm` test helper's `secondary_disk_boot_order` default handling — confirm `VMConfig` accepts it as a kwarg (it does; default `()`, see `config.py:29`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v`
Expected: PASS (all tests from Task 1 and Task 2)

- [ ] **Step 5: Commit**

```bash
git add auto_tests/app/services/campaign_dispatch.py auto_tests/tests/test_campaign_dispatch.py
git commit -m "Add campaign spec/worker-pool resolution and run expansion"
```

---

### Task 3: Outcome classification

**Spec reference:** "Outcome classification".

**Files:**
- Modify: `auto_tests/app/services/campaign_dispatch.py`
- Test: `auto_tests/tests/test_campaign_dispatch.py`

- [ ] **Step 1: Write the failing tests**

```python
# append to auto_tests/tests/test_campaign_dispatch.py
from app.models import OperationResult, StepResult
from app.services.campaign_dispatch import _classify


def test_classify_returns_passed_for_clean_ok_result_with_verdict() -> None:
    result = OperationResult(
        status="ok",
        operation="automation",
        message="done",
        steps=[
            StepResult(
                step="automation.vm_finished",
                status="ok",
                message="done",
                context={"vm": "vm1", "vm_status": "ok"},
            )
        ],
    )
    assert _classify(result, "vm1") == ("passed", None)


def test_classify_returns_failed_when_ok_status_missing_verdict() -> None:
    result = OperationResult(status="ok", operation="automation", message="incomplete", steps=[])
    assert _classify(result, "vm1") == ("failed", None)


def test_classify_returns_retryable_when_every_error_step_is_recognized_infra() -> None:
    result = OperationResult(
        status="error",
        operation="automation",
        message="preflight failed",
        steps=[
            StepResult(
                step="automation.rollback_preflight", status="error", message="boom", context={}
            )
        ],
    )
    outcome, reason = _classify(result, "vm1")
    assert outcome == "retryable"
    assert reason in {"restore_failed", "preflight_failed"}


def test_classify_returns_failed_when_any_error_step_is_a_real_failure() -> None:
    result = OperationResult(
        status="error",
        operation="automation",
        message="mixed failure",
        steps=[
            StepResult(
                step="automation.rollback_preflight", status="error", message="infra", context={}
            ),
            StepResult(
                step="automation.installer_crash", status="error", message="real bug", context={}
            ),
        ],
    )
    assert _classify(result, "vm1") == ("failed", None)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v -k classify`
Expected: FAIL — `ImportError: cannot import name '_classify'`

- [ ] **Step 3: Implement classification**

```python
# append to auto_tests/app/services/campaign_dispatch.py
from app.models import OperationResult

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


def _is_infra_step(step: str) -> bool:
    return step in _RECOGNIZED_INFRA_STEPS or step.startswith("automation.rollback_")


def _classify(outcome: OperationResult, vm_name: str) -> tuple[ScenarioOutcome, str | None]:
    error_steps = [step.step for step in outcome.steps if step.status == "error"]
    if outcome.status == "error":
        if error_steps and all(_is_infra_step(step) for step in error_steps):
            reason = (
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add auto_tests/app/services/campaign_dispatch.py auto_tests/tests/test_campaign_dispatch.py
git commit -m "Add conservative campaign outcome classification"
```

---

### Task 4: Summary persistence and `read_interrupted_campaign_summary`

**Spec reference:** "Summary persistence", "`campaign-summary.json` schema", "`read_interrupted_campaign_summary` (full rewrite)".

**Files:**
- Modify: `auto_tests/app/services/campaign_dispatch.py`
- Test: `auto_tests/tests/test_campaign_dispatch.py`

- [ ] **Step 1: Write the failing tests**

```python
# append to auto_tests/tests/test_campaign_dispatch.py
import json
from pathlib import Path

from app.models import AutomationCampaignRequest
from app.services.campaign_dispatch import (
    FORMAT_VERSION,
    ScenarioRunResult,
    _build_summary,
    _counts,
    _mark_completed,
    _mark_running,
    _persist_summary,
    read_interrupted_campaign_summary,
)


def _campaign_request(**overrides: object) -> AutomationCampaignRequest:
    values = {"apply": True, "linux_password": "test-passphrase"}
    values.update(overrides)
    return AutomationCampaignRequest(**values)


def test_build_summary_has_one_pending_entry_per_run() -> None:
    specs = [ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())]
    vm_pool = [_vm(name="a")]
    runs = [ScenarioRun(run_id="x::Windows 10 UEFI", scenario_id="x", profile="Windows 10 UEFI")]
    summary = _build_summary(_campaign_request(), specs, vm_pool, runs)
    assert summary["format_version"] == FORMAT_VERSION
    entry = summary["runs"]["x::Windows 10 UEFI"]
    assert entry["status"] == "pending"
    assert entry["vm"] is None


def test_persist_summary_writes_atomically_and_matches_schema(tmp_path: Path) -> None:
    specs = [ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())]
    vm_pool = [_vm(name="a")]
    runs = [ScenarioRun(run_id="x::Windows 10 UEFI", scenario_id="x", profile="Windows 10 UEFI")]
    summary = _build_summary(_campaign_request(), specs, vm_pool, runs)
    _persist_summary(tmp_path, summary)
    on_disk = json.loads((tmp_path / "campaign-summary.json").read_text(encoding="utf-8"))
    assert on_disk["format_version"] == FORMAT_VERSION
    assert isinstance(on_disk["runs"], list)
    assert on_disk["runs"][0]["run_id"] == "x::Windows 10 UEFI"
    assert on_disk["counts"]["pending"] == 1
    assert not (tmp_path / "campaign-summary.json.tmp").exists()


def test_mark_running_then_completed_updates_entry_and_counts() -> None:
    specs = [ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())]
    runs = [ScenarioRun(run_id="x::p", scenario_id="x", profile="p")]
    summary = _build_summary(_campaign_request(), specs, [_vm(name="a")], runs)
    _mark_running(summary, "x::p", "a", "2026-09-21T00:00:00Z")
    assert summary["runs"]["x::p"]["status"] == "running"
    _mark_completed(
        summary,
        ScenarioRunResult(
            run_id="x::p", scenario_id="x", profile="p", vm="a", outcome="passed", reason=None,
            message="ok", errors=[], log="log.txt", captures="captures",
            claimed_at="2026-09-21T00:00:00Z", finished_at="2026-09-21T00:01:00Z",
        ),
    )
    assert summary["runs"]["x::p"]["status"] == "passed"
    assert _counts(summary["runs"])["passed"] == 1


def test_read_interrupted_campaign_summary_marks_running_interrupted_and_keeps_pending(
    tmp_path: Path,
) -> None:
    specs = [ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())]
    runs = [
        ScenarioRun(run_id="x::a", scenario_id="x", profile="a"),
        ScenarioRun(run_id="x::b", scenario_id="x", profile="b"),
    ]
    summary = _build_summary(_campaign_request(), specs, [_vm(name="v")], runs)
    _mark_running(summary, "x::a", "v", "2026-09-21T00:00:00Z")
    _persist_summary(tmp_path, summary)

    result = read_interrupted_campaign_summary(tmp_path)
    statuses = {entry["run_id"]: entry["status"] for entry in result}
    assert statuses["x::a"] == "interrupted"
    assert statuses["x::b"] == "pending"


def test_read_interrupted_campaign_summary_fails_safe_on_malformed_file(tmp_path: Path) -> None:
    (tmp_path / "campaign-summary.json").write_text("not json", encoding="utf-8")
    assert read_interrupted_campaign_summary(tmp_path) == []


def test_read_interrupted_campaign_summary_fails_safe_on_missing_file(tmp_path: Path) -> None:
    assert read_interrupted_campaign_summary(tmp_path) == []


def test_read_interrupted_campaign_summary_fails_safe_on_wrong_format_version(
    tmp_path: Path,
) -> None:
    (tmp_path / "campaign-summary.json").write_text(
        json.dumps({"format_version": 999, "runs": [], "resolved": {}, "requested": {}}),
        encoding="utf-8",
    )
    assert read_interrupted_campaign_summary(tmp_path) == []
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v -k "summary or persist or interrupted"`
Expected: FAIL — `ImportError`

- [ ] **Step 3: Implement persistence and the reader**

```python
# append to auto_tests/app/services/campaign_dispatch.py
import json
import os
from datetime import UTC, datetime
from pathlib import Path

from app.models import AutomationCampaignRequest

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
        "requested": {"scenario_ids": request.scenario_ids, "vms": request.selectors()},
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
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add auto_tests/app/services/campaign_dispatch.py auto_tests/tests/test_campaign_dispatch.py
git commit -m "Add campaign-summary.json persistence and interrupted-readback"
```

---

### Task 5: `windows_path` plumbing in `AutomationService.run()`

**Spec reference:** "Dispatch algorithm" step 5, "`windows_path` is not a request field".

**Files:**
- Modify: `auto_tests/app/services/automation.py:84-197`
- Test: `auto_tests/tests/test_core.py`

- [ ] **Step 1: Write the failing test**

Find an existing test in `test_core.py` that exercises `AutomationService.run()` with a mocked `ValidationService` (search `class FakeValidationService` or similar around `prepare_server`/`to_windows_share_path` mocks) and add:

```python
# add near existing AutomationService.run() tests in auto_tests/tests/test_core.py
from pathlib import PureWindowsPath


def test_run_skips_prepare_server_when_windows_path_is_supplied(monkeypatch: pytest.MonkeyPatch) -> None:
    service = _automation_service_with_fakes(monkeypatch)  # reuse this suite's existing fixture helper
    calls: list[str] = []
    monkeypatch.setattr(
        service.validation, "prepare_server", lambda *a, **k: calls.append("prepare_server") or None
    )
    monkeypatch.setattr(
        service.validation, "to_windows_share_path", lambda *a, **k: calls.append("to_windows_share_path")
    )
    supplied = PureWindowsPath("Z:/prebuilt/Libertix.exe")
    service.run(
        ["vm1"],
        linux_password="test-passphrase",
        monitor_iso=True,
        windows_path=supplied,
    )
    assert calls == []
```

If this codebase's existing `AutomationService.run()` test suite already has a helper that constructs a fully-faked service (VNC/SSH/Proxmox clients mocked) — use that exact helper name; do not invent a parallel fixture. Search first: `grep -n "def _automation_service\|def make_automation_service\|AutomationService(" auto_tests/tests/test_core.py | head -20`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd auto_tests && python -m pytest tests/test_core.py -v -k windows_path`
Expected: FAIL — `TypeError: run() got an unexpected keyword argument 'windows_path'`

- [ ] **Step 3: Add the parameter**

In `auto_tests/app/services/automation.py`, change the `run()` signature (currently `automation.py:84-119`):

```python
        source: SourceMode = "remote",
        on_step: Callable[[StepResult], None] | None = None,
        run_workspace: Path | None = None,
        windows_path: PureWindowsPath | None = None,
    ) -> OperationResult:
```

(add `windows_path: PureWindowsPath | None = None` as the last parameter, after `run_workspace`)

Then change the build step (currently `automation.py:188-189`):

```python
            executable = self.validation.prepare_server(result, source=source)
            windows_path = self.validation.to_windows_share_path(executable)
```

to:

```python
            if windows_path is None:
                executable = self.validation.prepare_server(result, source=source)
                windows_path = self.validation.to_windows_share_path(executable)
```

- [ ] **Step 4: Run the test to verify it passes, and the full automation.py test file for regressions**

Run: `cd auto_tests && python -m pytest tests/test_core.py -v -k windows_path`
Expected: PASS

Run: `cd auto_tests && python -m pytest tests/test_core.py -v`
Expected: PASS (no regressions — `windows_path` defaults to `None`, existing behavior unchanged)

- [ ] **Step 5: Commit**

```bash
git add auto_tests/app/services/automation.py auto_tests/tests/test_core.py
git commit -m "Let AutomationService.run() accept a pre-built windows_path"
```

---

### Task 6: `windows_path` plumbing in `_run_operation`

**Spec reference:** "API / wiring changes".

**Files:**
- Modify: `auto_tests/app/main.py:131-167`
- Test: `auto_tests/tests/test_api_runtime.py`

- [ ] **Step 1: Write the failing test**

```python
# add to auto_tests/tests/test_api_runtime.py, near other _run_operation-level tests
from pathlib import PureWindowsPath

from app import main as main_module


def test_run_operation_passes_windows_path_through_to_automation_service(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    received: dict[str, object] = {}

    class FakeAutomationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, selectors, *, windows_path=None, **_kwargs):
            received["windows_path"] = windows_path
            return OperationResult(status="ok", operation="automation", message="done", steps=[])

    monkeypatch.setattr(main_module, "AutomationService", FakeAutomationService)
    configured = settings(capture_dir=tmp_path / "captures", operation_log_dir=tmp_path / "logs")
    request = AutomationRequest(apply=True, linux_password="test-passphrase")
    supplied = PureWindowsPath("Z:/prebuilt/Libertix.exe")

    main_module._run_operation(
        configured, "automation", ["vm1"], request, None, None, windows_path=supplied
    )
    assert received["windows_path"] == supplied
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd auto_tests && python -m pytest tests/test_api_runtime.py -v -k passes_windows_path`
Expected: FAIL — `TypeError: _run_operation() got an unexpected keyword argument 'windows_path'`

- [ ] **Step 3: Add the parameter**

In `auto_tests/app/main.py`, change `_run_operation`'s signature (currently `main.py:131-138`):

```python
def _run_operation(
    configured: Settings,
    operation: OperationName,
    selectors: list[str] | None,
    request: ValidationRequest | AutomationRequest | None,
    on_step: Callable[[StepResult], None] | None = None,
    run_workspace: Path | None = None,
    windows_path: PureWindowsPath | None = None,
) -> OperationResult:
```

(add `windows_path` as the last parameter; add `from pathlib import Path, PureWindowsPath` if `PureWindowsPath` isn't already imported in `main.py` — check first: `grep -n "^from pathlib" auto_tests/app/main.py`)

Then in the plain-`AutomationRequest` branch (currently `main.py:175-197`), add `windows_path=windows_path` to the `AutomationService(...).run(...)` call's keyword arguments (any position, matches the pattern of the other keyword args already there).

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd auto_tests && python -m pytest tests/test_api_runtime.py -v -k passes_windows_path`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add auto_tests/app/main.py auto_tests/tests/test_api_runtime.py
git commit -m "Thread windows_path through _run_operation's automation branch"
```

---

### Task 7: `CampaignDispatcher` — worker loop and consumer loop

**Spec reference:** "Dispatch algorithm" steps 6-9, "Restore-before-reuse", "Summary persistence (concrete single-writer model)".

This is the largest task. Build it with a **fake `run_scenario`** so no real `AutomationService`/Proxmox/SSH dependency is needed — matches the existing test style for `run_campaign` (`test_automation_campaign.py`'s `run(child, workspace, publish)` fakes).

**Files:**
- Modify: `auto_tests/app/services/campaign_dispatch.py`
- Test: `auto_tests/tests/test_campaign_dispatch.py`

- [ ] **Step 1: Write the failing tests**

```python
# append to auto_tests/tests/test_campaign_dispatch.py
import threading
import time
from pathlib import PureWindowsPath

from app.services.campaign_dispatch import CampaignDispatcher


def _fake_run_scenario_always_ok(distribution_by_vm: dict[str, str] | None = None):
    calls: list[tuple[str, str]] = []

    def run(child, workspace, publish, windows_path):
        vm_name = child.vms[0]
        calls.append((vm_name, child.distribution))
        step = StepResult(
            step="automation.vm_finished", status="ok", message="done",
            context={"vm": vm_name, "vm_status": "ok"},
        )
        publish(step)
        return OperationResult(status="ok", operation="automation", message="done", steps=[step])

    run.calls = calls  # type: ignore[attr-defined]
    return run


def test_campaign_dispatcher_runs_every_resolved_run_exactly_once(tmp_path: Path) -> None:
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
        {"name": "b", "os": "Windows 10 UEFI", "firmware": "uefi", "automation_enabled": True},
        {"name": "c", "os": "Windows 11 UEFI", "firmware": "uefi", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(apply=True, linux_password="test-passphrase")
    run_scenario = _fake_run_scenario_always_ok()
    result = CampaignDispatcher(configured).run(request, run_scenario, tmp_path, on_step=None)
    assert result.status == "ok"
    assert len(run_scenario.calls) == 12  # 4 nominal scenarios x 3 profiles
    assert len(set(run_scenario.calls)) == 12  # no run claimed twice


def test_campaign_dispatcher_two_vms_sharing_a_profile_compete_for_the_same_runs(
    tmp_path: Path,
) -> None:
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 11 UEFI", "firmware": "uefi", "automation_enabled": True},
        {"name": "b", "os": "Windows 11 UEFI", "firmware": "uefi", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True, linux_password="test-passphrase",
        scenario_ids=["mint-windows-first", "mint-linux-first"],
    )
    run_scenario = _fake_run_scenario_always_ok()
    result = CampaignDispatcher(configured).run(request, run_scenario, tmp_path, on_step=None)
    assert result.status == "ok"
    assert len(run_scenario.calls) == 2  # 2 scenarios x 1 profile, split across 2 competing VMs
    claimed_vms = {vm for vm, _distribution in run_scenario.calls}
    assert claimed_vms  # at least one of the two VMs claimed work; both are eligible


def test_campaign_dispatcher_claim_respects_capability_not_just_profile_string(
    tmp_path: Path,
) -> None:
    configured = _settings_with_vms(
        {
            "name": "with-secondary", "os": "Windows 11 UEFI", "firmware": "uefi",
            "automation_enabled": True, "secondary_disk_boot_order": ("scsi1",),
        },
        {
            "name": "without-secondary", "os": "Windows 11 UEFI", "firmware": "uefi",
            "automation_enabled": True, "secondary_disk_boot_order": (),
        },
    )
    request = AutomationCampaignRequest(
        apply=True, linux_password="test-passphrase", scenario_ids=["mint-secondary-install"],
    )
    run_scenario = _fake_run_scenario_always_ok()
    result = CampaignDispatcher(configured).run(request, run_scenario, tmp_path, on_step=None)
    assert result.status == "ok"
    assert run_scenario.calls == [("with-secondary", "mint")]


def test_campaign_dispatcher_continue_after_failure_false_stops_new_claims(tmp_path: Path) -> None:
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True, linux_password="test-passphrase",
        scenario_ids=["mint-windows-first", "mint-linux-first"],
        continue_after_failure=False,
    )

    def run(child, workspace, publish, windows_path):
        step = StepResult(
            step="automation.installer_crash", status="error", message="boom", context={},
        )
        publish(step)
        return OperationResult(status="error", operation="automation", message="boom", steps=[step])

    result = CampaignDispatcher(configured).run(request, run, tmp_path, on_step=None)
    assert result.status == "error"
    statuses = {entry["status"] for entry in result.campaign_summary}
    assert "stopped-after-failure" in statuses
    assert "failed" in statuses


def test_campaign_dispatcher_restore_failure_quarantines_worker_not_whole_campaign(
    tmp_path: Path,
) -> None:
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
        {"name": "b", "os": "Windows 10 UEFI", "firmware": "uefi", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True, linux_password="test-passphrase",
        scenario_ids=["mint-windows-first", "mint-linux-first"],
        continue_after_failure=True,
    )

    def run(child, workspace, publish, windows_path):
        if child.vms[0] == "a":
            step = StepResult(
                step="automation.rollback_preflight", status="error", message="restore broke",
                context={},
            )
            publish(step)
            return OperationResult(
                status="error", operation="automation", message="restore broke", steps=[step],
            )
        step = StepResult(
            step="automation.vm_finished", status="ok", message="done",
            context={"vm": "b", "vm_status": "ok"},
        )
        publish(step)
        return OperationResult(status="ok", operation="automation", message="done", steps=[step])

    result = CampaignDispatcher(configured).run(request, run, tmp_path, on_step=None)
    entries = {entry["scenario_id"] + "::" + entry["profile"]: entry for entry in result.campaign_summary}
    assert entries["mint-windows-first::Windows 10 BIOS"]["status"] == "retryable"
    assert entries["mint-windows-first::Windows 10 UEFI"]["status"] == "passed"
    assert entries["mint-linux-first::Windows 10 UEFI"]["status"] == "passed"


def test_campaign_dispatcher_worker_done_reported_on_every_exit_path(tmp_path: Path) -> None:
    """No compatible worker at all -> dispatcher must still terminate, not hang."""

    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True, linux_password="test-passphrase", scenario_ids=["mint-windows-first"],
    )
    run_scenario = _fake_run_scenario_always_ok()

    completed = threading.Event()

    def target() -> None:
        CampaignDispatcher(configured).run(request, run_scenario, tmp_path, on_step=None)
        completed.set()

    thread = threading.Thread(target=target)
    thread.start()
    thread.join(timeout=5)
    assert completed.is_set(), "CampaignDispatcher.run() hung -- worker_done not guaranteed"


def test_campaign_dispatcher_stop_claiming_visible_before_consumer_drains_queue(
    tmp_path: Path,
) -> None:
    """Regression test for the queue-latency race: a worker must set stop_claiming
    itself, synchronously, at classification time -- not rely on the consumer."""

    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True, linux_password="test-passphrase",
        scenario_ids=["mint-windows-first", "mint-linux-first"],
        continue_after_failure=False,
    )
    claim_order: list[str] = []

    def run(child, workspace, publish, windows_path):
        claim_order.append(child.first_boot)
        step = StepResult(step="automation.installer_crash", status="error", message="boom", context={})
        publish(step)
        return OperationResult(status="error", operation="automation", message="boom", steps=[step])

    CampaignDispatcher(configured).run(request, run, tmp_path, on_step=None)
    # Only the single VM in the pool exists, so it can claim at most one run before
    # the failure it just produced must stop it from claiming the second.
    assert len(claim_order) == 1
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v -k CampaignDispatcher`
Expected: FAIL — `ImportError: cannot import name 'CampaignDispatcher'`

- [ ] **Step 3: Implement `CampaignDispatcher`**

```python
# append to auto_tests/app/services/campaign_dispatch.py
import queue as queue_module
import threading
from collections.abc import Callable
from pathlib import PureWindowsPath

from app.models import AutomationRequest, OperationResult, StepResult
from app.services.common import ResultBuilder
from app.stream_events import StreamEventProjector

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
    def __init__(self, configured: Settings, matrix: Sequence[ScenarioSpec] = SCENARIO_MATRIX) -> None:
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
        specs = _resolve_specs(self._matrix, request.scenario_ids, fleet)
        spec_by_id = {spec.id: spec for spec in specs}
        vm_pool = _resolve_worker_pool(self._configured, request.selectors())
        runs = _expand_runs(specs, fleet, vm_pool)

        validation = ValidationService(self._configured)
        build_result = ResultBuilder("automation", on_step=on_step)
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
                    vm, state, updates, spec_by_id, request, run_scenario, on_step, windows_path,
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
                _mark_running(summary, run_id, vm_name, when)
                _persist_summary(workspace, summary)
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
                            if candidate.profile == vm.os and _vm_compatible(vm, spec.requirements):
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

                def publish(step: StepResult, *, scenario_id=claimed.scenario_id) -> None:
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
                try:
                    outcome_result = run_scenario(child_request, scenario_workspace, publish, windows_path)
                    outcome, reason = _classify(outcome_result, vm.name)
                    errors = [
                        step.model_dump(mode="json")
                        for step in outcome_result.steps
                        if step.status == "error"
                    ]
                    message = outcome_result.message
                    projector.project_result(outcome_result)
                except Exception as exc:
                    error_step = StepResult(
                        step="automation.campaign_exception",
                        status="error",
                        message="Scenario terminated unexpectedly",
                        context={"exception_type": type(exc).__name__},
                    )
                    publish(error_step)
                    outcome, reason = "failed", None
                    errors = [error_step.model_dump(mode="json")]
                    message = error_step.message
                    projector.project_result(
                        OperationResult(
                            status="error", operation="automation", message=message, steps=[error_step],
                        )
                    )

                with state.lock:
                    if outcome == "retryable" and reason in {"restore_failed", "preflight_failed"}:
                        state.quarantined.add(vm.name)
                    if outcome in {"failed", "retryable"} and not request.continue_after_failure:
                        state.stop_claiming = True

                updates.put((
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
                ))
        finally:
            updates.put(("worker_done", vm.name))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py -v`
Expected: PASS (all tests from Tasks 1-7)

- [ ] **Step 5: Commit**

```bash
git add auto_tests/app/services/campaign_dispatch.py auto_tests/tests/test_campaign_dispatch.py
git commit -m "Add CampaignDispatcher worker/consumer loop and orchestration"
```

---

### Task 8: Wire `main.py` and `models.py`; delete `automation_campaign.py`

**Spec reference:** "API / wiring changes"; pre-flight audit table above.

**Files:**
- Modify: `auto_tests/app/main.py:1-198`
- Modify: `auto_tests/app/models.py:81-137`
- Delete: `auto_tests/app/services/automation_campaign.py`
- Delete: `auto_tests/tests/test_automation_campaign.py`

- [ ] **Step 1: Update `models.py`**

Change `AutomationCampaignRequest`'s docstring and add `scenario_ids` (currently `models.py:87-96`):

```python
class AutomationCampaignRequest(ValidationRequest):
    """A campaign run: the code-defined scenario matrix, expanded across
    every compatible logical platform profile, dispatched to whichever
    configured automation-enabled VM claims each pending run. `vms`/`vm`
    (inherited from ValidationRequest) restrict the worker pool, not the
    required coverage; `scenario_ids` restricts which matrix scenarios run.
    """

    model_config = ConfigDict(extra="forbid")
    apply: Literal[True]
    linux_username: str = "test"
    linux_password: str = Field(min_length=4, max_length=128)
    linux_size_gib: int = Field(default=20, ge=_MINIMUM_LINUX_SIZE_GIB, le=16384)
    migrate_windows_preferences: bool = False
    continue_after_failure: bool = False
    scenario_ids: list[str] | None = Field(
        default=None, description="Optional subset of the campaign scenario matrix to run"
    )

    @model_validator(mode="after")
    def validate_installation_options(self) -> AutomationCampaignRequest:
        AutomationRequest(
            apply=True,
            linux_username=self.linux_username,
            linux_password=self.linux_password,
            linux_size_gib=self.linux_size_gib,
        )
        return self
```

- [ ] **Step 2: Update `main.py`'s imports and `_run_operation`**

Remove the `run_campaign` import (currently near the top of `main.py`, alongside other `app.services.*` imports — search `from app.services.automation_campaign import`), replace with:

```python
from app.services.campaign_dispatch import SCENARIO_MATRIX, CampaignDispatcher
```

Replace the `AutomationCampaignRequest` branch in `_run_operation` (currently `main.py:151-166`):

```python
    if operation == "automation":
        if isinstance(request, AutomationCampaignRequest):
            if run_workspace is None:
                raise ValueError("The complete campaign requires an isolated operation workspace")
            return CampaignDispatcher(configured, SCENARIO_MATRIX).run(
                request,
                lambda child, workspace, publish, child_windows_path: _run_operation(
                    configured,
                    "automation",
                    child.selectors(),
                    child,
                    publish,
                    workspace,
                    windows_path=child_windows_path,
                ),
                run_workspace,
                on_step,
            )
```

(everything below this block, the plain-`AutomationRequest` branch, is unchanged from Task 6)

- [ ] **Step 3: Delete the old module and its test file**

```bash
git rm auto_tests/app/services/automation_campaign.py
git rm auto_tests/tests/test_automation_campaign.py
```

(Task 10 recreates equivalent coverage as `test_campaign_dispatch.py`; Tasks 1-7 already cover most of what the old test file checked, in more detail — do not restore the deleted file's assertions verbatim, they assert the old fixed-4/fixed-3 shape.)

- [ ] **Step 4: Run the full app import and a smoke test**

Run: `cd auto_tests && python -c "from app.main import create_app; create_app"`
Expected: no import errors (confirms nothing else still imports `automation_campaign`)

Run: `cd auto_tests && python -m pytest tests/test_campaign_dispatch.py tests/test_core.py -v`
Expected: PASS (no leftover references to the deleted module)

- [ ] **Step 5: Commit**

```bash
git add auto_tests/app/main.py auto_tests/app/models.py
git commit -m "Wire CampaignDispatcher into _run_operation; remove old sequential campaign module"
```

---

### Task 9: Rewrite the full-campaign end-to-end test in `test_api_runtime.py`

**Spec reference:** pre-flight audit table (`test_full_campaign_endpoint_keeps_one_lock_and_returns_all_scenario_logs`).

**Files:**
- Modify: `auto_tests/tests/test_api_runtime.py:647-699`

- [ ] **Step 1: Replace the test**

```python
@pytest.mark.parametrize("stream", [False, True])
def test_full_campaign_endpoint_keeps_one_lock_and_returns_all_run_logs(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path, stream: bool
) -> None:
    lock = FakeOperationLock()
    monkeypatch.setattr(main_module, "operation_lock", lock)

    class FakeAutomationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, selectors, *, on_step, windows_path=None, **_kwargs):
            assert len(selectors) == 1  # one physical VM per campaign run, not three at once
            vm_name = selectors[0]
            step = StepResult(
                step="automation.vm_finished", status="ok", message="done",
                context={"vm": vm_name, "vm_status": "ok"},
            )
            on_step(step)
            return OperationResult(status="ok", operation="automation", message="done", steps=[step])

    class FakeValidationService:
        def __init__(self, settings) -> None:
            self._settings = settings

        def prepare_server(self, result, *, source):
            return PurePosixPath("/srv/libertix-smb/build/Libertix.exe")

        def to_windows_share_path(self, path):
            return PureWindowsPath("Z:/build/Libertix.exe")

        def select_vms(self, selectors):
            from app.services.validation import ValidationService as RealValidationService

            return RealValidationService(self._settings).select_vms(selectors)

    monkeypatch.setattr(main_module, "AutomationService", FakeAutomationService)
    monkeypatch.setattr("app.services.campaign_dispatch.ValidationService", FakeValidationService)
    configured = settings(capture_dir=tmp_path / "captures", operation_log_dir=tmp_path / "logs")
    configured = configured.model_copy(
        update={
            "vms": tuple(
                vm.model_copy(update={"automation_enabled": True}) for vm in configured.vms
            )
        }
    )
    endpoint = "/api/v1/automation/full" + ("/stream?format=ndjson" if stream else "")
    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(endpoint, json={"apply": True, "linux_password": "test-passphrase"})
    assert response.status_code == 200
    data = (
        [json.loads(line) for line in response.text.splitlines()][-1]["data"]
        if stream
        else response.json()
    )
    assert data["status"] == "ok"
    # 4 nominal scenarios x 3 configured profiles (BIOS, UEFI-10, UEFI-11 in the test
    # fixture); the fifth starter-matrix scenario needs secondary_disk_boot_order,
    # which no fixture VM has, so it contributes 0 runs by design.
    assert len(data["campaign_summary"]) == 12
    assert len({entry["log"] for entry in data["campaign_summary"]}) == 12
    assert all(Path(entry["log"]).is_file() for entry in data["campaign_summary"])
    assert all(entry["status"] == "passed" for entry in data["campaign_summary"])
    assert lock.acquire_calls == lock.release_calls == 1
```

Note the `PureWindowsPath`/`PurePosixPath` imports must already exist at the top of `test_api_runtime.py` (check first — add if missing).

- [ ] **Step 2: Run the test**

Run: `cd auto_tests && python -m pytest tests/test_api_runtime.py -v -k full_campaign_endpoint`
Expected: PASS

If the `FakeValidationService`/monkeypatch approach above doesn't cleanly intercept `CampaignDispatcher`'s internal `ValidationService(self._configured)` call, use `monkeypatch.setattr("app.services.campaign_dispatch.ValidationService", ...)` exactly as shown (patches the name as imported into `campaign_dispatch.py`, not the original `validation.py` module) — this is the standard `unittest.mock`/`monkeypatch` pattern for patching a name used via `from X import Y`.

- [ ] **Step 3: Run the entire `test_api_runtime.py` file for regressions**

Run: `cd auto_tests && python -m pytest tests/test_api_runtime.py -v`
Expected: PASS

- [ ] **Step 4: Commit**

```bash
git add auto_tests/tests/test_api_runtime.py
git commit -m "Rewrite full-campaign end-to-end test for per-VM-per-profile dispatch"
```

---

### Task 10: Full test suite run and self-review

**Files:** none (verification only)

- [ ] **Step 1: Run the complete `auto_tests` suite**

Run: `cd auto_tests && python -m pytest tests/ -v`
Expected: PASS, zero failures, zero errors. Pay particular attention to any test that imports `app.services.automation_campaign` (should not exist) or references `SCENARIOS`/`run_campaign` (should not exist).

- [ ] **Step 2: Grep for any leftover references to the deleted module**

Run: `cd /c/Workspace/libertix && grep -rn "automation_campaign\|run_campaign\b" auto_tests/app auto_tests/tests --include="*.py"`
Expected: no output (empty). If anything remains, fix it before proceeding — do not leave a dangling import.

- [ ] **Step 3: Confirm the branch and commit history are still local-only**

Run: `cd /c/Workspace/libertix && git log --oneline feature/campaign-worker-dispatch -15 && git status && git log --oneline origin/feature/campaign-worker-dispatch 2>&1 | head -1`

Expected: the last command errors (`unknown revision` or similar) — confirms `origin` (the user's fork) does not yet have this branch. Do not push.

- [ ] **Step 4: Report completion**

Summarize to the user: all tasks complete, full test suite passes, `automation_campaign.py`/its test file deleted and replaced, nothing pushed. Remind them of the still-open item flagged during spec review: this plan's own creation (the writing-plans skill invocation) was done correctly through the sanctioned brainstorming -> writing-plans flow, unlike the earlier subagent research task that self-authorized branch/commit/file-write actions outside its read-only mandate — that boundary violation should stay noted in the eventual PR/handoff description, per the user's explicit request.

---

## Self-Review Notes (completed during plan authoring)

- **Spec coverage:** every named section of the design spec (data model, resolve algorithm, build-once, worker loop, consumer loop, outcome classification, restore-before-reuse, summary persistence, schema, interrupted-readback, compatibility notes, API wiring, testing plan) maps to a task above. The one spec item intentionally *not* implemented as code is the "legacy-shaped `campaign_summary` projection" mentioned as a maybe-needed fallback in the spec's Compatibility section — the audit in this plan's Pre-flight section confirms no other caller/UI depends on the old nested `vms` dict shape (only the one test, rewritten in Task 9), so that fallback is not built, per the spec's own "unless... finds an existing consumer that needs one."
- **Placeholder scan:** no `TBD`/`TODO`/"add appropriate handling" in any task; every step has real, complete code.
- **Type consistency:** `ScenarioRunResult.outcome`/`reason` match `_classify`'s return type across Tasks 3 and 7; `run_scenario`'s callback signature (`RunScenario` type alias) is introduced once in Task 7 and used identically in Task 8's `main.py` wiring; `_persist_summary`/`_build_summary`/`_mark_running`/`_mark_completed` share the same `summary: dict[str, object]` shape from Task 4 through Task 7 without renaming.
