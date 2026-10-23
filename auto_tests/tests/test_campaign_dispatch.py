from __future__ import annotations

import json
import threading
from collections import Counter

import pytest

from app import main
from app.models import AutomationCampaignRequest, OperationResult, StepResult
from app.services.automation_campaign import campaign_scenarios, run_campaign
from app.services.campaign_dispatch import CampaignDispatcher, preparation_failed, worker_profiles
from tools.campaign_client import CampaignProgress, validate_success

from .test_boot_guardian_campaign import recovery_steps
from .test_core import settings


def fleet():
    vms = list(settings().vms)
    vms.append(vms[1].model_copy(update={"name": "clone", "vmid": 503}))
    return vms


def success(child, workspace, publish):
    steps = recovery_steps(child)
    for step in steps:
        publish(step)
    return OperationResult(status="ok", operation="automation", message="done", steps=steps)


def campaign(tmp_path, runner=success, **options):
    vms = fleet()
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-pass",
        continue_after_failure=True,
        retry_failed_scenarios=True,
        **options,
    )
    return run_campaign(
        request,
        [vm.name for vm in vms],
        tmp_path,
        runner,
        vm_firmwares={vm.name: vm.firmware for vm in vms},
        vm_configs=vms,
    )


def test_profiles_require_both_windows_version_and_firmware():
    vms = fleet()
    assert worker_profiles(vms) == {
        "vm1": "vm1",
        "vm2": "vm2",
        "vm3": "vm3",
        "clone": "vm2",
    }
    vms[-1] = vms[-1].model_copy(update={"firmware": "bios"})
    assert worker_profiles(vms)["clone"] == "clone"


def test_all_22_scenarios_keep_their_56_required_cells(tmp_path):
    calls = Counter()
    busy = set()
    lock = threading.Lock()
    profiles = worker_profiles(fleet())

    def run(child, workspace, publish):
        vm = child.vms[0]
        with lock:
            assert vm not in busy
            busy.add(vm)
            calls[(workspace.parents[1].name, profiles[vm])] += 1
        try:
            return success(child, workspace, publish)
        finally:
            with lock:
                busy.remove(vm)

    result = campaign(
        tmp_path,
        run,
        include_storage_scenarios=True,
        include_boot_guardian_scenarios=True,
        include_local_filepool_scenarios=True,
    )
    assert result.status == "ok"
    assert len(result.campaign_summary) == 22
    assert len(calls) == 56
    assert set(calls.values()) == {1}
    scenarios = campaign_scenarios()
    assert [entry["scenario"] for entry in result.campaign_summary] == [
        scenario.name for scenario in scenarios
    ]
    assert sum(len(entry["cells"]) for entry in result.campaign_summary) == 56
    assert all(
        profiles[cell["worker"]] == representative
        for entry in result.campaign_summary
        for representative, cell in entry["cells"].items()
    )
    assert json.loads((tmp_path / "campaign-summary.json").read_text()) == result.campaign_summary


def test_two_clones_execute_different_scenarios_at_the_same_time(tmp_path):
    barrier = threading.Barrier(2)
    seen = set()
    lock = threading.Lock()

    def run(child, workspace, publish):
        vm = child.vms[0]
        if vm in {"vm2", "clone"}:
            with lock:
                first = vm not in seen
                seen.add(vm)
            if first:
                barrier.wait(timeout=5)
        return success(child, workspace, publish)

    assert campaign(tmp_path, run).status == "ok"
    assert seen == {"vm2", "clone"}


def test_preparation_is_retried_twice_before_another_clone_takes_over(tmp_path):
    calls = Counter()
    clone_started = threading.Event()
    failed_scenarios = set()

    def run(child, workspace, publish):
        vm = child.vms[0]
        calls[vm] += 1
        if vm == "vm2":
            failed_scenarios.add(workspace.parents[1].name)
            assert clone_started.wait(5)
            return OperationResult(
                status="error",
                operation="automation",
                message="snapshot unavailable",
                steps=[
                    StepResult(
                        step="proxmox.check_snapshot",
                        status="error",
                        message="snapshot unavailable",
                    )
                ],
            )
        if vm == "clone":
            clone_started.set()
        return success(child, workspace, publish)

    result = campaign(tmp_path, run)
    assert result.status == "ok"
    assert calls["vm2"] == 2
    assert len(failed_scenarios) == 1
    cell = next(
        entry["cells"]["vm2"]
        for entry in result.campaign_summary
        if entry["scenario"] in failed_scenarios
    )
    assert cell["worker"] == "clone"
    assert [attempt["status"] for attempt in cell["previous_attempts"]] == ["error", "error"]
    assert [attempt["attempt"] for attempt in cell["previous_attempts"]] == [1, 2]
    assert all(attempt["worker"] == "vm2" for attempt in cell["previous_attempts"])


def test_no_compatible_replacement_keeps_a_failed_campaign(tmp_path):
    def run(child, workspace, publish):
        if child.vms[0] in {"vm2", "clone"}:
            return OperationResult(
                status="error",
                operation="automation",
                message="network unavailable",
                steps=[
                    StepResult(
                        step="automation.guest_network_discovery",
                        status="error",
                        message="unavailable",
                    )
                ],
            )
        return success(child, workspace, publish)

    result = campaign(tmp_path, run)
    assert result.status == "error"
    assert any(entry["status"] == "error" for entry in result.campaign_summary)


def test_clones_without_matching_storage_setup_do_not_claim_storage_jobs(tmp_path):
    vms = fleet()
    vms[1] = vms[1].model_copy(
        update={
            "local_filepool_snapshot": "clean2-larger",
            "secondary_disk_boot_order": ("sata1",),
        }
    )
    clone_started = threading.Event()
    clone_jobs = []

    def run(child, workspace, publish):
        if child.vms == ["vm2"] and workspace.parents[1].name == "mint-windows-first":
            assert clone_started.wait(5)
        if child.vms == ["clone"]:
            clone_started.set()
            clone_jobs.append(child)
        return success(child, workspace, publish)

    result = run_campaign(
        AutomationCampaignRequest(
            apply=True,
            linux_password="test-pass",
            include_storage_scenarios=True,
            include_local_filepool_scenarios=True,
        ),
        [vm.name for vm in vms],
        tmp_path,
        run,
        vm_firmwares={vm.name: vm.firmware for vm in vms},
        vm_configs=vms,
    )
    assert result.status == "ok"
    assert clone_jobs
    assert all(not child.local_filepool for child in clone_jobs)
    assert all(child.snapshot_mode == "default" for child in clone_jobs)


def test_real_validation_failure_is_not_handed_to_another_clone(tmp_path):
    calls = Counter()

    def run(child, workspace, publish):
        scenario = workspace.parents[1].name
        profile = worker_profiles(fleet())[child.vms[0]]
        calls[(scenario, profile)] += 1
        if scenario == "mint-windows-first" and profile == "vm2":
            return OperationResult(
                status="error",
                operation="automation",
                message="Windows check failed",
                steps=[
                    StepResult(
                        step="automation.test.windows",
                        status="error",
                        message="Windows check failed",
                    )
                ],
            )
        return success(child, workspace, publish)

    result = campaign(tmp_path, run)
    assert result.status == "error"
    assert calls[("mint-windows-first", "vm2")] == 2
    assert not any(step.step == "automation.campaign_worker_quarantined" for step in result.steps)


@pytest.mark.parametrize(
    "steps",
    [
        [StepResult(step="automation.test.windows", status="error", message="failed")],
        [
            StepResult(step="automation.rollback_preflight", status="error", message="failed"),
            StepResult(step="automation.test.windows", status="error", message="failed"),
        ],
    ],
)
def test_validation_errors_never_count_as_preparation_failures(steps):
    result = OperationResult(status="error", operation="automation", message="failed", steps=steps)
    assert not preparation_failed(result)


def test_ssh_failure_after_deployment_is_not_a_preparation_failure():
    result = OperationResult(
        status="error",
        operation="automation",
        message="SSH failed",
        steps=[
            StepResult(step="automation.deploy", status="ok", message="deployed"),
            StepResult(step="ssh.connect", status="error", message="SSH failed"),
        ],
    )
    assert not preparation_failed(result)


def test_peer_waits_for_a_job_returned_after_preparation_failure():
    job = (0, "profile")
    dispatcher = CampaignDispatcher({job: {"a", "b"}})
    assert dispatcher.claim("a") == job
    claimed = []
    started = threading.Event()

    def peer():
        started.set()
        claimed.append(dispatcher.claim("b"))

    thread = threading.Thread(target=peer)
    thread.start()
    assert started.wait(5)
    assert dispatcher.finish("a", quarantine=True)
    thread.join(timeout=5)
    assert not thread.is_alive()
    assert claimed == [job]
    assert not dispatcher.finish("b")
    assert dispatcher.claim("b") is None


def test_retiring_a_crashed_worker_releases_waiting_peers():
    dispatcher = CampaignDispatcher({(0, "profile"): {"a", "b"}})
    dispatcher.claim("a")
    claimed = []
    thread = threading.Thread(target=lambda: claimed.append(dispatcher.claim("b")))
    thread.start()
    dispatcher.retire("a")
    thread.join(timeout=5)
    assert not thread.is_alive()
    assert claimed == [None]


def test_client_checks_profiles_and_rejects_a_foreign_worker(tmp_path):
    result = campaign(tmp_path)
    vms = fleet()
    profiles = worker_profiles(vms)
    payload = {"vms": [vm.name for vm in vms]}
    scenarios = campaign_scenarios(storage=False, boot_guardian=False, local_filepool=False)
    firmwares = {vm.name: vm.firmware for vm in vms}
    data = result.model_dump(mode="json")
    validate_success(data, payload, scenarios, firmwares, profiles)
    data["campaign_summary"][0]["cells"]["vm2"]["worker"] = "vm1"
    with pytest.raises(RuntimeError, match="inconsistent VM results"):
        validate_success(data, payload, scenarios, firmwares, profiles)


def test_progress_counts_a_clone_against_its_required_profile(tmp_path, capsys):
    events = []
    vms = fleet()
    result = run_campaign(
        AutomationCampaignRequest(apply=True, linux_password="test-pass"),
        [vm.name for vm in vms],
        tmp_path,
        success,
        events.append,
        vm_firmwares={vm.name: vm.firmware for vm in vms},
        vm_configs=vms,
    )
    progress = CampaignProgress(settings(), [vm.name for vm in vms])
    for step in events:
        progress.observe_step(step.model_dump(mode="json"))
    expected = sum(
        len(item["vm_milestones"][vm]) for item in progress.scenarios for vm in item["vms"]
    )
    assert result.status == "ok"
    assert len(progress.completed) == expected
    progress.print()
    assert "100.0%" in capsys.readouterr().out


def test_campaign_keeps_one_build_hash_and_one_controller_per_run(tmp_path, monkeypatch):
    configured = settings().model_copy(update={"vms": tuple(fleet())})
    builds = []
    controllers = []
    release = ("Z:/release/Libertix.exe", "a" * 64)

    def prepare(configured, source, workspace, on_step):
        builds.append(source)
        return release

    def run(configured, child, workspace, publish, prepared_release):
        assert prepared_release == release
        assert (
            configured.proxmox_storage_min_free_gib
            >= 4 * configured.proxmox_storage_min_free_per_vm_gib
        )
        controllers.append(child.vms)
        return success(child, workspace, publish)

    monkeypatch.setattr(main, "_prepare_campaign_release", prepare)
    monkeypatch.setattr(main, "_run_campaign_vm_attempt", run)
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-pass",
        vms=[vm.name for vm in fleet()],
    )
    result = main._run_operation(
        configured,
        "automation",
        request.selectors(),
        request,
        run_workspace=tmp_path,
    )
    assert result.status == "ok"
    assert len(builds) == 1
    assert len(controllers) == 12
    assert all(len(vms) == 1 for vms in controllers)


def test_timeout_diagnostics_follow_the_actual_clone(tmp_path, monkeypatch):
    configured = settings().model_copy(update={"vms": tuple(fleet())})
    (tmp_path / "campaign-summary.json").write_text(
        json.dumps(
            [
                {
                    "scenario": "mint-windows-first",
                    "status": "running",
                    "vms": {"vm2": "running"},
                    "cells": {
                        "vm2": {
                            "status": "running",
                            "worker": "clone",
                            "log": str(tmp_path / "clone.log"),
                        }
                    },
                },
            ]
            * 4
        )
    )
    collected = []

    def collect(configured, vm, *args):
        collected.append(vm.name)
        return tmp_path / "manifest.json"

    monkeypatch.setattr(main, "collect_failure_diagnostics", collect)
    result = main._collect_timeout_diagnostics(
        configured,
        [vm.name for vm in fleet()],
        AutomationCampaignRequest(apply=True, linux_password="test-pass"),
        tmp_path,
        StepResult(step="automation.inactivity_timeout", status="error", message="timeout"),
    )
    assert collected == ["clone"] * 4
    assert set(result) == {"clone"}
