from collections import Counter

import pytest

from app.models import AutomationCampaignRequest, AutomationRequest, OperationResult, StepResult
from app.services.automation import AutomationService
from app.services.automation_campaign import missing_campaign_evidence, run_campaign
from app.services.automation_types import AutomationOptions
from app.services.automation_windows_checks import CrossOsArtifacts, build_windows_validation_plan
from app.services.common import ResultBuilder
from app.storage_fixtures import StorageFixtureRequest

from .campaign_evidence import LINUX_CHECKS, WINDOWS_CHECKS, successful_campaign_steps
from .test_core import settings


@pytest.mark.parametrize("kind", ["nominal", "secondary", "refusal", "preferences"])
@pytest.mark.parametrize("first_boot", ["linux", "windows"])
def test_each_required_evidence_is_indispensable(kind, first_boot):
    storage = kind in {"secondary", "refusal"}
    request = AutomationRequest(
        apply=True,
        vms=["vm1"],
        linux_password="test-pass",
        first_boot=first_boot,
        verify_uninstall=kind != "refusal",
        expected_compatibility_refusal="COMPAT_E_MBR_PRIMARY_LIMIT" if kind == "refusal" else None,
        snapshot_mode="secondary-disk" if storage else "default",
        storage_fixture=StorageFixtureRequest(secondary_data=storage, redirect_documents=storage),
        migrate_windows_preferences=kind == "preferences",
    )
    steps = successful_campaign_steps(request)
    assert missing_campaign_evidence(request, steps) == []
    for index, removed in enumerate(steps):
        incomplete = steps[:index] + steps[index + 1 :]
        key = removed.context.get("test", removed.step)
        assert missing_campaign_evidence(request, incomplete) == [key]


@pytest.mark.parametrize("corruption", ["other-vm", "error", "exit-code", "started"])
def test_non_successful_test_evidence_cannot_count(corruption):
    request = AutomationRequest(apply=True, vms=["vm1"], linux_password="test-pass")
    steps = successful_campaign_steps(request)
    check = next(step for step in steps if step.context.get("test") == "linux.identity")
    if corruption == "other-vm":
        check.context["vm"] = "vm2"
    elif corruption == "error":
        check.status = "error"
    elif corruption == "exit-code":
        check.context["exit_code"] = 1
    else:
        check.step = "automation.check_started"
    assert missing_campaign_evidence(request, steps) == ["linux.identity"]


def test_refusal_requires_the_expected_product_error():
    request = AutomationRequest(
        apply=True,
        vms=["vm1"],
        linux_password="test-pass",
        expected_compatibility_refusal="COMPAT_E_MBR_PRIMARY_LIMIT",
    )
    steps = successful_campaign_steps(request)
    refusal = next(step for step in steps if step.step == "automation.compatibility_refusal")
    refusal.context["error_code"] = "UNRELATED_FAILURE"
    assert missing_campaign_evidence(request, steps) == ["automation.compatibility_refusal"]


@pytest.mark.parametrize(
    "corruption", ["terminal-only", "missing-check", "duplicate-terminal", "hidden-error"]
)
def test_campaign_rejects_false_success_and_records_the_reason(tmp_path, corruption):
    def run(child, workspace, publish):
        steps = successful_campaign_steps(child)
        if corruption == "terminal-only":
            steps = steps[-1:]
        elif corruption == "missing-check":
            steps = [step for step in steps if step.context.get("test") != "linux.identity"]
        elif corruption == "duplicate-terminal":
            steps.append(steps[-1].model_copy(deep=True))
        else:
            steps.append(StepResult(step="synthetic.failure", status="error", message="failed"))
        for step in steps:
            publish(step)
        return OperationResult(status="ok", operation="automation", message="done", steps=steps)

    result = run_campaign(
        AutomationCampaignRequest(apply=True, linux_password="test-pass"),
        ["vm1", "vm2", "vm3"],
        tmp_path,
        run,
    )
    assert result.status == "error"
    assert set(result.campaign_summary[0]["vms"].values()) == {"error"}
    assert all(row["status"] == "not-run" for row in result.campaign_summary[1:])
    error_name = (
        "automation.campaign_missing_evidence"
        if corruption in {"terminal-only", "missing-check"}
        else "automation.campaign_missing_verdict"
    )
    assert sum(step.step == error_name for step in result.steps) == 3
    if corruption == "missing-check":
        for cell in result.campaign_summary[0]["cells"].values():
            assert cell["errors"][-1]["context"]["missing_evidence"] == ["linux.identity"]


def test_failed_attempt_evidence_cannot_complete_the_retry(tmp_path):
    attempts = Counter()

    def run(child, workspace, publish):
        vm = child.vms[0]
        attempts[vm] += 1
        steps = successful_campaign_steps(child)
        removed = "linux.identity" if attempts[vm] == 1 else "windows.identity"
        steps = [step for step in steps if step.context.get("test") != removed]
        return OperationResult(status="ok", operation="automation", message="done", steps=steps)

    result = run_campaign(
        AutomationCampaignRequest(
            apply=True, linux_password="test-pass", retry_failed_scenarios=True
        ),
        ["vm1", "vm2", "vm3"],
        tmp_path,
        run,
    )
    assert result.status == "error"
    assert attempts == {"vm1": 2, "vm2": 2, "vm3": 2}
    for cell in result.campaign_summary[0]["cells"].values():
        assert cell["errors"][-1]["context"]["missing_evidence"] == ["windows.identity"]
        assert cell["previous_attempts"][0]["errors"][-1]["context"]["missing_evidence"] == [
            "linux.identity"
        ]


def test_fixture_covers_the_actual_linux_and_windows_check_plans(monkeypatch):
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    options = AutomationOptions("test", "test-pass", True)
    checks = []
    monkeypatch.setattr(
        service,
        "_run_remote_check",
        lambda _ssh, _vm, _result, _os, check, **_kw: checks.append(check),
    )
    service._run_linux_checks(None, vm, options, ResultBuilder("automation"))  # noqa: SLF001
    assert {check.name for check in checks} == {f"linux.{name}" for name in LINUX_CHECKS}
    plan = build_windows_validation_plan(vm, options, CrossOsArtifacts("a", "b", "c", "d"))
    assert set(plan.check_names) == set(WINDOWS_CHECKS)
