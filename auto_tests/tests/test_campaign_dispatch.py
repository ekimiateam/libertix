from __future__ import annotations

import json
import threading
from pathlib import Path, PurePosixPath, PureWindowsPath

import pytest
from pydantic import ValidationError

import app.services.campaign_dispatch as campaign_dispatch_module
from app.config import VMConfig
from app.errors import WorkflowError
from app.models import AutomationCampaignRequest, OperationResult, StepResult
from app.services.campaign_dispatch import (
    FORMAT_VERSION,
    SCENARIO_MATRIX,
    CampaignDispatcher,
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
from app.stream_events import StreamEventProjector


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
        ("mint", "windows"),
        ("mint", "linux"),
        ("zorin", "windows"),
        ("zorin", "linux"),
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


def test_scenario_matrix_ids_are_unique() -> None:
    # Defensive, module-level: a future edit that accidentally reuses a
    # scenario id would otherwise silently create duplicate ScenarioRuns
    # with identical run_ids at expansion time.
    ids = [spec.id for spec in SCENARIO_MATRIX]
    assert len(ids) == len(set(ids))


def test_automation_campaign_request_rejects_duplicate_scenario_ids() -> None:
    with pytest.raises(ValidationError, match="Duplicate scenario_ids"):
        AutomationCampaignRequest(
            apply=True,
            linux_password="test-passphrase",
            scenario_ids=["mint-windows-first", "mint-windows-first"],
        )


def _settings_with_vms(*vm_overrides: dict) -> object:
    from tests.test_core import settings

    # Settings requires distinct, allow-listed vmids across configured VMs; the
    # shared _vm() helper defaults every VM to the same vmid, so assign unique
    # ones here (settings()'s default allowed_proxmox_vmids is (500, 501, 502)).
    vms = tuple(
        _vm(**{"vmid": 500 + index, **overrides}) for index, overrides in enumerate(vm_overrides)
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
        "mint-windows-first",
        "mint-linux-first",
        "zorin-windows-first",
        "zorin-linux-first",
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
            run_id="x::p",
            scenario_id="x",
            profile="p",
            vm="a",
            outcome="passed",
            reason=None,
            message="ok",
            errors=[],
            steps=[],
            log="log.txt",
            captures="captures",
            claimed_at="2026-09-21T00:00:00Z",
            finished_at="2026-09-21T00:01:00Z",
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


def _fake_validation_service_class():
    """A `ValidationService` stand-in with no real SSH/I/O, for
    `CampaignDispatcher` tests.

    `.calls` records every `prepare_server()`/`to_windows_share_path()`
    invocation so a test can assert the design spec's build-once contract:
    `CampaignDispatcher.run()` must call each exactly once per campaign run,
    never once per worker or once per resolved `ScenarioRun`.
    """

    calls: list[str] = []
    posix_path = PurePosixPath("/srv/libertix-smb/Libertix-release/Libertix.exe")
    windows_path = PureWindowsPath("Z:/Libertix-release/Libertix.exe")

    class _FakeValidationService:
        def __init__(self, configured: object) -> None:
            self._configured = configured

        def prepare_server(self, result, *, source: str) -> PurePosixPath:
            calls.append("prepare_server")
            result.ok("server.check_smb", "The SMB share is accessible", target="fake-host")
            return posix_path

        def to_windows_share_path(self, path: PurePosixPath) -> PureWindowsPath:
            calls.append("to_windows_share_path")
            return windows_path

    _FakeValidationService.calls = calls  # type: ignore[attr-defined]
    return _FakeValidationService


def _fake_run_scenario_always_ok():
    # (vm_name, distribution, first_boot): distribution alone collapses the two
    # nominal scenarios per distribution (windows-first vs linux-first) into
    # one key, which would make a "no run claimed twice" uniqueness check
    # meaningless -- first_boot is required to identify a run uniquely.
    calls: list[tuple[str, str, str]] = []

    def run(child, workspace, publish, windows_path):
        vm_name = child.vms[0]
        calls.append((vm_name, child.distribution, child.first_boot))
        step = StepResult(
            step="automation.vm_finished",
            status="ok",
            message="done",
            context={"vm": vm_name, "vm_status": "ok"},
        )
        publish(step)
        return OperationResult(status="ok", operation="automation", message="done", steps=[step])

    run.calls = calls  # type: ignore[attr-defined]
    return run


def test_campaign_dispatcher_final_result_includes_tagged_scenario_steps(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Regression: _aggregate_result() used to hardcode steps=[], silently
    dropping every scenario step from the non-stream /api/v1/automation/full
    response. The old sequential run_campaign() returned every tagged step;
    the dispatcher must preserve that."""

    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
    ).model_copy(update={"scenario_ids": ["mint-windows-first"]})
    run_scenario = _fake_run_scenario_always_ok()

    result = CampaignDispatcher(configured).run(request, run_scenario, tmp_path, on_step=None)

    assert result.status == "ok"
    scenario_steps = [step for step in result.steps if step.step == "automation.vm_finished"]
    assert scenario_steps
    assert scenario_steps[0].context["scenario"] == "mint-windows-first"


def test_campaign_dispatcher_build_once_progress_reaches_on_step_and_result(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The build-once phase (prepare_server) must stream through the real
    on_step callback and land in the final OperationResult.steps, untagged
    with any scenario -- it's campaign-global, not per-run."""

    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
    ).model_copy(update={"scenario_ids": ["mint-windows-first"]})
    run_scenario = _fake_run_scenario_always_ok()

    streamed: list[StepResult] = []
    result = CampaignDispatcher(configured).run(
        request, run_scenario, tmp_path, on_step=streamed.append
    )

    assert any(step.step == "server.check_smb" for step in streamed)
    build_steps = [step for step in result.steps if step.step == "server.check_smb"]
    assert build_steps
    assert "scenario" not in build_steps[0].context


def test_campaign_dispatcher_unknown_scenario_id_returns_failure_result_not_raise(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A pre-dispatch WorkflowError (unknown scenario_ids, a VM filter
    dropping required coverage, a disabled selected VM, or a build/SSH
    failure) must become a proper failure OperationResult with on_step
    notified -- not propagate uncaught, which would otherwise be turned
    into a generic automation.internal_error by the caller."""

    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
    ).model_copy(update={"scenario_ids": ["not-a-real-scenario"]})

    streamed: list[StepResult] = []
    result = CampaignDispatcher(configured).run(
        request, _fake_run_scenario_always_ok(), tmp_path, on_step=streamed.append
    )

    assert result.status == "error"
    assert result.steps
    assert result.steps[-1].step == "campaign.unknown_scenario_id"
    assert streamed  # on_step was notified of the failure
    assert streamed[-1].step == "campaign.unknown_scenario_id"


def test_campaign_dispatcher_post_claim_setup_failure_becomes_terminal_failed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A setup/construction failure after a claim has already been acked
    (e.g. workspace mkdir) must still produce exactly one terminal
    "completed" event -- the run must end up failed, never stuck at
    "running" forever -- and worker_done must still arrive exactly once
    so the dispatcher terminates."""

    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )

    real_mkdir = Path.mkdir

    def flaky_mkdir(self: Path, *args: object, **kwargs: object) -> None:
        if "scenarios" in self.parts:
            raise OSError("disk full")
        return real_mkdir(self, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", flaky_mkdir)

    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
    ).model_copy(update={"scenario_ids": ["mint-windows-first"]})
    run_scenario = _fake_run_scenario_always_ok()

    completed = threading.Event()
    outcome: dict[str, object] = {}

    def target() -> None:
        outcome["result"] = CampaignDispatcher(configured).run(
            request, run_scenario, tmp_path, on_step=None
        )
        completed.set()

    thread = threading.Thread(target=target)
    thread.start()
    thread.join(timeout=5)

    assert completed.is_set(), "CampaignDispatcher.run() hung -- worker_done not guaranteed"
    result = outcome["result"]
    assert result.status == "error"
    statuses = {entry["status"] for entry in result.campaign_summary}
    assert statuses == {"failed"}
    assert run_scenario.calls == []  # run_scenario itself was never reached


def test_campaign_dispatcher_runs_every_resolved_run_exactly_once(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    fake_validation = _fake_validation_service_class()
    monkeypatch.setattr("app.services.campaign_dispatch.ValidationService", fake_validation)
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
    # Design spec: prepare_server()/to_windows_share_path() are each called
    # exactly once per campaign run, regardless of how many ScenarioRuns (12
    # here, across 3 concurrent worker threads) the campaign resolves to.
    assert fake_validation.calls == ["prepare_server", "to_windows_share_path"]


def test_campaign_dispatcher_two_vms_sharing_a_profile_compete_for_the_same_runs(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 11 UEFI", "firmware": "uefi", "automation_enabled": True},
        {"name": "b", "os": "Windows 11 UEFI", "firmware": "uefi", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
    )
    request = request.model_copy(
        update={"scenario_ids": ["mint-windows-first", "mint-linux-first"]}
    )
    run_scenario = _fake_run_scenario_always_ok()
    result = CampaignDispatcher(configured).run(request, run_scenario, tmp_path, on_step=None)
    assert result.status == "ok"
    assert len(run_scenario.calls) == 2  # 2 scenarios x 1 profile, split across 2 competing VMs
    claimed_vms = {vm for vm, _distribution, _first_boot in run_scenario.calls}
    assert claimed_vms  # at least one of the two VMs claimed work; both are eligible


def test_campaign_dispatcher_claim_respects_capability_not_just_profile_string(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )
    configured = _settings_with_vms(
        {
            "name": "with-secondary",
            "os": "Windows 11 UEFI",
            "firmware": "uefi",
            "automation_enabled": True,
            "secondary_disk_boot_order": ("scsi1",),
        },
        {
            "name": "without-secondary",
            "os": "Windows 11 UEFI",
            "firmware": "uefi",
            "automation_enabled": True,
            "secondary_disk_boot_order": (),
        },
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
    ).model_copy(update={"scenario_ids": ["mint-secondary-install"]})
    run_scenario = _fake_run_scenario_always_ok()
    result = CampaignDispatcher(configured).run(request, run_scenario, tmp_path, on_step=None)
    assert result.status == "ok"
    assert run_scenario.calls == [("with-secondary", "mint", "windows")]


def test_campaign_dispatcher_continue_after_failure_false_stops_new_claims(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
        continue_after_failure=False,
    ).model_copy(update={"scenario_ids": ["mint-windows-first", "mint-linux-first"]})

    def run(child, workspace, publish, windows_path):
        step = StepResult(
            step="automation.installer_crash",
            status="error",
            message="boom",
            context={},
        )
        publish(step)
        return OperationResult(status="error", operation="automation", message="boom", steps=[step])

    result = CampaignDispatcher(configured).run(request, run, tmp_path, on_step=None)
    assert result.status == "error"
    statuses = {entry["status"] for entry in result.campaign_summary}
    assert "stopped-after-failure" in statuses
    assert "failed" in statuses


def test_campaign_dispatcher_restore_failure_quarantines_worker_not_whole_campaign(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
        {"name": "b", "os": "Windows 10 UEFI", "firmware": "uefi", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
        continue_after_failure=True,
    ).model_copy(update={"scenario_ids": ["mint-windows-first", "mint-linux-first"]})

    def run(child, workspace, publish, windows_path):
        if child.vms[0] == "a":
            step = StepResult(
                step="automation.rollback_preflight",
                status="error",
                message="restore broke",
                context={},
            )
            publish(step)
            return OperationResult(
                status="error",
                operation="automation",
                message="restore broke",
                steps=[step],
            )
        step = StepResult(
            step="automation.vm_finished",
            status="ok",
            message="done",
            context={"vm": "b", "vm_status": "ok"},
        )
        publish(step)
        return OperationResult(status="ok", operation="automation", message="done", steps=[step])

    result = CampaignDispatcher(configured).run(request, run, tmp_path, on_step=None)
    entries = {
        entry["scenario_id"] + "::" + entry["profile"]: entry for entry in result.campaign_summary
    }
    assert entries["mint-windows-first::Windows 10 BIOS"]["status"] == "retryable"
    assert entries["mint-windows-first::Windows 10 UEFI"]["status"] == "passed"
    assert entries["mint-linux-first::Windows 10 UEFI"]["status"] == "passed"


def test_campaign_dispatcher_worker_done_reported_on_every_exit_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """No compatible worker at all -> dispatcher must still terminate, not hang."""

    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
    ).model_copy(update={"scenario_ids": ["mint-windows-first"]})
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
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Regression test for the queue-latency race: a worker must set stop_claiming
    itself, synchronously, at classification time -- not rely on the consumer."""

    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )
    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
        continue_after_failure=False,
    ).model_copy(update={"scenario_ids": ["mint-windows-first", "mint-linux-first"]})
    claim_order: list[str] = []

    def run(child, workspace, publish, windows_path):
        claim_order.append(child.first_boot)
        step = StepResult(
            step="automation.installer_crash",
            status="error",
            message="boom",
            context={},
        )
        publish(step)
        return OperationResult(status="error", operation="automation", message="boom", steps=[step])

    CampaignDispatcher(configured).run(request, run, tmp_path, on_step=None)
    # Only the single VM in the pool exists, so it can claim at most one run before
    # the failure it just produced must stop it from claiming the second.
    assert len(claim_order) == 1


def test_campaign_dispatcher_project_result_failure_does_not_change_outcome(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A logging/persistence I/O fault while writing the detailed scenario
    log must never override the classified outcome: run_scenario() and
    _classify() are the sole source of truth for pass/fail, and a
    "completed" message must still be sent."""

    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )

    def broken_project_result(self, result):
        raise OSError("disk full")

    monkeypatch.setattr(StreamEventProjector, "project_result", broken_project_result)

    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
    ).model_copy(update={"scenario_ids": ["mint-windows-first"]})
    run_scenario = _fake_run_scenario_always_ok()

    result = CampaignDispatcher(configured).run(request, run_scenario, tmp_path, on_step=None)

    assert result.status == "ok"
    statuses = {entry["status"] for entry in result.campaign_summary}
    assert statuses == {"passed"}


def test_campaign_dispatcher_persist_summary_failure_still_unblocks_worker(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A _persist_summary failure while marking a run "claimed" must still
    unblock the worker's ack.wait() -- not hang it forever -- even though
    the original exception is allowed to propagate out of run()."""

    monkeypatch.setattr(
        "app.services.campaign_dispatch.ValidationService", _fake_validation_service_class()
    )

    real_persist_summary = campaign_dispatch_module._persist_summary
    call_count = {"n": 0}

    def flaky_persist_summary(workspace, summary):
        call_count["n"] += 1
        # Call 1 persists the freshly built summary before any worker starts;
        # call 2 is the consumer's "claimed" write -- that is the one that
        # must fail here without leaving the worker stuck on ack.wait().
        if call_count["n"] == 2:
            raise OSError("disk full")
        return real_persist_summary(workspace, summary)

    monkeypatch.setattr(campaign_dispatch_module, "_persist_summary", flaky_persist_summary)

    configured = _settings_with_vms(
        {"name": "a", "os": "Windows 10 BIOS", "firmware": "bios", "automation_enabled": True},
    )
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-passphrase",
    ).model_copy(update={"scenario_ids": ["mint-windows-first"]})
    run_scenario = _fake_run_scenario_always_ok()

    outcome: dict[str, object] = {}

    def target() -> None:
        try:
            CampaignDispatcher(configured).run(request, run_scenario, tmp_path, on_step=None)
        except Exception as exc:  # noqa: BLE001 -- captured to assert on below
            outcome["exception"] = exc
        else:
            outcome["completed"] = True

    thread = threading.Thread(target=target)
    thread.start()
    thread.join(timeout=5)
    assert not thread.is_alive(), "CampaignDispatcher.run() hung -- ack.set() not guaranteed"
    assert isinstance(outcome.get("exception"), OSError)
