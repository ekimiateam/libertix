from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.config import VMConfig
from app.errors import WorkflowError
from app.models import AutomationCampaignRequest, OperationResult, StepResult
from app.services.campaign_dispatch import (
    FORMAT_VERSION,
    SCENARIO_MATRIX,
    ScenarioRequirements,
    ScenarioRun,
    ScenarioRunResult,
    ScenarioSpec,
    _build_summary,
    _classify,
    _counts,
    _expand_runs,
    _fleet_profiles,
    _mark_completed,
    _mark_running,
    _persist_summary,
    _resolve_specs,
    _resolve_worker_pool,
    _vm_compatible,
    read_interrupted_campaign_summary,
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


def _settings_with_vms(*vm_overrides: dict) -> object:
    from tests.test_core import settings

    # Settings requires distinct, allow-listed vmids across configured VMs; the
    # shared _vm() helper defaults every VM to the same vmid, so assign unique
    # ones here (settings()'s default allowed_proxmox_vmids is (500, 501, 502)).
    vms = tuple(
        _vm(**{"vmid": 500 + index, **overrides})
        for index, overrides in enumerate(vm_overrides)
    )
    return settings(vms=vms)


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


def test_classify_returns_failed_for_error_status_with_no_error_steps() -> None:
    # Matches a real construction site: main.py's "another operation is
    # already running" result is status="error" with steps=[].
    result = OperationResult(
        status="error",
        operation="automation",
        message="error: another operation is already running",
        steps=[],
    )
    assert _classify(result, "vm1") == ("failed", None)


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


def test_read_interrupted_campaign_summary_fails_safe_on_non_string_status(
    tmp_path: Path,
) -> None:
    (tmp_path / "campaign-summary.json").write_text(
        json.dumps(
            {
                "format_version": FORMAT_VERSION,
                "resolved": {},
                "requested": {},
                "runs": [
                    {
                        "run_id": "x::p",
                        "scenario_id": "x",
                        "profile": "p",
                        "vm": None,
                        "status": 1,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    assert read_interrupted_campaign_summary(tmp_path) == []
