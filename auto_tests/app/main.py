from __future__ import annotations

import asyncio
import faulthandler
import hashlib
import importlib.metadata
import json
import logging
import multiprocessing
import os
import queue
import re
import shlex
import sys
import threading
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from multiprocessing.connection import Connection
from multiprocessing.connection import wait as wait_connections
from pathlib import Path
from typing import Annotated, Literal

from fastapi import Body, FastAPI, HTTPException, Query
from fastapi.responses import FileResponse, HTMLResponse, StreamingResponse
from vncdotool import api as vnc_api

from app.api_requests import automation_request, validation_request
from app.api_runtime import (
    ActiveOperationProcess,
    cleanup_operation_artifacts,
    create_capture_workspace,
    mark_capture_workspace_complete,
    mark_capture_workspace_owned,
    operation_lock,
)
from app.clients import network_recovery
from app.clients.vnc import VNCClient
from app.config import Settings, get_settings
from app.distributions import load_distribution_profile
from app.logging_config import configure_logging
from app.models import (
    AutomationCampaignRequest,
    AutomationRequest,
    OperationResult,
    SourceMode,
    StepResult,
    ValidationRequest,
)
from app.services.automation import AutomationService
from app.services.automation_campaign import read_interrupted_campaign_summary, run_campaign
from app.services.automation_diagnostics import collect_failure_diagnostics
from app.services.automation_progress import OperationProgress
from app.services.automation_types import AutomationOptions
from app.services.common import ResultBuilder
from app.services.reset import ResetService
from app.services.validation import ValidationService
from app.stream_events import StreamEventProjector

logger = logging.getLogger(__name__)
OperationName = Literal["validation", "reset", "automation"]

# Capture source identity at import, not later after an operator edits the checkout.
SOURCE_AT_IMPORT = {
    str(path.relative_to(Path(__file__).parent)): hashlib.sha256(path.read_bytes()).hexdigest()
    for path in sorted(Path(__file__).parent.rglob("*.py"))
}
PACKAGES_AT_IMPORT = {
    name: importlib.metadata.version(name) for name in ("paramiko", "fastapi", "pydantic")
}


def _runtime_provenance() -> dict[str, object]:
    return {
        "pid": os.getpid(),
        "python": sys.version,
        "multiprocessing": multiprocessing.get_start_method(allow_none=True),
        "packages": PACKAGES_AT_IMPORT,
        "source_sha256_at_import": SOURCE_AT_IMPORT,
    }


def _worker_fatal_diagnostic_context(run_workspace: Path) -> dict[str, str]:
    path = run_workspace / "worker-fatal.log"
    try:
        content = path.read_text(encoding="utf-8", errors="replace").strip()
    except OSError:
        return {}
    if not content:
        return {}
    lines = content.splitlines()
    return {
        "fatal_log": str(path),
        "fatal_diagnostics": "\n".join(lines[-80:])[-12000:],
    }


def _operation_busy_result(operation: OperationName) -> OperationResult:
    return OperationResult(
        status="error",
        operation=operation,
        message="error: another operation is already running",
        steps=[],
    )


def _unpersisted_result_event(result: OperationResult) -> dict[str, object]:
    data = result.model_dump(mode="json")
    data["steps"] = [
        step.model_dump(mode="json") for step in result.steps if step.status == "error"
    ]
    data["detailed_log"] = ""
    return {"event": "result", "data": data}


def _finalize_operation_workspace(configured: Settings, run_workspace: Path) -> None:
    try:
        mark_capture_workspace_complete(run_workspace)
    except Exception:
        logger.exception(
            "Failed to mark an operation workspace complete",
            extra={"step": "capture.finalize", "target": str(run_workspace)},
        )
    try:
        cleanup_operation_artifacts(configured)
    except Exception:
        logger.exception(
            "Failed to apply operation artifact retention",
            extra={"step": "capture.retention", "target": str(run_workspace)},
        )


def _resolve_distribution_metadata(runtime_dir: Path, filepool_dir: Path) -> Path | None:
    for candidate in (runtime_dir / "filepool" / "catalog.json", filepool_dir / "catalog.json"):
        if candidate.is_file():
            return candidate
    return None


def _capture_automation_timeout_screens(
    configured: Settings,
    selectors: list[str] | None,
    run_workspace: Path,
) -> tuple[dict[str, str], dict[str, str]]:
    """Capture every selected VM before terminating an expired automation run."""

    captures: dict[str, str] = {}
    errors: dict[str, str] = {}
    try:
        selected_vms = ValidationService(configured).select_vms(selectors)
    except Exception as exc:
        return captures, {"selection": f"{type(exc).__name__}: {exc}"}

    vnc = VNCClient(configured.vnc_timeout_seconds)
    capture_dir = run_workspace / "captures"
    for vm in selected_vms:
        destination = capture_dir / f"timeout-{vm.name}.png"
        try:
            vnc.capture(vm.vnc, destination)
            captures[vm.name] = str(destination)
        except Exception as exc:
            errors[vm.name] = f"{type(exc).__name__}: {exc}"
    return captures, errors


def _collect_timeout_diagnostics(
    configured: Settings,
    selectors: list[str] | None,
    request: AutomationRequest | AutomationCampaignRequest,
    run_workspace: Path,
    failure: StepResult,
) -> dict[str, str]:
    workspace = run_workspace
    distribution = getattr(request, "distribution", "mint")
    first_boot = getattr(request, "first_boot", "windows")
    if isinstance(request, AutomationCampaignRequest):
        summary = read_interrupted_campaign_summary(workspace)
        if any("cells" in item for item in summary):
            manifests = {}
            for item in summary:
                distribution, first_boot = str(item["scenario"]).split("-")[:2]
                for vm, cell in item.get("cells", {}).items():
                    if cell.get("status") != "interrupted":
                        continue
                    child = AutomationRequest(
                        apply=True,
                        vms=[vm],
                        distribution=distribution,
                        first_boot=first_boot,
                        linux_username=request.linux_username,
                        linux_password=request.linux_password,
                    )
                    cell_failure = failure.model_copy(
                        update={
                            "context": {**failure.context, "scenario": item["scenario"], "vm": vm}
                        }
                    )
                    manifests.update(
                        _collect_timeout_diagnostics(
                            configured, [vm], child, Path(cell["log"]).parent, cell_failure
                        )
                    )
            return manifests
        interrupted = next(
            (item for item in summary if item["status"] == "interrupted"),
            None,
        )
        if interrupted is not None:
            scenario = str(interrupted["scenario"])
            workspace = (
                Path(str(interrupted["log"])).parent
                if interrupted.get("log")
                else workspace / scenario
            )
            distribution, first_boot = scenario.split("-")[:2]
            selectors = list(interrupted["vms"])
    capture_dir = workspace / "captures"
    capture_dir.mkdir(parents=True, exist_ok=True)
    options = AutomationOptions(
        linux_username=request.linux_username,
        linux_password=request.linux_password,
        monitor_iso=True,
        distribution=load_distribution_profile(distribution),
        first_boot=first_boot,
    )
    selected = ValidationService(configured).select_vms(selectors)

    def collect(vm):
        try:
            path = collect_failure_diagnostics(
                configured,
                vm,
                options,
                capture_dir,
                [failure.model_dump(mode="json")],
                lambda path: VNCClient(configured.vnc_timeout_seconds).capture(vm.vnc, path),
            )
            return vm.name, str(path)
        except Exception as exc:
            return vm.name, f"Collection failed: {type(exc).__name__}: {exc}"

    with ThreadPoolExecutor(max_workers=len(selected)) as pool:
        return dict(pool.map(collect, selected))


def _run_campaign_vm_attempt(
    configured: Settings,
    request: AutomationRequest,
    workspace: Path,
    publish: Callable[[StepResult], None],
    prepared_release: tuple[str, str],
) -> OperationResult:
    context = multiprocessing.get_context("spawn")
    events, sender = context.Pipe(duplex=False)
    worker = context.Process(
        target=_stream_operation_worker,
        args=(
            configured,
            "automation",
            request.selectors(),
            request,
            sender,
            workspace,
            _runtime_provenance(),
            prepared_release,
            True,
        ),
        daemon=True,
    )
    progress = OperationProgress(time.monotonic())
    paused_at: float | None = None
    received: list[StepResult] = []
    outcome: OperationResult | None = None
    last_step = "worker startup"
    try:
        worker.start()
        sender.close()
        while True:
            if events.poll(0.25):
                kind, payload = events.recv()
                if kind == "result":
                    outcome = OperationResult.model_validate(payload)
                    break
                step = StepResult.model_validate(payload)
                received.append(step)
                now = time.monotonic()
                if step.step == "automation.network.restart_required":
                    # This supervisor owns only one VM; never ask the outer API to kill all lanes.
                    publish(
                        step.model_copy(update={"step": "automation.network.vm_restart_required"})
                    )
                    failure = step.model_copy(update={"status": "error"})
                    received[-1] = failure
                    outcome = OperationResult(
                        status="error", operation="automation", message=step.message, steps=received
                    )
                    break
                if step.step == "automation.network.wait":
                    paused_at = paused_at or now
                elif step.step == "automation.network.resumed":
                    if paused_at is not None:
                        progress.exclude_network_pause(now - paused_at)
                    paused_at = None
                if progress.observe(step, now):
                    last_step = step.step
                publish(step)
            elif not worker.is_alive():
                raise RuntimeError(f"VM worker exited without a result (exit={worker.exitcode})")
            if paused_at is None and (
                time.monotonic() - progress.oldest()[1]
                > configured.automation_operation_timeout_seconds
            ):
                failure = StepResult(
                    step="automation.inactivity_timeout",
                    status="error",
                    message=f"VM controller made no progress during {last_step}",
                    context={
                        "last_step": last_step,
                        "timeout_seconds": configured.automation_operation_timeout_seconds,
                    },
                )
                received.append(failure)
                publish(failure)
                outcome = OperationResult(
                    status="error", operation="automation", message=failure.message, steps=received
                )
                break
    except Exception as exc:
        failure = StepResult(
            step="automation.worker_failure",
            status="error",
            message="The isolated VM controller failed",
            context={
                "exception_type": type(exc).__name__,
                "error": str(exc),
                "last_step": last_step,
            },
        )
        received.append(failure)
        publish(failure)
        outcome = OperationResult(
            status="error", operation="automation", message=failure.message, steps=received
        )
    finally:
        if worker.pid is not None:
            worker.join(timeout=5)
            if worker.is_alive():
                worker.kill()
                worker.join()
        sender.close()
        events.close()
    assert outcome is not None
    last_failure_index = max(
        (
            index
            for index, step in enumerate(outcome.steps)
            if step.status == "error" and not step.step.startswith("automation.diagnostics.")
        ),
        default=-1,
    )
    source_changed = any(step.step == "automation.source_changed" for step in outcome.steps)
    if (
        outcome.status != "ok"
        and not source_changed
        and not any(
            step.step == "automation.diagnostics.saved"
            for step in outcome.steps[last_failure_index + 1 :]
        )
    ):
        failures = [step for step in outcome.steps if step.status == "error"]
        failure = (
            failures[-1]
            if failures
            else StepResult(
                step="automation.worker_failure", status="error", message=outcome.message
            )
        )
        if not failures:
            outcome.steps.append(failure)
        try:
            failure.context["diagnostics"] = _collect_timeout_diagnostics(
                configured, request.selectors(), request, workspace, failure
            )
        except Exception as exc:
            failure.context["diagnostics"] = {
                request.vms[0]: f"Collection failed: {type(exc).__name__}: {exc}"
            }
        complete = set(failure.context["diagnostics"]) == set(request.selectors() or [])
        for path in failure.context["diagnostics"].values():
            try:
                complete &= (
                    json.loads(Path(path).read_text(encoding="utf-8")).get("status") == "collected"
                )
            except (OSError, ValueError):
                complete = False
        diagnostic = StepResult(
            step="automation.diagnostics.saved",
            status="ok" if complete else "error",
            message="Interrupted VM evidence collection completed before any snapshot retry",
            context={
                "manifests": failure.context["diagnostics"],
                "collection_status": "collected" if complete else "incomplete",
            },
        )
        outcome.steps.append(diagnostic)
        publish(diagnostic)
    return outcome


def _run_operation(
    configured: Settings,
    operation: OperationName,
    selectors: list[str] | None,
    request: ValidationRequest | AutomationRequest | None,
    on_step: Callable[[StepResult], None] | None = None,
    run_workspace: Path | None = None,
    prepared_release: tuple[str, str] | None = None,
) -> OperationResult:
    if operation == "validation":
        validation = request if isinstance(request, ValidationRequest) else ValidationRequest()
        return ValidationService(configured).run(
            selectors,
            source=validation.source,
            on_step=on_step,
            run_workspace=run_workspace,
        )
    if operation == "automation":
        if isinstance(request, AutomationCampaignRequest):
            if run_workspace is None:
                raise ValueError("The complete campaign requires an isolated operation workspace")
            selected = ValidationService(configured).select_vms(selectors)
            if len(selected) != 3 or not all(vm.automation_enabled for vm in selected):
                raise ValueError("The complete campaign requires exactly three enabled test VMs")
            if any(vm.host == configured.build_vm_host for vm in selected):
                raise ValueError("Independent campaign lanes require a separate build VM")
            validation = ValidationService(configured)
            build = ResultBuilder("automation", on_step=on_step)
            executable = validation.prepare_server(build, source=request.source)
            with validation.ssh(
                configured.main_ssh_host,
                configured.main_ssh_user,
                configured.main_ssh_password.get_secret_value(),
            ) as ssh:
                response = ssh.run(
                    f"sha256sum -- {shlex.quote(str(executable))}",
                    step="automation.release_provenance",
                    timeout=120,
                    replay_safe=True,
                )
            digest = response.stdout.split()[0] if response.stdout.split() else ""
            if re.fullmatch(r"[0-9a-f]{64}", digest) is None:
                raise ValueError("The campaign executable hash is unavailable")
            prepared_release = (str(validation.to_windows_share_path(executable)), digest)
            (run_workspace / "release-provenance.json").write_text(
                json.dumps(
                    {
                        "executable": prepared_release[0],
                        "sha256": digest,
                        "build_steps": [step.model_dump(mode="json") for step in build.steps],
                    },
                    indent=2,
                ),
                encoding="utf-8",
            )
            return run_campaign(
                request,
                [vm.name for vm in selected],
                run_workspace,
                lambda child, workspace, publish: _run_campaign_vm_attempt(
                    configured, child, workspace, publish, prepared_release
                ),
                on_step,
                vm_firmwares={vm.name: vm.firmware for vm in selected},
            )
        if not isinstance(request, AutomationRequest):
            raise ValueError("Automation request body is required")
        automation_settings = configured
        if request.snapshot_mode == "secondary-disk":
            # Keep the shared server settings and later default/reset requests unchanged.
            automation_settings = configured.model_copy(
                update={"reset_snapshot": configured.secondary_disk_reset_snapshot}
            )
        elif request.local_filepool:
            selected = ValidationService(configured).select_vms(selectors)
            if len(selected) == 1 and selected[0].local_filepool_snapshot:
                automation_settings = configured.model_copy(
                    update={"reset_snapshot": selected[0].local_filepool_snapshot}
                )
        if prepared_release is not None:
            # Each lane still reserves headroom for all three concurrently running test VMs.
            automation_settings = automation_settings.model_copy(
                update={
                    "proxmox_storage_min_free_gib": max(
                        configured.proxmox_storage_min_free_gib,
                        3 * configured.proxmox_storage_min_free_per_vm_gib,
                    )
                }
            )
        return AutomationService(automation_settings).run(
            selectors,
            linux_username=request.linux_username,
            linux_password=request.linux_password,
            linux_size_gib=request.linux_size_gib,
            installation_target=request.installation_target,
            expected_compatibility_refusal=request.expected_compatibility_refusal,
            local_filepool=request.local_filepool,
            distribution=request.distribution,
            monitor_iso=request.monitor_iso,
            share_windows_files_in_linux=request.share_windows_files_in_linux,
            share_linux_files_in_windows=request.share_linux_files_in_windows,
            migrate_windows_preferences=request.migrate_windows_preferences,
            preference_wallpaper=request.preference_wallpaper,
            storage_fixture=request.storage_fixture,
            secondary_snapshot=request.snapshot_mode == "secondary-disk",
            simulate_stale_firmware_entries=request.simulate_stale_firmware_entries,
            force_offline_ntfs_resize=request.force_offline_ntfs_resize,
            boot_guardian_fault=request.boot_guardian_fault,
            verify_uninstall=request.verify_uninstall,
            first_boot=request.first_boot,
            source=request.source,
            on_step=on_step,
            run_workspace=run_workspace,
            prepared_release=prepared_release,
        )
    return ResetService(configured).run(selectors, on_step=on_step)


def _stream_operation_worker(
    configured: Settings,
    operation: OperationName,
    selectors: list[str] | None,
    request: ValidationRequest | AutomationRequest | None,
    process_events: Connection,
    run_workspace: Path,
    server_provenance: dict[str, object] | None = None,
    prepared_release: tuple[str, str] | None = None,
    campaign_cell: bool = False,
) -> None:
    parent = multiprocessing.parent_process()
    if parent is not None:

        def stop_with_parent() -> None:
            wait_connections([parent.sentinel])
            os._exit(1)

        threading.Thread(target=stop_with_parent, daemon=True).start()
    mark_capture_workspace_owned(run_workspace)
    configure_logging(configured.log_level, run_workspace / "logs")
    (run_workspace / "runtime-provenance.json").write_text(
        json.dumps({"server": server_provenance, "worker": _runtime_provenance()}, indent=2),
        encoding="utf-8",
    )
    fatal_output = (run_workspace / "worker-fatal.log").open(
        "a",
        encoding="utf-8",
        buffering=1,
    )
    faulthandler.enable(file=fatal_output, all_threads=True)
    event_stream_available = True
    publish_lock = threading.Lock()

    def publish(event_type: str, payload: object) -> None:
        nonlocal event_stream_available
        with publish_lock:
            if not event_stream_available:
                return
            try:
                process_events.send((event_type, payload))
            except (BrokenPipeError, EOFError, OSError):
                event_stream_available = False

    def on_step(step: StepResult) -> None:
        publish("step", step.model_dump(mode="json"))

    try:
        if (
            (campaign_cell or isinstance(request, AutomationCampaignRequest))
            and server_provenance is not None
            and (server_provenance.get("source_sha256_at_import") != SOURCE_AT_IMPORT)
        ):
            message = (
                "The Python sources changed after campaign startup; refusing mixed controllers"
            )
            result = OperationResult(
                status="error",
                operation=operation,
                message=message,
                steps=[
                    StepResult(
                        step=f"{operation}.source_changed",
                        status="error",
                        message=message,
                    )
                ],
            )
        else:
            if campaign_cell and configured.automation_network_ping_hosts:
                network_recovery.active = network_recovery.NetworkRecovery(
                    configured.automation_network_ping_hosts, on_step
                )
            result = _run_operation(
                configured,
                operation,
                selectors,
                request,
                on_step,
                run_workspace,
                prepared_release,
            )
    except Exception as exc:
        logger.exception("Unexpected internal error in %s stream", operation)
        result = OperationResult(
            status="error",
            operation=operation,
            message="error: unexpected internal failure",
            steps=[
                StepResult(
                    step=f"{operation}.internal_error",
                    status="error",
                    message="Unexpected internal error; inspect the server logs",
                    context={"exception_type": type(exc).__name__},
                )
            ],
        )
    finally:
        network_recovery.active = None
    try:
        # vncdotool keeps a Twisted reactor for reuse inside an operation. The
        # isolated worker has no later VNC work after its terminal result, so
        # stop that reactor before asking multiprocessing to exit.
        vnc_api.shutdown()
    except Exception:
        logger.exception("VNC runtime shutdown failed after %s", operation)
    publish("result", result.model_dump(mode="json"))
    process_events.close()
    faulthandler.disable()
    fatal_output.close()


def create_app(settings: Settings | None = None) -> FastAPI:
    configured = settings or get_settings()
    operation_process = ActiveOperationProcess()

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        configure_logging(configured.log_level, configured.operation_log_dir)
        configured.capture_dir.mkdir(parents=True, exist_ok=True)
        cleanup_operation_artifacts(configured)
        yield

    api = FastAPI(
        title="Libertix Automated Validation",
        version="0.1.0",
        description=(
            "Controlled SSH, VNC, vision-model, and Proxmox validation for Libertix test VMs."
        ),
        lifespan=lifespan,
    )
    api.state.settings = configured
    api.state.operation_process = operation_process

    filepool_dir = Path(__file__).resolve().parent / "filepool"

    @api.api_route("/filepool/catalog.json", methods=["GET", "HEAD"], include_in_schema=False)
    async def filepool_distribution_metadata() -> FileResponse:
        metadata = _resolve_distribution_metadata(configured.runtime_dir, filepool_dir)
        if metadata is None:
            raise HTTPException(status_code=404, detail="Distribution catalog is unavailable")
        return FileResponse(metadata, media_type="application/json")

    @api.api_route("/filepool/{filename}", methods=["GET", "HEAD"], include_in_schema=False)
    async def filepool_artifact(filename: str) -> FileResponse:
        artifact = filepool_dir / filename
        if not artifact.is_file():
            raise HTTPException(status_code=404, detail="Filepool artifact is unavailable")
        return FileResponse(artifact)

    async def execute(
        operation: OperationName,
        selectors: list[str] | None = None,
        request: ValidationRequest | AutomationRequest | None = None,
    ) -> OperationResult:
        if not operation_lock.acquire(blocking=False):
            return _operation_busy_result(operation)
        try:
            run_workspace = create_capture_workspace(configured, operation)
        except BaseException:
            operation_lock.release()
            raise
        projector = StreamEventProjector(operation, run_workspace)
        try:
            result = await asyncio.to_thread(
                _run_operation,
                configured,
                operation,
                selectors,
                request,
                projector.project_step,
                run_workspace,
            )
            projector.project_result(result)
            return result
        finally:
            operation_lock.release()
            _finalize_operation_workspace(configured, run_workspace)

    def stream_operation(
        operation: OperationName,
        selectors: list[str] | None = None,
        request: ValidationRequest | AutomationRequest | None = None,
        stream_format: Literal["compact", "ndjson"] = "compact",
    ):
        events: queue.Queue[tuple[str, str | int | None]] = queue.Queue()

        terminal_result_seen = threading.Event()
        independent_lanes_started = threading.Event()
        terminal_result_lock = threading.Lock()
        timeout_cleanup_started = threading.Event()
        timeout_cleanup_finished = threading.Event()

        latest_steps: dict[str, str] = {}
        latest_steps_lock = threading.Lock()
        automation_progress = threading.Event()
        automation_progress_lock = threading.Lock()
        progress_clock = OperationProgress(time.monotonic())

        network_waiting = threading.Event()
        network_restart: StepResult | None = None
        network_paused_at: float | None = None

        if not operation_lock.acquire(blocking=False):
            result = _operation_busy_result(operation)
            events.put(
                (
                    "data",
                    StreamEventProjector.render(
                        _unpersisted_result_event(result),
                        stream_format=stream_format,
                    ),
                )
            )
            events.put(("exit", 0))

            async def rejected_generator():
                while True:
                    event_type, payload = await asyncio.to_thread(events.get)
                    if event_type == "data":
                        yield str(payload)
                        continue
                    break

            return rejected_generator()

        try:
            run_workspace = create_capture_workspace(configured, operation)
        except BaseException:
            operation_lock.release()
            raise
        projector = StreamEventProjector(operation, run_workspace)

        def publish_result(result: OperationResult, stream_format: str) -> None:
            with terminal_result_lock:
                if terminal_result_seen.is_set():
                    return
                if isinstance(request, AutomationCampaignRequest) and not result.campaign_summary:
                    result.campaign_summary = read_interrupted_campaign_summary(run_workspace)
                event = projector.project_result(result)
                terminal_result_seen.set()
                automation_progress.set()
                events.put(("data", projector.render(event, stream_format=stream_format)))

        # The worker owns the operation; the relay only publishes its evidence
        # and tracks progress so an unresponsive worker can be diagnosed.
        process_context = multiprocessing.get_context("spawn")
        process_events, worker_events = process_context.Pipe(duplex=False)

        def relay_process_events() -> None:
            nonlocal network_restart, network_paused_at
            try:
                while True:
                    if not process_events.poll(0.1):
                        if not process.is_alive():
                            return
                        continue
                    event_type, payload = process_events.recv()
                    if event_type == "step":
                        step = StepResult.model_validate(payload)
                        if step.step == "automation.campaign_plan" and step.context.get(
                            "independent_vms"
                        ):
                            independent_lanes_started.set()

                        with automation_progress_lock:
                            now = time.monotonic()
                            if step.step == "automation.network.wait":
                                if network_paused_at is None:
                                    network_paused_at = now
                                network_waiting.set()
                            elif step.step == "automation.network.resumed":
                                if network_paused_at is not None:
                                    progress_clock.exclude_network_pause(now - network_paused_at)
                                network_paused_at = None
                                network_waiting.clear()
                            elif step.step == "automation.network.restart_required":
                                network_restart = step
                            advanced = step.step.startswith(
                                "automation.network."
                            ) or progress_clock.observe(step, now)
                        if advanced:
                            automation_progress.set()

                        vm = str(step.context.get("vm") or step.context.get("target") or "global")
                        with latest_steps_lock:
                            label = step.step
                            if step.context.get("test"):
                                label += ":" + str(step.context["test"])
                            if advanced or step.status == "error":
                                latest_steps[vm] = label
                                if "vm" not in step.context:
                                    latest_steps["global"] = label
                        event = projector.project_step(step)
                        if event is not None:
                            events.put(
                                (
                                    "data",
                                    projector.render(event, stream_format=stream_format),
                                )
                            )
                        continue

                    if event_type == "result":
                        publish_result(OperationResult.model_validate(payload), stream_format)
                        # All operation cleanup has completed before the worker
                        # publishes its result. Do not let an unexpected library
                        # thread keep the global operation lock forever.
                        process.join(timeout=5)
                        if process.is_alive():
                            logger.warning(
                                "Terminating an operation worker that remained alive "
                                "after its terminal result",
                                extra={"step": f"{operation}.process_exit"},
                            )
                            process.terminate()
                        return
            except (EOFError, OSError):
                return
            finally:
                process_events.close()

        process = process_context.Process(
            target=_stream_operation_worker,
            args=(
                configured,
                operation,
                selectors,
                request,
                worker_events,
                run_workspace,
                _runtime_provenance(),
            ),
            daemon=not isinstance(request, AutomationCampaignRequest),
        )
        try:
            process.start()
            worker_events.close()
            operation_process.register(process, operation)
        except Exception:
            process_events.close()
            worker_events.close()
            operation_lock.release()
            _finalize_operation_workspace(configured, run_workspace)
            raise

        relay_thread = threading.Thread(target=relay_process_events, daemon=True)
        relay_thread.start()

        def terminate_and_collect(result: OperationResult) -> None:
            timeout_cleanup_started.set()
            try:
                # Keep the lock until the old controller is stopped and its evidence saved.
                process.terminate()
                process.join()

                failure = result.steps[0]
                event = projector.project_step(
                    StepResult(
                        step="automation.diagnostics.wait",
                        status="ok",
                        message="Interrupted worker stopped; saving VM screenshots and logs "
                        "before releasing the campaign lock",
                        context=dict(failure.context),
                    )
                )
                events.put(("data", projector.render(event, stream_format=stream_format)))
                failure.context["diagnostics"] = _collect_timeout_diagnostics(
                    configured, selectors, request, run_workspace, failure
                )
            except Exception as exc:
                result.steps[0].context["diagnostics_error"] = f"{type(exc).__name__}: {exc}"
            finally:
                try:
                    publish_result(result, stream_format)
                finally:
                    timeout_cleanup_finished.set()

        def enforce_automation_timeout() -> None:
            if operation != "automation":
                return
            while True:
                automation_progress.clear()
                if terminal_result_seen.is_set() or not process.is_alive():
                    return
                if independent_lanes_started.is_set():
                    # Each isolated lane has its own progress clock and network pause budget.
                    automation_progress.wait(5)
                    continue
                if network_restart is not None:
                    terminate_and_collect(
                        OperationResult(
                            status="error",
                            operation="automation",
                            message="Network restored; the current scenario needs a clean restart",
                            steps=[network_restart.model_copy(update={"status": "error"})],
                        )
                    )
                    return
                if network_waiting.is_set():
                    automation_progress.wait(5)
                    continue
                with automation_progress_lock:
                    stalled_vm, last_progress = progress_clock.oldest()
                    idle_seconds = time.monotonic() - last_progress
                remaining_seconds = configured.automation_operation_timeout_seconds - idle_seconds
                if remaining_seconds > 0 and automation_progress.wait(remaining_seconds):
                    continue
                if terminal_result_seen.is_set() or not process.is_alive():
                    return
                if network_waiting.is_set() or network_restart is not None:
                    continue

                with automation_progress_lock:
                    stalled_vm, last_progress = progress_clock.oldest()
                    idle_seconds = time.monotonic() - last_progress
                if idle_seconds < configured.automation_operation_timeout_seconds:
                    continue
                captures, capture_errors = _capture_automation_timeout_screens(
                    configured,
                    selectors,
                    run_workspace,
                )
                if terminal_result_seen.is_set() or not process.is_alive():
                    return
                if network_waiting.is_set() or network_restart is not None:
                    continue
                with automation_progress_lock:
                    stalled_vm, last_progress = progress_clock.oldest()
                    if (
                        time.monotonic() - last_progress
                        < configured.automation_operation_timeout_seconds
                    ):
                        continue
                with latest_steps_lock:
                    active_steps = dict(latest_steps)

                result = OperationResult(
                    status="error",
                    operation="automation",
                    message="error: automation made no progress before its configured timeout",
                    steps=[
                        StepResult(
                            step="automation.inactivity_timeout",
                            status="error",
                            message=(
                                f"No progress on {stalled_vm}: "
                                f"{active_steps.get(stalled_vm, 'global preparation')}"
                            ),
                            context={
                                "inactivity_timeout_seconds": (
                                    configured.automation_operation_timeout_seconds
                                ),
                                "active_steps": active_steps,
                                "stalled_vm": stalled_vm,
                                "stalled_step": active_steps.get(stalled_vm, "global preparation"),
                                "captures": captures,
                                "capture_errors": capture_errors,
                            },
                        )
                    ],
                )
                terminate_and_collect(result)
                return

        threading.Thread(target=enforce_automation_timeout, daemon=True).start()

        def watch_process() -> None:
            try:
                process.join()
                relay_thread.join()
                if timeout_cleanup_started.is_set():
                    timeout_cleanup_finished.wait()

                if not terminal_result_seen.is_set():
                    exit_code = process.exitcode if process.exitcode is not None else -1
                    forced = exit_code < 0
                    diagnostic_context = (
                        _worker_fatal_diagnostic_context(run_workspace) if forced else {}
                    )
                    result = OperationResult(
                        status="error",
                        operation=operation,
                        message=(
                            "error: operation was forcibly terminated"
                            if forced
                            else "error: operation process exited unexpectedly"
                        ),
                        steps=[
                            StepResult(
                                step=(
                                    f"{operation}.force_killed"
                                    if forced
                                    else f"{operation}.process_exit"
                                ),
                                status="error",
                                message=(
                                    "Operation was forcibly terminated without cleanup"
                                    if forced
                                    else "Operation process exited without a terminal result"
                                ),
                                context={"exit_code": exit_code, **diagnostic_context},
                            )
                        ],
                    )
                    publish_result(result, stream_format)
            except Exception:
                logger.exception(
                    "Operation watcher failed",
                    extra={"step": f"{operation}.watcher"},
                )
            finally:
                operation_process.clear(process)
                operation_lock.release()
                _finalize_operation_workspace(configured, run_workspace)
                events.put(("exit", process.exitcode))

        threading.Thread(target=watch_process, daemon=True).start()

        async def generator():
            while True:
                event_type, payload = await asyncio.to_thread(events.get)
                if event_type == "data":
                    yield str(payload)
                    continue
                if event_type == "exit":
                    break

        return generator()

    async def execute_isolated_automation(
        selectors: list[str] | None,
        request: AutomationRequest | AutomationCampaignRequest,
    ) -> OperationResult:
        terminal_result: OperationResult | None = None
        async for payload in stream_operation(
            "automation",
            selectors,
            request,
            stream_format="ndjson",
        ):
            for line in payload.splitlines():
                event = json.loads(line)
                if event.get("event") == "result":
                    terminal_result = OperationResult.model_validate(event.get("data"))
        if terminal_result is None:
            raise RuntimeError("Isolated automation ended without a terminal result")
        return terminal_result

    @api.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @api.get("/", response_class=HTMLResponse)
    async def web_ui() -> HTMLResponse:
        html_path = Path(__file__).resolve().parent / "web" / "index.html"
        return HTMLResponse(html_path.read_text(encoding="utf-8"))

    @api.get("/api/v1/vms")
    async def configured_vms() -> dict[str, object]:
        return {
            "vms": [
                {
                    "name": vm.name,
                    "host": vm.host,
                    "os": vm.os,
                    "vnc": vm.vnc,
                    "username": vm.username,
                }
                for vm in configured.vms
            ]
        }

    @api.post(
        "/api/v1/operation/kill",
        status_code=202,
    )
    async def kill_operation() -> dict[str, object]:
        killed = operation_process.kill_active()
        if killed is None:
            raise HTTPException(status_code=409, detail="No isolated operation is currently active")
        return {
            "status": "killing",
            "operation": killed.operation,
            "pid": killed.pid,
            "warning": (
                "The operation was terminated without cleanup; the API server remains active."
            ),
        }

    @api.post(
        "/api/v1/validation",
        response_model=OperationResult,
    )
    async def validation(
        body: Annotated[ValidationRequest | None, Body()] = None,
        vm: Annotated[list[str] | None, Query()] = None,
        source: Annotated[SourceMode | None, Query()] = None,
    ) -> OperationResult:
        selectors, request = validation_request(body, vm, source)
        return await execute("validation", selectors, request)

    @api.post(
        "/api/v1/automation",
        response_model=OperationResult,
    )
    async def automation(
        body: Annotated[AutomationRequest, Body()],
        vm: Annotated[list[str] | None, Query()] = None,
        source: Annotated[SourceMode | None, Query()] = None,
    ) -> OperationResult:
        selectors, request = automation_request(body, vm, source)
        return await execute_isolated_automation(selectors, request)

    @api.post("/api/v1/automation/full", response_model=OperationResult)
    async def automation_full(body: AutomationCampaignRequest) -> OperationResult:
        return await execute_isolated_automation(body.selectors(), body)

    @api.post("/api/v1/automation/full/stream")
    async def automation_full_stream(
        body: AutomationCampaignRequest,
        format: Annotated[Literal["compact", "ndjson"], Query()] = "compact",
    ) -> StreamingResponse:
        return StreamingResponse(
            stream_operation("automation", body.selectors(), body, format),
            media_type="application/x-ndjson" if format == "ndjson" else "text/plain",
        )

    @api.post("/api/v1/validation/stream")
    async def validation_stream(
        body: Annotated[ValidationRequest | None, Body()] = None,
        vm: Annotated[list[str] | None, Query()] = None,
        source: Annotated[SourceMode | None, Query()] = None,
        format: Annotated[Literal["compact", "ndjson"], Query()] = "compact",
    ) -> StreamingResponse:
        selectors, request = validation_request(body, vm, source)
        return StreamingResponse(
            stream_operation("validation", selectors, request, format),
            media_type="application/x-ndjson" if format == "ndjson" else "text/plain",
        )

    @api.post("/api/v1/automation/stream")
    async def automation_stream(
        body: Annotated[AutomationRequest, Body()],
        vm: Annotated[list[str] | None, Query()] = None,
        source: Annotated[SourceMode | None, Query()] = None,
        format: Annotated[Literal["compact", "ndjson"], Query()] = "compact",
    ) -> StreamingResponse:
        selectors, request = automation_request(body, vm, source)
        return StreamingResponse(
            stream_operation("automation", selectors, request, format),
            media_type="application/x-ndjson" if format == "ndjson" else "text/plain",
        )

    @api.post(
        "/api/v1/reset",
        response_model=OperationResult,
    )
    async def reset(vm: Annotated[list[str] | None, Query()] = None) -> OperationResult:
        return await execute("reset", vm)

    @api.post("/api/v1/reset/stream")
    async def reset_stream(
        vm: Annotated[list[str] | None, Query()] = None,
        format: Annotated[Literal["compact", "ndjson"], Query()] = "compact",
    ) -> StreamingResponse:
        return StreamingResponse(
            stream_operation("reset", vm, stream_format=format),
            media_type="application/x-ndjson" if format == "ndjson" else "text/plain",
        )

    return api


class LazyApp:
    def __init__(self) -> None:
        self._app: FastAPI | None = None
        self._lock = threading.Lock()

    async def __call__(self, scope, receive, send) -> None:
        if self._app is None:
            with self._lock:
                if self._app is None:
                    self._app = create_app()
        await self._app(scope, receive, send)


app = LazyApp()
