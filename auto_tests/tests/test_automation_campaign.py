import threading
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.models import AutomationCampaignRequest, OperationResult, StepResult
from app.services.automation_campaign import (
    CAMPAIGN_MILESTONES,
    SCENARIOS,
    STORAGE_SCENARIOS,
    read_interrupted_campaign_summary,
    run_campaign,
)
from app.services.automation_progress import OperationProgress
from app.stream_events import StreamEventProjector

from .campaign_evidence import successful_campaign_steps


def test_extended_campaign_preserves_oem_and_secondary_data_then_uninstalls(tmp_path: Path) -> None:
    names = ["legacy", "uefi-a", "uefi-b"]
    request = AutomationCampaignRequest(
        apply=True, linux_password="test-pass", include_storage_scenarios=True
    )
    calls = []
    events = []

    def run(child, workspace, publish):
        calls.append(child)
        assert child.verify_uninstall == (child.expected_compatibility_refusal is None)
        assert child.boot_guardian_fault == "none"
        assert child.monitor_iso
        steps = successful_campaign_steps(child)
        return OperationResult(status="ok", operation="automation", message="done", steps=steps)

    outcome = run_campaign(
        request,
        names,
        tmp_path,
        run,
        on_step=events.append,
        vm_firmwares={"legacy": "bios", "uefi-a": "uefi", "uefi-b": "uefi"},
    )
    assert outcome.status == "ok"
    plan = events[0]
    assert plan.step == "automation.campaign_plan"
    assert CAMPAIGN_MILESTONES.items() <= plan.context["milestones"].items()
    assert plan.context["independent_vms"] is True
    assert sum(len(item["vms"]) for item in plan.context["scenarios"]) == 42
    projector = StreamEventProjector("automation", tmp_path / "progress")
    assert projector.project_step(plan)["data"]["context"] == plan.context
    for milestone in CAMPAIGN_MILESTONES:
        step = StepResult(
            step=milestone,
            status="ok",
            message="completed",
            context={"vm": "legacy", "scenario": "mint-windows-first", "vm_status": "ok"},
        )
        assert projector.project_step(step) is not None
    failed = StepResult(
        step="automation.vm_finished",
        status="error",
        message="failed",
        context={"vm": "uefi-a", "scenario": "mint-windows-first", "vm_status": "error"},
    )
    assert projector.project_step(failed)["data"]["status"] == "error"
    assert len(calls) == 3 * (len(SCENARIOS) + len(STORAGE_SCENARIOS)) == 42
    assert all(len(child.vms) == 1 for child in calls)
    nominal = [child for child in calls if child.snapshot_mode == "default"]
    storage = [child for child in calls if child.snapshot_mode == "secondary-disk"]
    assert len(nominal) == 12
    assert len(storage) == 30
    for name in names:
        assert [
            (child.distribution, child.first_boot) for child in nominal if child.vms == [name]
        ] == list(SCENARIOS)
    for child in storage:
        assert child.snapshot_mode == "secondary-disk"
        assert child.storage_fixture.secondary_data
        assert child.storage_fixture.decrypt_secondary_volume
        assert child.storage_fixture.decrypt_system_volume
        assert child.storage_fixture.redirect_documents
    oem = [child for child in storage if child.installation_target == "windows"]
    assert len(oem) == 18
    assert {
        (child.distribution, child.storage_fixture.extra_system_partition) for child in oem
    } == {
        (distribution, layout)
        for distribution in ("mint", "zorin")
        for layout in ("fat32", "ntfs", "recovery")
    }
    negative = [child for child in oem if child.vms == ["legacy"]]
    assert len(negative) == 6
    assert all(
        child.expected_compatibility_refusal == "COMPAT_E_MBR_PRIMARY_LIMIT"
        and not child.verify_uninstall
        for child in negative
    )
    assert all(
        child.expected_compatibility_refusal is None and child.verify_uninstall
        for child in oem
        if child.vms != ["legacy"]
    )
    secondary = [child for child in storage if child.installation_target == "secondary"]
    assert len(secondary) == 12
    assert {(child.distribution, child.first_boot) for child in secondary} == set(SCENARIOS)
    assert all(
        child.verify_uninstall and child.expected_compatibility_refusal is None
        for child in secondary
    )
    assert all(child.storage_fixture.extra_system_partition == "recovery" for child in secondary)
    assert len(read_interrupted_campaign_summary(tmp_path)) == 14


def test_extended_campaign_continues_all_scenarios_but_retains_early_errors(tmp_path: Path) -> None:
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="test-pass",
        include_storage_scenarios=True,
        continue_after_failure=True,
    )
    calls = []

    def run(child, workspace, publish):
        calls.append((child.vms[0], workspace.parents[1].name))
        failed = child.vms == ["vm2"] and workspace.parents[1].name in {
            "mint-linux-first",
            "mint-windows-first-ntfs",
        }
        steps = successful_campaign_steps(child)
        steps[-1].context["vm_status"] = "error" if failed else "ok"
        return OperationResult(
            status="error" if failed else "ok",
            operation="automation",
            message="done",
            steps=steps,
        )

    outcome = run_campaign(
        request,
        ["vm1", "vm2", "vm3"],
        tmp_path,
        run,
        vm_firmwares={"vm1": "bios", "vm2": "uefi", "vm3": "uefi"},
    )
    assert len(calls) == 42
    assert outcome.status == "error"
    assert [entry["status"] for entry in outcome.campaign_summary].count("error") == 2
    assert all(entry["status"] != "not-run" for entry in outcome.campaign_summary)


def test_storage_campaign_refuses_unknown_firmware_before_any_run(tmp_path: Path) -> None:
    request = AutomationCampaignRequest(
        apply=True, linux_password="test-pass", include_storage_scenarios=True
    )
    with pytest.raises(ValueError, match="configured firmware"):
        run_campaign(request, ["a", "b", "c"], tmp_path, lambda *_: pytest.fail())


@pytest.mark.parametrize("continue_after_failure", [False, True])
def test_campaign_runs_four_nominal_three_vm_scenarios_and_retains_failures(
    tmp_path: Path, continue_after_failure: bool
) -> None:
    request = AutomationCampaignRequest(
        apply=True,
        linux_password="private-test-password",
        continue_after_failure=continue_after_failure,
    )
    calls = []
    names = ["vm1", "vm2", "vm3"]

    def run(child, workspace, publish):
        vm = child.vms[0]
        calls.append((vm, child.distribution, child.first_boot, child.verify_uninstall))
        assert len(child.vms) == 1 and vm in names
        assert child.boot_guardian_fault == "none"
        assert child.snapshot_mode == "default"
        assert child.monitor_iso is True
        assert workspace.parents[2] == tmp_path
        assert workspace.parent.name == vm
        failed = vm == "vm2" and (child.distribution, child.first_boot) == SCENARIOS[1]
        steps = successful_campaign_steps(child)
        steps[-1].context["vm_status"] = "error" if failed else "ok"
        for step in steps:
            publish(step)
        if failed:
            error = StepResult(
                step="test.failure", status="error", message="expected", context={"vm": "vm2"}
            )
            publish(error)
            steps.append(error)
        return OperationResult(
            status="error" if failed else "ok",
            operation="automation",
            message="done",
            steps=steps,
        )

    outcome = run_campaign(request, names, tmp_path, run)
    for name in names:
        expected = [
            (name, distribution, first_boot, True)
            for distribution, first_boot in (
                SCENARIOS if continue_after_failure or name != "vm2" else SCENARIOS[:2]
            )
        ]
        assert [call for call in calls if call[0] == name] == expected
    assert outcome.status == "error"
    assert len(outcome.campaign_summary) == 4
    assert outcome.campaign_summary[1]["vms"]["vm2"] == "error"
    assert outcome.campaign_summary[1]["cells"]["vm2"]["errors"][0]["message"] == "expected"
    for item in outcome.campaign_summary:
        for cell in item["cells"].values():
            if cell["status"] != "not-run":
                assert Path(cell["log"]).is_file()
                assert request.linux_password not in Path(cell["log"]).read_text()
    rendered = StreamEventProjector.render(
        {"event": "result", "data": {**outcome.model_dump(), "detailed_log": "campaign.log"}},
        stream_format="compact",
    )
    assert rendered.count("SCENARIO ") == 4
    assert "RESULT ERROR" in rendered


def test_campaign_requires_three_distinct_vms_before_any_run(tmp_path: Path) -> None:
    request = AutomationCampaignRequest(apply=True, linux_password="test-pass")
    with pytest.raises(ValueError, match="three distinct"):
        run_campaign(request, ["vm1", "vm1", "vm2"], tmp_path, lambda *_args: pytest.fail())


@pytest.mark.parametrize("raises", [False, True])
def test_campaign_does_not_claim_success_without_vm_verdicts(tmp_path: Path, raises: bool) -> None:
    request = AutomationCampaignRequest(apply=True, linux_password="test-pass")

    def run(*_args):
        if raises:
            raise RuntimeError("private diagnostic not to expose")
        return OperationResult(status="ok", operation="automation", message="incomplete")

    outcome = run_campaign(request, ["vm1", "vm2", "vm3"], tmp_path, run)
    assert outcome.status == "error"
    assert outcome.campaign_summary[0]["status"] == "error"
    assert all(item["status"] == "not-run" for item in outcome.campaign_summary[1:])
    assert "private diagnostic" not in outcome.model_dump_json()


def test_campaign_rejects_reserved_account_and_missing_consent() -> None:
    with pytest.raises(ValidationError):
        AutomationCampaignRequest(linux_password="test-pass")
    with pytest.raises(ValidationError):
        AutomationCampaignRequest(apply=True, linux_username="root", linux_password="test-pass")


def test_campaign_preserves_a_recap_when_the_worker_is_interrupted(tmp_path: Path) -> None:
    request = AutomationCampaignRequest(apply=True, linux_password="test-pass")
    calls = []
    barrier = threading.Barrier(3)

    def run(child, workspace, publish):
        vm = child.vms[0]
        calls.append((vm, child.first_boot))
        if child.first_boot == "windows":
            barrier.wait(timeout=5)
            if vm == "vm1":
                steps = successful_campaign_steps(child)
                for step in steps:
                    publish(step)
                return OperationResult(
                    status="ok", operation="automation", message="verified", steps=steps
                )
        publish(
            StepResult(step="automation.deploy", status="ok", message="started", context={"vm": vm})
        )
        raise SystemExit(1)

    with pytest.raises(SystemExit):
        run_campaign(request, ["vm1", "vm2", "vm3"], tmp_path, run)
    summary = read_interrupted_campaign_summary(tmp_path)
    assert len(calls) == 4
    assert summary[0]["status"] == "interrupted"
    assert summary[0]["vms"] == {
        "vm1": "ok",
        "vm2": "interrupted",
        "vm3": "interrupted",
    }
    assert summary[1]["vms"] == {"vm1": "interrupted", "vm2": "not-run", "vm3": "not-run"}
    assert all(item["status"] == "not-run" for item in summary[2:])
    for item in summary[:2]:
        for vm, cell in item["cells"].items():
            assert cell["status"] == item["vms"][vm]
            if cell["status"] != "not-run":
                assert Path(cell["log"]).is_file()


def test_progress_tracks_repeated_checks_in_each_campaign_scenario() -> None:
    progress = OperationProgress(0)
    for number, scenario in enumerate(("mint-windows-first", "mint-linux-first"), 1):
        step = StepResult(
            step="test.check", status="ok", message="same check", context={"scenario": scenario}
        )
        assert progress.observe(step, number)
        assert not progress.observe(step, number + 0.1)
    assert progress.oldest() == ("global", 2)
