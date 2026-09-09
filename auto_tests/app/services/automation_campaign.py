from __future__ import annotations

import json
import os
from collections.abc import Callable
from pathlib import Path

from app.models import AutomationCampaignRequest, AutomationRequest, OperationResult, StepResult
from app.stream_events import StreamEventProjector

SCENARIOS = (("mint", "windows"), ("mint", "linux"), ("zorin", "windows"), ("zorin", "linux"))


def read_interrupted_campaign_summary(workspace: Path) -> list[dict[str, object]]:
    path = workspace / "campaign-summary.json"
    try:
        if path.stat().st_size > 1024 * 1024:
            return []
        summary = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(summary, list) or len(summary) != len(SCENARIOS):
            return []
        for item in summary:
            if not isinstance(item, dict):
                return []
            if item.get("status") == "running":
                item["status"] = "interrupted"
        return summary
    except (OSError, ValueError):
        return []


def _persist_summary(workspace: Path, summary: list[dict[str, object]]) -> None:
    temporary = workspace / "campaign-summary.json.tmp"
    with temporary.open("w", encoding="utf-8") as output:
        json.dump(summary, output, ensure_ascii=False)
        output.flush()
        os.fsync(output.fileno())
    temporary.replace(workspace / "campaign-summary.json")


def run_campaign(
    request: AutomationCampaignRequest,
    vm_names: list[str],
    workspace: Path,
    run_scenario: Callable[
        [AutomationRequest, Path, Callable[[StepResult], None]], OperationResult
    ],
    on_step: Callable[[StepResult], None] | None = None,
) -> OperationResult:
    if len(vm_names) != 3 or len(set(vm_names)) != 3:
        raise ValueError("The complete campaign requires exactly three distinct enabled test VMs")
    summaries: list[dict[str, object]] = [
        {
            "scenario": f"{distribution}-{first_boot}-first",
            "status": "not-run",
            "vms": {name: "not-run" for name in vm_names},
        }
        for distribution, first_boot in SCENARIOS
    ]
    _persist_summary(workspace, summaries)
    steps: list[StepResult] = []
    stopped = False
    failed = False
    for index, (distribution, first_boot) in enumerate(SCENARIOS):
        scenario = f"{distribution}-{first_boot}-first"
        if stopped:
            continue
        scenario_workspace = workspace / scenario
        scenario_workspace.mkdir(mode=0o700, parents=True, exist_ok=True)
        projector = StreamEventProjector("automation", scenario_workspace)
        summaries[index].update(status="running", log=str(projector.log_path))
        _persist_summary(workspace, summaries)

        def publish(step: StepResult, *, scenario_name=scenario, log=projector) -> None:
            tagged = step.model_copy(
                update={"context": {**step.context, "scenario": scenario_name}}
            )
            log.project_step(tagged)
            steps.append(tagged)
            if on_step is not None:
                on_step(tagged)

        publish(StepResult(step="automation.campaign_scenario", status="ok", message=scenario))
        child_request = AutomationRequest(
            vms=vm_names,
            source=request.source,
            apply=True,
            distribution=distribution,
            first_boot=first_boot,
            linux_username=request.linux_username,
            linux_password=request.linux_password,
            linux_size_gib=request.linux_size_gib,
            migrate_windows_preferences=request.migrate_windows_preferences,
        )
        try:
            outcome = run_scenario(child_request, scenario_workspace, publish)
        except Exception as exc:
            error = StepResult(
                step="automation.campaign_exception",
                status="error",
                message="Scenario terminated unexpectedly",
                context={"exception_type": type(exc).__name__},
            )
            publish(error)
            outcome = OperationResult(
                status="error", operation="automation", message=error.message, steps=[error]
            )
        errors = [step.model_dump(mode="json") for step in outcome.steps if step.status == "error"]
        statuses = {
            str(step.context["vm"]): step.context["vm_status"]
            for step in outcome.steps
            if step.step == "automation.vm_finished" and "vm" in step.context
        }
        if outcome.status == "ok" and any(statuses.get(name) != "ok" for name in vm_names):
            error = StepResult(
                step="automation.campaign_missing_verdict",
                status="error",
                message="A scenario lacks a successful terminal verdict for every selected VM",
            )
            publish(error)
            errors.append(error.model_dump(mode="json"))
            outcome.status = "error"
            outcome.message = error.message
            outcome.steps.append(error)
        projector.project_result(outcome)
        summaries[index] = {
            "scenario": scenario,
            "status": outcome.status,
            "message": outcome.message,
            "vms": {name: statuses.get(name, "not-verified") for name in vm_names},
            "errors": errors,
            "log": str(projector.log_path),
            "captures": str(scenario_workspace / "captures"),
        }
        _persist_summary(workspace, summaries)
        failed |= outcome.status != "ok"
        stopped = outcome.status != "ok" and not request.continue_after_failure
    return OperationResult(
        status="error" if failed else "ok",
        operation="automation",
        message="Complete nominal installation campaign failed"
        if failed
        else "Complete nominal installation campaign passed",
        steps=steps,
        campaign_summary=summaries,
    )
