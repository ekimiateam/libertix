from __future__ import annotations

import json
import os
import threading
from collections import Counter
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from app.models import AutomationCampaignRequest, AutomationRequest, OperationResult, StepResult
from app.storage_fixtures import StorageFixtureRequest
from app.stream_events import StreamEventProjector

SCENARIOS = (("mint", "windows"), ("mint", "linux"), ("zorin", "windows"), ("zorin", "linux"))
LOCAL_FILEPOOL_SCENARIOS = (("mint", "windows"), ("zorin", "linux"))
STORAGE_SCENARIOS = tuple(
    (distribution, first_boot, layout)
    for layout in ("fat32", "ntfs", "recovery")
    for distribution, first_boot in (("mint", "windows"), ("zorin", "linux"))
) + tuple((distribution, first_boot, "secondary") for distribution, first_boot in SCENARIOS)
BOOT_GUARDIAN_SCENARIOS = tuple(
    (distribution, "windows", fault)
    for fault in ("boot-order", "preferred-path", "preferred-path-rollback")
    for distribution in ("mint", "zorin")
)

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
BOOT_GUARDIAN_MILESTONES = {
    "boot-order": {
        "automation.boot_guardian_fault.verify": "BootOrder repair verified",
        "automation.boot_guardian_shutdown.windows": "Shutdown repair and both OS boots verified",
    },
    "preferred-path": {
        "automation.preferred_path_prompt.restored_after_reboot": "Unanswered consent restored",
        "automation.preferred_path_prompt.rebooted": "Consented EFI replacement completed",
        "automation.preferred_path_guardian.verify": "Preferred EFI path repair verified",
        "automation.boot_guardian_shutdown.windows": "Shutdown repair and both OS boots verified",
    },
    "preferred-path-rollback": {
        "automation.preferred_path_rollback.requested": "EFI replacement declined",
        "automation.preferred_path_rollback.verify": "Original Windows state restored",
    },
}


# This independent acceptance contract must not shrink if a controller skips a check.
INSTALLATION_TESTS = [
    "linux.ssh",
    "linux.first_boot_verification_ready",
    "linux.post_install_result_process",
    "linux.identity",
    "linux.os_release",
    "linux.kernel",
    "linux.hostname",
    "linux.locale",
    "linux.keyboard",
    "linux.timezone",
    "linux.firmware",
    "linux.root_filesystem",
    "linux.root_uuid",
    "linux.fstab",
    "linux.user_home",
    "linux.sudo_group",
    "linux.ssh_service",
    "linux.ssh_security",
    "linux.development_profile",
    "linux.static_ipv4",
    "linux.gateway",
    "linux.dns",
    "linux.grub",
    "linux.grub_regeneration",
    "linux.boot_mode_files",
    "linux.boot_artifacts",
    "linux.running_kernel_artifacts",
    "linux.initramfs_integrity",
    "linux.windows_mount",
    "linux.sharing_policy",
    "linux.windows_profile_shortcuts",
    "linux.desktop_stack",
    "linux.first_boot_verification",
    "linux.first_boot_cleanup",
    "linux.system_resources",
    "linux.failed_units",
    "linux.time_sync",
    "linux.package_database",
    "linux.package_dependencies",
    "linux.name_resolution",
    "sharing.linux_to_windows_100m",
    "sharing.linux_home_marker",
    "linux.windows_reboot",
    "windows.ssh",
    "windows.finalization",
    "windows.identity",
    "windows.firmware",
    "windows.system_volume",
    "windows.system_resources",
    "windows.partition_layout",
    "windows.partition_geometry",
    "windows.boot_partition",
    "windows.boot_configuration",
    "windows.recovery",
    "windows.bitlocker",
    "windows.temporary_artifacts",
    "windows.network",
    "windows.locale",
    "windows.ssh_service",
    "windows.update_policy",
    "windows.core_services",
    "windows.hibernation",
    "windows.ext4_driver",
    "windows.ext4_readonly_mount",
    "windows.linux_home",
    "windows.linux_home_hash",
    "windows.ext4_write_denied",
    "windows.explorer_shortcut",
    "windows.explorer_integration",
    "windows.sharing_tasks",
    "windows.cross_os_hash",
    "windows.dism_check_health",
    "windows.sfc_verify_only",
    "windows.chkdsk_scan",
    "sharing.windows_artifact_cleanup",
    "windows.linux_reboot",
    "linux.return_after_windows",
    "sharing.linux_artifact_cleanup",
    "linux.final_windows_reboot",
    "windows.final_state",
]


def campaign_evidence_requirements(request: AutomationRequest) -> Counter[str]:
    required = Counter(("automation.prepare_vm", "automation.deploy", "automation.vm_finished"))
    if request.local_filepool:
        required.update(("automation.local_filepool.prepared", "automation.local_filepool.used"))
    if request.expected_compatibility_refusal:
        required.update(("automation.compatibility_refusal", "automation.compatibility_unchanged"))
    else:
        if request.boot_guardian_fault != "preferred-path-rollback":
            required.update(INSTALLATION_TESTS)
        required.update(
            (
                "automation.reboot_requested",
                "automation.installed_boot_menu_seen",
            )
        )
        if request.boot_guardian_fault == "none":
            required.update(
                (
                    "automation.installed_linux_uninstall.verify",
                    "automation.installed_linux_uninstall.completed",
                    "automation.installed_linux_uninstall.unassisted_boot",
                    "automation.installed_linux_uninstall.after_reboot",
                )
            )
        if request.first_boot == "windows":
            required.update(("windows.waiting_for_linux", "windows.linux_reboot"))
        if request.storage_fixture.redirect_documents:
            required.update(("automation.test.redirected_documents",))
        if (
            request.migrate_windows_preferences
            and request.boot_guardian_fault != "preferred-path-rollback"
        ):
            required.update(("automation.test.preference_migration",))
    fault = request.boot_guardian_fault
    if fault in {"boot-order", "preferred-path"}:
        required.update(
            (
                "automation.boot_guardian_shutdown.stopped",
                "automation.boot_guardian_shutdown.started",
                "automation.boot_guardian_shutdown.linux",
                "linux.boot_guardian_shutdown_windows_reboot",
                "automation.boot_guardian_shutdown.windows",
            )
        )
        prefix = (
            "automation.boot_guardian_fault"
            if fault == "boot-order"
            else "automation.preferred_path_guardian"
        )
        # Reboot repair and cold-start repair must each provide their own evidence.
        required.update({f"{prefix}.{phase}": 2 for phase in ("plan", "inject", "verify")})
    if fault in {"preferred-path", "preferred-path-rollback"}:
        count = 2 if fault == "preferred-path" else 1
        required.update(
            {
                "automation.preferred_path_bypass.plan": count,
                "automation.preferred_path_bypass.inject": count,
            }
        )
        if fault == "preferred-path":
            required.update(
                (
                    "automation.preferred_path_prompt.visible_before_reboot",
                    "automation.preferred_path_prompt.restored_after_reboot",
                    "automation.preferred_path_prompt.accepted_after_proven_bypass",
                    "automation.preferred_path_prompt.rebooted",
                )
            )
            required.update({"automation.preferred_path_prompt.unanswered_reboot": 2})
        else:
            required.update(
                (
                    "automation.preferred_path_rollback.requested",
                    "automation.preferred_path_rollback.verify",
                )
            )
    if request.snapshot_mode == "secondary-disk":
        required.update(
            (
                "automation.storage_fixture.preserved",
                "automation.storage_fixture.documents_preserved",
            )
        )
    return required


def missing_campaign_evidence(request: AutomationRequest, steps: list[StepResult]) -> list[str]:
    observed: Counter[str] = Counter()
    for step in steps:
        if step.context.get("vm") != request.vms[0] or step.status != "ok":
            continue
        if step.context.get("exit_code", 0) != 0:
            continue
        if step.step == "automation.compatibility_refusal" and (
            step.context.get("error_code") != request.expected_compatibility_refusal
        ):
            continue
        if step.step in {
            "automation.test.linux",
            "automation.test.windows",
            "automation.test.artifact_cleanup",
        }:
            key = step.context.get("test")
            if isinstance(key, str):
                observed[key] += 1
        else:
            observed[step.step] += 1
    return sorted((campaign_evidence_requirements(request) - observed).elements())


def read_interrupted_campaign_summary(workspace: Path) -> list[dict[str, object]]:
    path = workspace / "campaign-summary.json"
    try:
        summary = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(summary, list) or len(summary) not in {
            len(SCENARIOS) + storage + guardian + local
            for storage in (0, len(STORAGE_SCENARIOS))
            for guardian in (0, len(BOOT_GUARDIAN_SCENARIOS))
            for local in (0, len(LOCAL_FILEPOOL_SCENARIOS))
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
    scenarios = [(distribution, first_boot, "", "none") for distribution, first_boot in SCENARIOS]
    if (
        request.include_storage_scenarios
        or request.include_boot_guardian_scenarios
        or request.include_local_filepool_scenarios
    ) and (
        vm_firmwares is None
        or any(vm_firmwares.get(name) not in {"bios", "uefi"} for name in vm_names)
    ):
        raise ValueError(
            "Storage and boot scenarios require the configured firmware of each test VM"
        )
    if request.include_storage_scenarios:
        scenarios.extend((d, b, layout, "none") for d, b, layout in STORAGE_SCENARIOS)
    if request.include_boot_guardian_scenarios:
        if not any(vm_firmwares[name] == "uefi" for name in vm_names):
            raise ValueError("Boot guardian scenarios require at least one UEFI test VM")
        scenarios.extend((d, b, "", fault) for d, b, fault in BOOT_GUARDIAN_SCENARIOS)
    local_filepool_vm = next(
        (vm for vm in vm_names if (vm_firmwares or {}).get(vm) == "uefi"), None
    )
    if request.include_local_filepool_scenarios:
        if not local_filepool_vm:
            raise ValueError("Local filepool scenarios require a UEFI VM")
        scenarios.extend((d, b, "local-filepool", "none") for d, b in LOCAL_FILEPOOL_SCENARIOS)
    scenario_vms = [
        [local_filepool_vm]
        if layout == "local-filepool"
        else [vm for vm in vm_names if fault == "none" or vm_firmwares[vm] == "uefi"]
        for _, _, layout, fault in scenarios
    ]
    summaries = [
        {
            "scenario": f"{distribution}-{first_boot}-first"
            + (f"-{layout}" if layout else f"-{fault}" if fault != "none" else ""),
            "status": "not-run",
            "vms": {name: "not-run" for name in scenario_vms[index]},
            "cells": {
                name: {"status": "not-run", "previous_attempts": []} for name in scenario_vms[index]
            },
            "previous_attempts": [],
        }
        for index, (distribution, first_boot, layout, fault) in enumerate(scenarios)
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

    def cell_milestones(vm: str, layout: str, fault: str) -> dict[str, str]:
        if is_negative(vm, layout):
            return negative_milestones
        if fault == "none":
            return CAMPAIGN_MILESTONES
        common = {
            key: label
            for key, label in CAMPAIGN_MILESTONES.items()
            if not key.startswith("automation.installed_linux_uninstall.")
            and not (
                fault == "preferred-path-rollback" and key == "automation.test.windows.final_state"
            )
        }
        return common | BOOT_GUARDIAN_MILESTONES[fault]

    plan = StepResult(
        step="automation.campaign_plan",
        status="ok",
        message="Independent VM lanes with explicit installation or refusal contracts",
        context={
            "milestones": CAMPAIGN_MILESTONES
            | negative_milestones
            | {
                key: label
                for values in BOOT_GUARDIAN_MILESTONES.values()
                for key, label in values.items()
            },
            "first_scenario_index": start_index + 1,
            "total_scenarios": len(scenarios),
            "independent_vms": True,
            "scenarios": [
                {
                    "name": names[index],
                    "vms": scenario_vms[index],
                    "distribution": distribution,
                    "first_boot": first_boot,
                    "layout": layout or "nominal",
                    "boot_guardian_fault": fault,
                    "snapshot_mode": "secondary-disk"
                    if layout and layout != "local-filepool"
                    else "default",
                    "installation_target": "secondary" if layout == "secondary" else "windows",
                    "vm_milestones": {
                        vm: list(cell_milestones(vm, layout, fault)) for vm in scenario_vms[index]
                    },
                    "expectations": {
                        vm: "compatibility-refusal"
                        if is_negative(vm, layout)
                        else fault
                        if fault != "none"
                        else "install-uninstall"
                        for vm in scenario_vms[index]
                    },
                }
                for index, (distribution, first_boot, layout, fault) in enumerate(scenarios)
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
        summary["vms"] = {vm: cell["status"] for vm, cell in cells.items()}
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
            {"vm": vm, **attempt}
            for vm, cell in cells.items()
            for attempt in cell["previous_attempts"]
        ]
        _persist_summary(workspace, summaries)

    def lane(vm: str) -> None:
        for index in range(start_index, len(scenarios)):
            if vm not in scenario_vms[index]:
                continue
            distribution, first_boot, layout, fault = scenarios[index]
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
                if layout and layout != "local-filepool":
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
                    share_windows_files_in_linux=True,
                    share_linux_files_in_windows=True,
                    verify_uninstall=not negative and fault == "none",
                    boot_guardian_fault=fault,
                    local_filepool=layout == "local-filepool",
                    expected_compatibility_refusal="COMPAT_E_MBR_PRIMARY_LIMIT"
                    if negative
                    else None,
                    snapshot_mode="secondary-disk"
                    if layout and layout != "local-filepool"
                    else "default",
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
                if outcome.status == "ok":
                    missing = missing_campaign_evidence(child, outcome.steps)
                    if missing:
                        error = StepResult(
                            step="automation.campaign_missing_evidence",
                            status="error",
                            message="The VM scenario is missing required successful checks: "
                            + ", ".join(missing),
                            context={"vm": vm, "missing_evidence": missing},
                        )
                        publish(error)
                        outcome.status = "error"
                        outcome.message = error.message
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
