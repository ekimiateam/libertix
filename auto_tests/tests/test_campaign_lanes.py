import json
import multiprocessing
import os
import threading
import time
from collections import Counter
from contextlib import nullcontext
from pathlib import Path, PureWindowsPath
from types import SimpleNamespace

import pytest

from app import main
from app.errors import WorkflowError
from app.models import AutomationCampaignRequest, AutomationRequest, OperationResult, StepResult
from app.services.automation_campaign import run_campaign
from app.services.automation_wizard import WizardAutomationMixin
from app.services.common import ResultBuilder
from app.services.validation import ValidationService

from .test_core import settings


def finished(vm, status="ok"):
    return OperationResult(
        status=status,
        operation="automation",
        message=status,
        steps=[
            StepResult(
                step="automation.vm_finished",
                status="ok",
                message=status,
                context={"vm": vm, "vm_status": status},
            )
        ],
    )


def test_independent_42_cells_and_retry_budgets(tmp_path):
    release_slow = threading.Event()
    lock = threading.Lock()
    busy = set()
    calls = []
    counts = Counter()
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="testpass",
        include_storage_scenarios=True,
        continue_after_failure=True,
        retry_failed_scenarios=True,
    )

    def run(child, workspace, publish):
        vm = child.vms[0]
        key = (vm, workspace.parents[1].name)
        with lock:
            assert vm not in busy
            busy.add(vm)
            calls.append((child, workspace))
            counts[key] += 1
            iteration = counts[key]
        try:
            if key == ("a", "mint-windows-first"):
                assert release_slow.wait(5), "A slow VM prevented another VM from advancing"
            if key == ("c", "mint-linux-first"):
                release_slow.set()
            if key == ("b", "mint-windows-first") and iteration < 3:
                result = finished(vm, "error")
                result.steps.append(
                    StepResult(
                        step="automation.network.restart_required",
                        status="error",
                        message="synthetic bounded recovery probe",
                        context={
                            "restart_reason": "unknown_command_outcome"
                            if iteration == 1
                            else "prolonged_outage"
                        },
                    )
                )
                return result
            result = finished(vm)
            publish(result.steps[0])
            return result
        finally:
            with lock:
                busy.remove(vm)

    result = run_campaign(
        request,
        ["a", "b", "c"],
        tmp_path,
        run,
        vm_firmwares={"a": "bios", "b": "uefi", "c": "uefi"},
    )
    assert result.status == "ok"
    assert len(calls) == 44
    assert sum(bool(child.expected_compatibility_refusal) for child, _ in calls) == 6
    assert all(
        not child.verify_uninstall for child, _ in calls if child.expected_compatibility_refusal
    )
    assert all(
        child.verify_uninstall for child, _ in calls if not child.expected_compatibility_refusal
    )
    assert all(len(child.vms) == 1 for child, _ in calls)
    retry_cell = result.campaign_summary[0]["cells"]["b"]
    assert retry_cell["attempt"] == 2 and retry_cell["generation"] == 3
    assert [entry["attempt"] for entry in retry_cell["previous_attempts"]] == [1, 2]
    assert all(
        Path(cell["log"]).is_file()
        for row in result.campaign_summary
        for cell in row["cells"].values()
    )
    persisted = json.loads((tmp_path / "campaign-summary.json").read_text())
    assert persisted == result.campaign_summary
    assert len({str(path) for _, path in calls}) == 44


def spawned_probe_worker(
    configured,
    operation,
    selectors,
    request,
    sender,
    workspace,
    provenance=None,
    prepared_release=None,
    campaign_cell=False,
):
    def run(_configured, _operation, _selectors, request, on_step, _workspace, _release=None):
        vm = request.vms[0]
        if request.linux_username == "network":
            on_step(
                StepResult(
                    step="automation.network.restart_required",
                    status="ok",
                    message="Synthetic long outage",
                    context={"restart_reason": "prolonged_outage"},
                )
            )
            while True:
                time.sleep(1)
        if request.linux_username == "stall":
            while True:
                time.sleep(1)
        result = finished(vm)
        on_step(result.steps[0])
        return result

    main._run_operation = run
    main.vnc_api.shutdown = lambda: None
    main._stream_operation_worker(
        configured,
        operation,
        selectors,
        request,
        sender,
        workspace,
        provenance,
        prepared_release,
        campaign_cell,
    )


@pytest.mark.parametrize(
    "mode,expected", [("normal", "ok"), ("network", "error"), ("stall", "error")]
)
def test_real_spawn_worker_is_supervised(monkeypatch, tmp_path, mode, expected):
    assert multiprocessing.get_context("spawn").get_start_method() == "spawn"
    original_worker = main._stream_operation_worker
    # The child imports the original module; only its remote-operation body is substituted.
    monkeypatch.setattr(main, "_stream_operation_worker", spawned_probe_worker)
    manifest = tmp_path / "manifest.json"
    manifest.write_text(json.dumps({"status": "collected"}))
    monkeypatch.setattr(main, "_collect_timeout_diagnostics", lambda *args: {"vm1": str(manifest)})
    cfg = settings().model_copy(update={"automation_operation_timeout_seconds": 2})
    request = AutomationRequest(
        apply=True, vms=["vm1"], linux_password="testpass", linux_username=mode
    )
    events = []
    result = main._run_campaign_vm_attempt(
        cfg, request, tmp_path, events.append, ("Z:/Libertix-release/Libertix.exe", "a" * 64)
    )
    assert result.status == expected
    if mode == "network":
        assert any(s.step == "automation.network.vm_restart_required" for s in events)
        assert not any(s.step == "automation.network.restart_required" for s in events)
        assert any(s.context.get("restart_reason") == "prolonged_outage" for s in result.steps)
    if mode == "stall":
        assert any(s.step == "automation.inactivity_timeout" for s in result.steps)
    assert not multiprocessing.active_children()
    monkeypatch.setattr(main, "_stream_operation_worker", original_worker)


def orphan_parent(cfg, workspace):
    context = multiprocessing.get_context("spawn")
    receiver, sender = context.Pipe(duplex=False)
    request = AutomationRequest(
        apply=True, vms=["vm1"], linux_password="testpass", linux_username="stall"
    )
    worker = context.Process(
        target=spawned_probe_worker, args=(cfg, "automation", ["vm1"], request, sender, workspace)
    )
    worker.start()
    (workspace / "pid").write_text(str(worker.pid))
    deadline = time.monotonic() + 10
    while not (workspace / "runtime-provenance.json").exists():
        if time.monotonic() > deadline:
            os._exit(2)
        time.sleep(0.05)
    os._exit(0)


def test_worker_exits_after_parent_dies(tmp_path):
    parent = multiprocessing.get_context("spawn").Process(
        target=orphan_parent, args=(settings(), tmp_path)
    )
    parent.start()
    parent.join(15)
    assert parent.exitcode == 0
    pid = int((tmp_path / "pid").read_text())
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            stat = Path(f"/proc/{pid}/stat").read_text()
        except FileNotFoundError:
            return
        if stat.split(") ", 1)[1].split()[0] == "Z":
            return
        time.sleep(0.05)
    pytest.fail(f"VM worker {pid} survived its controller")


@pytest.mark.parametrize(
    "failure,changed,passes",
    [
        ("COMPAT_E_MBR_PRIMARY_LIMIT", False, True),
        ("COMPAT_E_NTFS_SCAN_FAILED", False, False),
        ("COMPAT_E_MBR_PRIMARY_LIMIT", True, False),
        ("no-refusal", False, False),
    ],
)
def test_refusal_never_acknowledges_a_mutating_stage(failure, changed, passes):
    baseline = {
        "SYSTEM_DISK_NUMBER": "0",
        "STORAGE_LAYOUT_JSON": json.dumps(
            [{"Number": 0, "PartitionStyle": "MBR", "Partitions": [{}, {}, {}, {}]}]
        ),
        "LEDGER": "absent",
    }
    observed = {**baseline, "LEDGER": "present"} if changed else dict(baseline)
    acks = []
    observed_stages = []

    def wait(ssh, vm, path, sequence, stages):
        observed_stages.extend(stages)
        if stages == ("failed",) and failure != "no-refusal":
            raise WorkflowError(
                "automation.unattended_failure",
                "test refusal",
                details={"stage": "failed", "error_code": failure},
            )
        return {"stage": stages[0], "sequence": sequence + 1}

    def ack(ssh, vm, result, path, status):
        acks.append(status["stage"])
        return status["sequence"]

    harness = SimpleNamespace(
        validation=SimpleNamespace(ssh=lambda *args, **kwargs: nullcontext(object())),
        settings=settings(),
        _wait_for_unattended_stage=wait,
        _capture_and_acknowledge_unattended_stage=ack,
        _capture_with_name=lambda *args: Path("refusal.png"),
        _capture_rollback_baseline=lambda *args, **kwargs: observed,
        _verify_windows_storage_fixture=lambda *args: None,
    )
    options = SimpleNamespace(
        rollback_baseline=baseline,
        installation_target="windows",
        expected_compatibility_refusal="COMPAT_E_MBR_PRIMARY_LIMIT",
        storage_fixture_receipt={},
    )
    vm = SimpleNamespace(firmware="bios", host="test", username="test", name="vm1")
    result = ResultBuilder("automation")

    def call():
        return WizardAutomationMixin._verify_compatibility_refusal(
            harness,
            vm,
            options,
            result,
            {
                "unattended_status_path": "status.json",
                "unattended_acknowledgement_path": "ack.json",
            },
        )

    if passes:
        call()
        assert [s.step for s in result.steps] == [
            "automation.compatibility_refusal",
            "automation.compatibility_unchanged",
        ]
    else:
        with pytest.raises(WorkflowError):
            call()
    assert acks == [
        "compatibility-running",
        "compatibility-passed",
        "configuration-distribution-applied",
    ]


def test_diagnostic_failure_does_not_replace_worker_failure(monkeypatch, tmp_path):
    monkeypatch.setattr(main, "_stream_operation_worker", spawned_probe_worker)

    def fail(*args):
        raise RuntimeError("synthetic collector failure")

    monkeypatch.setattr(main, "_collect_timeout_diagnostics", fail)
    result = main._run_campaign_vm_attempt(
        settings().model_copy(update={"automation_operation_timeout_seconds": 1}),
        AutomationRequest(
            apply=True, vms=["vm1"], linux_password="testpass", linux_username="stall"
        ),
        tmp_path,
        lambda step: None,
        ("release", "a" * 64),
    )
    assert result.status == "error"
    assert any(s.step == "automation.inactivity_timeout" for s in result.steps)
    diagnostic = next(s for s in result.steps if s.step == "automation.diagnostics.saved")
    assert diagnostic.status == "error" and diagnostic.context["collection_status"] == "incomplete"
    assert "synthetic collector failure" in diagnostic.context["manifests"]["vm1"]


@pytest.mark.parametrize("reported_hash", ["a" * 64, "b" * 64, ""])
def test_deployment_requires_the_frozen_executable_hash(monkeypatch, reported_hash):
    cfg = settings()
    service = ValidationService(cfg)
    vm = service.select_vms(["vm1"])[0]
    monkeypatch.setattr(service, "ssh", lambda *args, **kwargs: nullcontext(object()))
    deployments = []

    def deploy(_ssh, *, config, script_name, **kwargs):
        assert script_name == "deploy_libertix.ps1"
        assert config["expected_sha256"] == "a" * 64
        deployments.append(script_name)
        return SimpleNamespace(
            stdout=f"LOCAL_EXE=C:\\Test\\Libertix.exe\nLOCAL_EXE_SHA256={reported_hash}\n"
        )

    monkeypatch.setattr(service, "run_windows_script", deploy)
    events = []
    executable = PureWindowsPath("Z:/") / cfg.release_dir_name / "Libertix.exe"
    if reported_hash == "a" * 64:
        assert service.deploy_to_documents(
            vm, executable, expected_sha256="a" * 64, on_step=events.append
        ) == PureWindowsPath("C:/Test/Libertix.exe")
        assert len(events) == 1
        assert events[0].context["LOCAL_EXE_SHA256"] == reported_hash
    else:
        expected_error = (
            "differs from the campaign release" if reported_hash else "path was not confirmed"
        )
        with pytest.raises(WorkflowError, match=expected_error):
            service.deploy_to_documents(
                vm, executable, expected_sha256="a" * 64, on_step=events.append
            )
        assert events == []
    assert deployments == ["deploy_libertix.ps1"]


def test_campaign_refuses_sources_changed_since_server_start(monkeypatch, tmp_path):
    messages = []
    connection = SimpleNamespace(send=messages.append, close=lambda: None)
    monkeypatch.setattr(main.vnc_api, "shutdown", lambda: None)
    monkeypatch.setattr(
        main, "_run_operation", lambda *args: pytest.fail("A stale server started a campaign")
    )
    main._stream_operation_worker(
        settings(),
        "automation",
        ["vm1", "vm2", "vm3"],
        AutomationCampaignRequest(apply=True, linux_password="testpass"),
        connection,
        tmp_path,
        {"source_sha256_at_import": {"old-source": "old-hash"}},
    )
    assert len(messages) == 1 and messages[0][0] == "result"
    assert messages[0][1]["status"] == "error"
    provenance = json.loads((tmp_path / "runtime-provenance.json").read_text())
    assert (
        provenance["server"]["source_sha256_at_import"]
        != provenance["worker"]["source_sha256_at_import"]
    )
