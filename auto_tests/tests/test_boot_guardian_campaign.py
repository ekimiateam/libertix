"""Campaign routing and evidence contracts; these tests do not operate real VMs."""

import ast
import json
import threading
from collections import Counter
from pathlib import Path

import pytest

from app.models import AutomationCampaignRequest, AutomationRequest, OperationResult, StepResult
from app.services.automation_campaign import (
    BOOT_GUARDIAN_SCENARIOS,
    LOCAL_FILEPOOL_SCENARIOS,
    SCENARIOS,
    STORAGE_SCENARIOS,
    missing_campaign_evidence,
    read_interrupted_campaign_summary,
    run_campaign,
)

from .campaign_evidence import successful_campaign_steps

MODES = ("boot-order", "preferred-path", "preferred-path-rollback")
FIRMWARES = {"vm1": "bios", "vm2": "uefi", "vm3": "uefi"}
RUNNER = Path(__file__).resolve().parents[1] / "RUN/run-test-auto.sh"


def recovery_steps(child):
    mode = child.boot_guardian_fault
    if mode == "none":
        return successful_campaign_steps(child)
    if mode == "preferred-path-rollback":
        events = [
            "automation.prepare_vm",
            "automation.deploy",
            "automation.reboot_requested",
            "automation.installed_boot_menu_seen",
            "windows.waiting_for_linux",
            "windows.linux_reboot",
            "automation.preferred_path_bypass.plan",
            "automation.preferred_path_bypass.inject",
            "automation.preferred_path_rollback.requested",
            "automation.preferred_path_rollback.verify",
            "automation.vm_finished",
        ]
        steps = []
    else:
        steps = [
            step
            for step in successful_campaign_steps(child)
            if not step.step.startswith("automation.installed_linux_uninstall.")
        ]
        events = [
            "automation.boot_guardian_shutdown.stopped",
            "automation.boot_guardian_shutdown.started",
            "automation.boot_guardian_shutdown.linux",
            "linux.boot_guardian_shutdown_windows_reboot",
            "automation.boot_guardian_shutdown.windows",
        ]
        if mode == "boot-order":
            events += [
                "automation.boot_guardian_fault.plan",
                "automation.boot_guardian_fault.inject",
                "automation.boot_guardian_fault.verify",
            ] * 2
        else:
            events += [
                "automation.preferred_path_bypass.plan",
                "automation.preferred_path_bypass.inject",
                "automation.preferred_path_prompt.unanswered_reboot",
                "automation.preferred_path_guardian.plan",
                "automation.preferred_path_guardian.inject",
                "automation.preferred_path_guardian.verify",
            ] * 2 + [
                "automation.preferred_path_prompt.visible_before_reboot",
                "automation.preferred_path_prompt.restored_after_reboot",
                "automation.preferred_path_prompt.accepted_after_proven_bypass",
                "automation.preferred_path_prompt.rebooted",
            ]
    for event in events:
        context = {"vm": child.vms[0]}
        if event.startswith(("windows.", "linux.")):
            context["test"] = event
            event = "automation.test." + event.split(".")[0]
        if event == "automation.vm_finished":
            context["vm_status"] = "ok"
        steps.append(
            StepResult(step=event, status="ok", message="Synthetic evidence", context=context)
        )
    return steps


def run_success(child, workspace, publish):
    steps = recovery_steps(child)
    for step in steps:
        publish(step)
    return OperationResult(status="ok", operation="automation", message="done", steps=steps)


def campaign_request(**overrides):
    return AutomationCampaignRequest(
        apply=True,
        linux_password="test-pass",
        include_boot_guardian_scenarios=True,
        **overrides,
    )


def test_full_campaign_adds_exactly_twelve_uefi_recovery_cells(tmp_path):
    calls = []

    def run(child, workspace, publish):
        calls.append(child)
        return run_success(child, workspace, publish)

    result = run_campaign(
        campaign_request(include_storage_scenarios=True),
        list(FIRMWARES),
        tmp_path,
        run,
        vm_firmwares=FIRMWARES,
    )
    assert result.status == "ok"
    assert len(calls) == 54
    assert Counter(c.vms[0] for c in calls) == {"vm1": 14, "vm2": 20, "vm3": 20}
    assert Counter(c.boot_guardian_fault for c in calls) == {
        "none": 42,
        "boot-order": 4,
        "preferred-path": 4,
        "preferred-path-rollback": 4,
    }
    expected_modes = tuple((d, "windows", mode) for mode in MODES for d in ("mint", "zorin"))
    assert expected_modes == BOOT_GUARDIAN_SCENARIOS
    for child in calls:
        if child.boot_guardian_fault != "none":
            assert child.vms[0] in {"vm2", "vm3"}
            assert child.first_boot == "windows"
            assert child.snapshot_mode == "default"
            assert child.installation_target == "windows"
            assert not child.verify_uninstall
            assert child.expected_compatibility_refusal is None
            assert child.share_windows_files_in_linux and child.share_linux_files_in_windows
    for row in result.campaign_summary[14:]:
        assert row["vms"] == {"vm2": "ok", "vm3": "ok"}
        assert set(row["cells"]) == {"vm2", "vm3"}
    plan = result.steps[0].context
    assert plan["total_scenarios"] == 20
    assert sum(len(s["vms"]) for s in plan["scenarios"]) == 54
    for scenario in plan["scenarios"][14:]:
        mode = scenario["boot_guardian_fault"]
        assert scenario["expectations"] == {"vm2": mode, "vm3": mode}
        for milestones in scenario["vm_milestones"].values():
            assert not any("uninstall" in name for name in milestones)
            if mode == "preferred-path-rollback":
                assert "automation.preferred_path_rollback.verify" in milestones
                assert "automation.test.windows.final_state" not in milestones
    assert read_interrupted_campaign_summary(tmp_path) == result.campaign_summary


@pytest.mark.parametrize("mode", MODES)
def test_recovery_requires_every_expected_proof(mode):
    child = AutomationRequest(
        apply=True,
        vms=["vm2"],
        linux_password="test-pass",
        first_boot="windows",
        boot_guardian_fault=mode,
    )
    steps = recovery_steps(child)
    assert missing_campaign_evidence(child, steps) == []
    for index, step in enumerate(steps):
        key = step.context.get("test", step.step)
        assert missing_campaign_evidence(child, steps[:index] + steps[index + 1 :]) == [key]


def test_recovery_vm_lanes_do_not_wait_for_each_other(tmp_path):
    advanced = threading.Event()

    def run(child, workspace, publish):
        if child.vms == ["vm2"] and child.boot_guardian_fault == "boot-order":
            assert advanced.wait(5), "A UEFI VM waited for the other UEFI VM"
        if child.vms == ["vm3"] and child.boot_guardian_fault == "preferred-path":
            advanced.set()
        return run_success(child, workspace, publish)

    result = run_campaign(
        campaign_request(start_scenario="mint-windows-first-boot-order"),
        list(FIRMWARES),
        tmp_path,
        run,
        vm_firmwares=FIRMWARES,
    )
    assert result.status == "ok"
    assert all(row["status"] == "not-run" for row in result.campaign_summary[:4])
    assert all(row["status"] == "ok" for row in result.campaign_summary[4:])


@pytest.mark.parametrize("firmwares", [None, {"vm1": "bios"}, dict.fromkeys(FIRMWARES, "bios")])
def test_recovery_rejects_unknown_or_missing_uefi_scope(tmp_path, firmwares):
    def must_not_run(*args):
        raise AssertionError("Invalid scope reached a VM worker")

    with pytest.raises(ValueError, match="firmware|UEFI"):
        run_campaign(
            campaign_request(), list(FIRMWARES), tmp_path, must_not_run, vm_firmwares=firmwares
        )


def test_recovery_missing_proof_retries_once_and_preserves_failure(tmp_path):
    attempts = Counter()

    def run(child, workspace, publish):
        key = (child.vms[0], child.distribution, child.boot_guardian_fault)
        attempts[key] += 1
        result = run_success(child, workspace, publish)
        if child.vms == ["vm2"] and child.boot_guardian_fault == "preferred-path-rollback":
            result.steps = [
                s for s in result.steps if s.step != "automation.preferred_path_rollback.verify"
            ]
        return result

    result = run_campaign(
        campaign_request(
            start_scenario="mint-windows-first-preferred-path-rollback",
            retry_failed_scenarios=True,
            continue_after_failure=True,
        ),
        list(FIRMWARES),
        tmp_path,
        run,
        vm_firmwares=FIRMWARES,
    )
    assert result.status == "error"
    for row in result.campaign_summary[-2:]:
        assert row["vms"] == {"vm2": "error", "vm3": "ok"}
        cell = row["cells"]["vm2"]
        assert cell["attempt"] == 2
        assert len(cell["previous_attempts"]) == 1
        assert (
            cell["previous_attempts"][0]["errors"][-1]["step"]
            == "automation.campaign_missing_evidence"
        )
        assert cell["errors"][-1]["context"]["missing_evidence"] == [
            "automation.preferred_path_rollback.verify"
        ]
    assert max(attempts.values()) == 2


@pytest.mark.parametrize("clean2_only", [False, True])
def test_runner_validates_full_and_clean2_campaign_results(tmp_path, clean2_only):
    source = RUNNER.read_text().split("<<'PY'\n", 1)[1].split("\nPY\n", 1)[0]
    tree = ast.parse(source)
    namespace = {
        "SCENARIOS": SCENARIOS,
        "STORAGE_SCENARIOS": STORAGE_SCENARIOS,
        "BOOT_GUARDIAN_SCENARIOS": BOOT_GUARDIAN_SCENARIOS,
        "LOCAL_FILEPOOL_SCENARIOS": LOCAL_FILEPOOL_SCENARIOS,
        "clean2_only": clean2_only,
        "firmwares": FIRMWARES,
        "payload": {"vms": list(FIRMWARES)},
    }
    for node in tree.body:
        if (
            (
                isinstance(node, ast.Assign)
                and isinstance(node.targets[0], ast.Name)
                and node.targets[0].id
                in {
                    "scenario_names",
                    "boot_guardian_scenario_names",
                    "local_filepool_scenario_names",
                }
            )
            or (
                isinstance(node, ast.If)
                and isinstance(node.test, ast.UnaryOp)
                and isinstance(node.test.op, ast.Not)
                and isinstance(node.test.operand, ast.Name)
                and node.test.operand.id == "clean2_only"
            )
            or (isinstance(node, ast.FunctionDef) and node.name == "validate_success")
        ):
            exec(compile(ast.Module(body=[node], type_ignores=[]), str(RUNNER), "exec"), namespace)
    expected = [f"{distribution}-{first_boot}-first" for distribution, first_boot in SCENARIOS]
    if not clean2_only:
        expected.extend(
            f"{distribution}-{first_boot}-first-{layout}"
            for distribution, first_boot, layout in STORAGE_SCENARIOS
        )
        expected.extend(
            f"{distribution}-{first_boot}-first-{fault}"
            for distribution, first_boot, fault in BOOT_GUARDIAN_SCENARIOS
        )
    expected.extend(f"{d}-{b}-first-local-filepool" for d, b in LOCAL_FILEPOOL_SCENARIOS)
    assert namespace["scenario_names"] == expected
    payload = next(
        node.value
        for node in ast.walk(tree)
        if isinstance(node, ast.Assign)
        and isinstance(node.targets[0], ast.Name)
        and node.targets[0].id == "payload"
    )
    assert isinstance(payload, ast.Dict)
    local_flag = next(
        value
        for key, value in zip(payload.keys, payload.values, strict=True)
        if isinstance(key, ast.Constant) and key.value == "include_local_filepool_scenarios"
    )
    assert eval(compile(ast.Expression(local_flag), str(RUNNER), "eval"), {}, namespace) is True
    for field in ("include_storage_scenarios", "include_boot_guardian_scenarios"):
        flag = next(
            value
            for key, value in zip(payload.keys, payload.values, strict=True)
            if isinstance(key, ast.Constant) and key.value == field
        )
        assert (
            eval(compile(ast.Expression(flag), str(RUNNER), "eval"), {}, namespace)
            is not clean2_only
        )
    result = run_campaign(
        AutomationCampaignRequest(
            apply=True,
            linux_password="test-pass",
            include_storage_scenarios=not clean2_only,
            include_boot_guardian_scenarios=not clean2_only,
            include_local_filepool_scenarios=True,
        ),
        list(FIRMWARES),
        tmp_path,
        run_success,
        vm_firmwares=FIRMWARES,
    ).model_dump(mode="json")
    namespace["validate_success"](result)
    corrupted = json.loads(json.dumps(result))
    del corrupted["campaign_summary"][-1]["cells"]["vm2"]
    with pytest.raises(RuntimeError, match="inconsistent VM results"):
        namespace["validate_success"](corrupted)
    corrupted = json.loads(json.dumps(result))
    corrupted["campaign_summary"][-1]["vms"]["vm1"] = "error" if clean2_only else "ok"
    with pytest.raises(RuntimeError, match="inconsistent VM results"):
        namespace["validate_success"](corrupted)
    corrupted = json.loads(json.dumps(result))
    corrupted["campaign_summary"] = corrupted["campaign_summary"][:-1]
    with pytest.raises(RuntimeError, match="missing, duplicate, or unexpected"):
        namespace["validate_success"](corrupted)


@pytest.mark.parametrize("full", [False, True])
def test_local_filepool_cases_remain_nominal_and_require_source_evidence(tmp_path, full):
    seen = []

    def run(child, workspace, publish):
        if child.local_filepool:
            assert child.vms == ["vm2"]
            assert child.snapshot_mode == "default"
            assert child.installation_target == "windows"
            assert child.boot_guardian_fault == "none"
            assert child.verify_uninstall
            assert child.storage_fixture.extra_system_partition == "none"
            seen.append(child.distribution)
            steps = successful_campaign_steps(child)
            for evidence in (
                "automation.local_filepool.prepared",
                "automation.local_filepool.used",
            ):
                missing = missing_campaign_evidence(
                    child, [step for step in steps if step.step != evidence]
                )
                assert missing == [evidence]
        return run_success(child, workspace, publish)

    result = run_campaign(
        AutomationCampaignRequest(
            apply=True,
            linux_password="test-pass",
            include_storage_scenarios=full,
            include_boot_guardian_scenarios=full,
            include_local_filepool_scenarios=True,
        ),
        list(FIRMWARES),
        tmp_path,
        run,
        vm_firmwares=FIRMWARES,
    )
    assert result.status == "ok"
    assert seen == ["mint", "zorin"]
    assert len(read_interrupted_campaign_summary(tmp_path)) == len(result.campaign_summary)
