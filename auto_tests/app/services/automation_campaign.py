from __future__ import annotations

import json
import os
import threading
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from app.models import AutomationCampaignRequest, AutomationRequest, OperationResult, StepResult
from app.storage_fixtures import StorageFixtureRequest
from app.stream_events import StreamEventProjector

SCENARIOS = (("mint", "windows"), ("mint", "linux"), ("zorin", "windows"), ("zorin", "linux"))
STORAGE_SCENARIOS = tuple(
    (distribution, first_boot, layout)
    for layout in ("fat32", "ntfs", "recovery")
    for distribution, first_boot in (("mint", "windows"), ("zorin", "linux"))
) + tuple((distribution, first_boot, "secondary") for distribution, first_boot in SCENARIOS)

# Equal-weight completed checkpoints, not a prediction of elapsed or remaining time.
CAMPAIGN_MILESTONES = {
    "automation.prepare_vm": "Windows prepared",
    "automation.deploy": "Executable deployed",
    "automation.reboot_requested": "Windows installation preparation completed",
    "automation.installed_boot_menu_seen": "Installed boot menu detected",
    "automation.test.windows.final_state": "Windows returned after both OS checks",
    "automation.installed_linux_uninstall.verify": "Uninstall verified",
    "automation.installed_linux_uninstall.after_reboot": "Post-uninstall reboot verified",
    "automation.vm_finished": "Scenario passed",
}


def read_interrupted_campaign_summary(workspace: Path) -> list[dict[str, object]]:
    path = workspace / "campaign-summary.json"
    try:
        summary = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(summary, list) or len(summary) not in {
            len(SCENARIOS),
            len(SCENARIOS) + len(STORAGE_SCENARIOS),
        }:
            return []
        for item in summary:
            if not isinstance(item, dict):
                return []
            if item.get("status") == "running":
                item["status"] = "interrupted"
                vms = item.get("vms")
                if isinstance(vms, dict):
                    for vm, status in vms.items():
                        if status == "running":
                            vms[vm] = "interrupted"
                cells = item.get("cells")
                if isinstance(cells, dict):
                    for cell in cells.values():
                        if cell.get("status") == "running":
                            cell["status"] = "interrupted"
        _persist_summary(workspace, summary)
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
    vm_firmwares: dict[str, str] | None = None,
) -> OperationResult:
    if len(vm_names) != 3 or len(set(vm_names)) != 3:
        raise ValueError("The complete campaign requires exactly three distinct enabled test VMs")
    scenarios = [(distribution, first_boot, "") for distribution, first_boot in SCENARIOS]
    if request.include_storage_scenarios:
        if vm_firmwares is None or any(
            vm_firmwares.get(name) not in {"bios", "uefi"} for name in vm_names
        ):
            raise ValueError("Storage scenarios require the configured firmware of each test VM")
        scenarios.extend(STORAGE_SCENARIOS)
    summaries = [
        {
            "scenario": f"{distribution}-{first_boot}-first" + (f"-{layout}" if layout else ""),
            "status": "not-run",
            "vms": {name: "not-run" for name in vm_names},
            "cells": {name: {"status": "not-run", "previous_attempts": []} for name in vm_names},
            "previous_attempts": [],
        }
        for distribution, first_boot, layout in scenarios
    ]
    names = [str(item["scenario"]) for item in summaries]
    start_index = 0
    if request.start_scenario is not None:
        if request.start_scenario not in names:
            raise ValueError("Unknown start scenario; choose one of: " + ", ".join(names))
        start_index = names.index(request.start_scenario)
    negative_milestones = {
        key: label
        for key, label in CAMPAIGN_MILESTONES.items()
        if key in {"automation.prepare_vm", "automation.deploy", "automation.vm_finished"}
    } | {
        "automation.compatibility_refusal": "Expected target refusal observed",
        "automation.compatibility_unchanged": "Storage and boot unchanged",
    }

    def is_negative(vm: str, layout: str) -> bool:
        return layout in {"fat32", "ntfs", "recovery"} and (vm_firmwares or {}).get(vm) == "bios"

    plan = StepResult(
        step="automation.campaign_plan",
        status="ok",
        message="Independent VM lanes with explicit installation or refusal contracts",
        context={
            "milestones": CAMPAIGN_MILESTONES | negative_milestones,
            "first_scenario_index": start_index + 1,
            "total_scenarios": len(scenarios),
            "independent_vms": True,
            "scenarios": [
                {
                    "name": names[index],
                    "vms": vm_names,
                    "distribution": distribution,
                    "first_boot": first_boot,
                    "layout": layout or "nominal",
                    "snapshot_mode": "secondary-disk" if layout else "default",
                    "installation_target": "secondary" if layout == "secondary" else "windows",
                    "vm_milestones": {
                        vm: list(
                            negative_milestones if is_negative(vm, layout) else CAMPAIGN_MILESTONES
                        )
                        for vm in vm_names
                    },
                    "expectations": {
                        vm: "compatibility-refusal"
                        if is_negative(vm, layout)
                        else "install-uninstall"
                        for vm in vm_names
                    },
                }
                for index, (distribution, first_boot, layout) in enumerate(scenarios)
                if index >= start_index
            ],
        },
    )
    lock = threading.RLock()
    steps = [plan]
    _persist_summary(workspace, summaries)
    if on_step:
        on_step(plan)

    def save(index: int) -> None:
        summary = summaries[index]
        cells = summary["cells"]
        summary["vms"] = {vm: cells[vm]["status"] for vm in vm_names}
        states = set(summary["vms"].values())
        summary["status"] = (
            "ok"
            if states == {"ok"}
            else "running"
            if "running" in states or states == {"ok", "not-run"}
            else "error"
            if "error" in states
            else "not-run"
        )
        summary["previous_attempts"] = [
            {"vm": vm, **attempt} for vm in vm_names for attempt in cells[vm]["previous_attempts"]
        ]
        _persist_summary(workspace, summaries)

    def lane(vm: str) -> None:
        for index in range(start_index, len(scenarios)):
            distribution, first_boot, layout = scenarios[index]
            scenario = names[index]
            attempt = request.start_scenario_attempt if index == start_index else 1
            generation = 0
            history = []
            while True:
                generation += 1
                cell_workspace = workspace / scenario / vm / f"attempt-{attempt}-run-{generation}"
                cell_workspace.mkdir(mode=0o700, parents=True)
                projector = StreamEventProjector("automation", cell_workspace)
                cell = {
                    "status": "running",
                    "attempt": attempt,
                    "generation": generation,
                    "log": str(projector.log_path),
                    "captures": str(cell_workspace / "captures"),
                    "previous_attempts": history,
                }
                with lock:
                    summaries[index]["cells"][vm] = cell
                    save(index)

                def publish(
                    step: StepResult,
                    *,
                    scenario=scenario,
                    attempt=attempt,
                    generation=generation,
                    projector=projector,
                ) -> None:
                    tagged = step.model_copy(
                        update={
                            "context": {
                                **step.context,
                                "scenario": scenario,
                                "vm": vm,
                                "scenario_attempt": attempt,
                                "scenario_generation": generation,
                            }
                        }
                    )
                    with lock:
                        projector.project_step(tagged)
                        steps.append(tagged)
                        if on_step:
                            on_step(tagged)

                publish(
                    StepResult(step="automation.campaign_scenario", status="ok", message=scenario)
                )
                fixture = StorageFixtureRequest()
                if layout:
                    fixture = StorageFixtureRequest(
                        extra_system_partition="recovery" if layout == "secondary" else layout,
                        decrypt_system_volume=True,
                        secondary_data=True,
                        decrypt_secondary_volume=True,
                        redirect_documents=True,
                    )
                negative = is_negative(vm, layout)
                child = AutomationRequest(
                    vms=[vm],
                    source=request.source,
                    apply=True,
                    distribution=distribution,
                    first_boot=first_boot,
                    linux_username=request.linux_username,
                    linux_password=request.linux_password,
                    linux_size_gib=request.linux_size_gib,
                    migrate_windows_preferences=request.migrate_windows_preferences,
                    verify_uninstall=not negative,
                    expected_compatibility_refusal="COMPAT_E_MBR_PRIMARY_LIMIT"
                    if negative
                    else None,
                    snapshot_mode="secondary-disk" if layout else "default",
                    installation_target="secondary" if layout == "secondary" else "windows",
                    storage_fixture=fixture,
                )
                try:
                    outcome = run_scenario(child, cell_workspace, publish)
                except Exception as exc:
                    error = StepResult(
                        step="automation.campaign_exception",
                        status="error",
                        message="VM scenario terminated unexpectedly",
                        context={"exception_type": type(exc).__name__},
                    )
                    publish(error)
                    outcome = OperationResult(
                        status="error", operation="automation", message=error.message, steps=[error]
                    )
                terminal = [
                    step
                    for step in outcome.steps
                    if step.step == "automation.vm_finished" and step.context.get("vm") == vm
                ]
                if outcome.status == "ok" and (
                    len(terminal) != 1
                    or terminal[0].context.get("vm_status") != "ok"
                    or any(step.status == "error" for step in outcome.steps)
                ):
                    error = StepResult(
                        step="automation.campaign_missing_verdict",
                        status="error",
                        message="The VM scenario lacks a unique successful terminal verdict",
                    )
                    publish(error)
                    outcome.status = "error"
                    outcome.steps.append(error)
                errors = [
                    step.model_dump(mode="json") for step in outcome.steps if step.status == "error"
                ]
                projector.project_result(outcome)
                with lock:
                    cell.update(status=outcome.status, message=outcome.message, errors=errors)
                    save(index)
                prolonged = any(
                    step.context.get("restart_reason") == "prolonged_outage"
                    for step in outcome.steps
                    if step.step == "automation.network.restart_required"
                )
                retry = outcome.status != "ok" and (
                    prolonged or (request.retry_failed_scenarios and attempt < 2)
                )
                if not retry:
                    break
                next_attempt = attempt if prolonged else attempt + 1
                publish(
                    StepResult(
                        step="automation.campaign_retry",
                        status="ok",
                        message="Retrying this VM scenario from its snapshot; evidence retained",
                        context={
                            "reason": outcome.message,
                            "errors": errors,
                            "previous_log": str(projector.log_path),
                            "next_attempt": next_attempt,
                            "prolonged_outage": prolonged,
                        },
                    )
                )
                history = [
                    *history,
                    {key: value for key, value in cell.items() if key != "previous_attempts"},
                ]
                attempt = next_attempt
            if outcome.status != "ok" and not request.continue_after_failure:
                break

    # Each callback owns one isolated VM worker. The lock protects only the journal, never a VM run.
    with ThreadPoolExecutor(max_workers=len(vm_names)) as pool:
        futures = [pool.submit(lane, vm) for vm in vm_names]
        for future in futures:
            future.result()
    failed = any(item["status"] != "ok" for item in summaries[start_index:])
    return OperationResult(
        status="error" if failed else "ok",
        operation="automation",
        message="Selected installation scenarios " + ("failed" if failed else "passed"),
        steps=steps,
        campaign_summary=summaries,
    )
