from pathlib import Path

import pytest
from pydantic import ValidationError

from app.models import AutomationCampaignRequest, OperationResult, StepResult
from app.services.automation_campaign import (
    SCENARIOS,
    read_interrupted_campaign_summary,
    run_campaign,
)
from app.services.automation_progress import OperationProgress
from app.stream_events import StreamEventProjector


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
        calls.append((child.distribution, child.first_boot))
        assert child.vms == names
        assert child.boot_guardian_fault == "none"
        assert child.snapshot_mode == "default"
        assert child.monitor_iso is True
        assert workspace.parent == tmp_path
        steps = []
        for name in names:
            step = StepResult(
                step="automation.vm_finished",
                status="ok",
                message="finished",
                context={
                    "vm": name,
                    "vm_status": "error" if len(calls) == 2 and name == "vm2" else "ok",
                },
            )
            publish(step)
            steps.append(step)
        if len(calls) == 2:
            error = StepResult(
                step="test.failure", status="error", message="expected", context={"vm": "vm2"}
            )
            publish(error)
            steps.append(error)
        return OperationResult(
            status="error" if len(calls) == 2 else "ok",
            operation="automation",
            message="done",
            steps=steps,
        )

    outcome = run_campaign(request, names, tmp_path, run)
    assert calls == list(SCENARIOS if continue_after_failure else SCENARIOS[:2])
    assert outcome.status == "error"
    assert len(outcome.campaign_summary) == 4
    assert outcome.campaign_summary[1]["vms"]["vm2"] == "error"
    assert outcome.campaign_summary[1]["errors"][0]["message"] == "expected"
    for item in outcome.campaign_summary:
        if item["status"] != "not-run":
            assert Path(item["log"]).is_file()
            assert request.linux_password not in Path(item["log"]).read_text()
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
    calls = 0

    def run(*_args):
        nonlocal calls
        calls += 1
        raise SystemExit(1)

    with pytest.raises(SystemExit):
        run_campaign(request, ["vm1", "vm2", "vm3"], tmp_path, run)
    summary = read_interrupted_campaign_summary(tmp_path)
    assert calls == 1
    assert summary[0]["status"] == "interrupted"
    assert all(item["status"] == "not-run" for item in summary[1:])
    assert "log" in summary[0]


def test_progress_tracks_repeated_checks_in_each_campaign_scenario() -> None:
    progress = OperationProgress(0)
    for number, scenario in enumerate(("mint-windows-first", "mint-linux-first"), 1):
        step = StepResult(
            step="test.check", status="ok", message="same check", context={"scenario": scenario}
        )
        assert progress.observe(step, number)
        assert not progress.observe(step, number + 0.1)
    assert progress.oldest() == ("global", 2)
