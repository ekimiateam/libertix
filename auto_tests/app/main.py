from __future__ import annotations

import asyncio
import logging
import multiprocessing
import queue
import threading
from collections.abc import Callable
from contextlib import asynccontextmanager
from multiprocessing.connection import Connection
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
from app.clients.vnc import VNCClient
from app.config import Settings, get_settings
from app.logging_config import configure_logging
from app.models import (
    AutomationRequest,
    OperationResult,
    SourceMode,
    StepResult,
    ValidationRequest,
)
from app.services.automation import AutomationService
from app.services.reset import ResetService
from app.services.validation import ValidationService
from app.stream_events import StreamEventProjector

logger = logging.getLogger(__name__)
OperationName = Literal["validation", "reset", "automation"]


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


def _run_operation(
    configured: Settings,
    operation: OperationName,
    selectors: list[str] | None,
    request: ValidationRequest | AutomationRequest | None,
    on_step: Callable[[StepResult], None] | None = None,
    run_workspace: Path | None = None,
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
        if not isinstance(request, AutomationRequest):
            raise ValueError("Automation request body is required")
        return AutomationService(configured).run(
            selectors,
            linux_username=request.linux_username,
            linux_password=request.linux_password,
            linux_size_gib=request.linux_size_gib,
            distribution=request.distribution,
            monitor_iso=request.monitor_iso,
            share_windows_files_in_linux=request.share_windows_files_in_linux,
            share_linux_files_in_windows=request.share_linux_files_in_windows,
            simulate_stale_firmware_entries=request.simulate_stale_firmware_entries,
            force_offline_ntfs_resize=request.force_offline_ntfs_resize,
            first_boot=request.first_boot,
            source=request.source,
            on_step=on_step,
            run_workspace=run_workspace,
        )
    return ResetService(configured).run(selectors, on_step=on_step)


def _stream_operation_worker(
    configured: Settings,
    operation: OperationName,
    selectors: list[str] | None,
    request: ValidationRequest | AutomationRequest | None,
    process_events: Connection,
    run_workspace: Path,
) -> None:
    mark_capture_workspace_owned(run_workspace)
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
        result = _run_operation(
            configured,
            operation,
            selectors,
            request,
            on_step,
            run_workspace,
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
    try:
        # vncdotool keeps a Twisted reactor for reuse inside an operation. The
        # isolated worker has no later VNC work after its terminal result, so
        # stop that reactor before asking multiprocessing to exit.
        vnc_api.shutdown()
    except Exception:
        logger.exception("VNC runtime shutdown failed after %s", operation)
    publish("result", result.model_dump(mode="json"))
    process_events.close()


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
        terminal_result_lock = threading.Lock()
        latest_steps: dict[str, str] = {}
        latest_steps_lock = threading.Lock()

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
                event = projector.project_result(result)
                terminal_result_seen.set()
                events.put(("data", projector.render(event, stream_format=stream_format)))

        process_context = multiprocessing.get_context("spawn")
        process_events, worker_events = process_context.Pipe(duplex=False)

        def relay_process_events() -> None:
            try:
                while True:
                    if not process_events.poll(0.1):
                        if not process.is_alive():
                            return
                        continue
                    event_type, payload = process_events.recv()
                    if event_type == "step":
                        step = StepResult.model_validate(payload)
                        vm = str(step.context.get("vm") or step.context.get("target") or "global")
                        with latest_steps_lock:
                            latest_steps[vm] = step.step
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
            args=(configured, operation, selectors, request, worker_events, run_workspace),
            daemon=True,
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

        def enforce_automation_timeout() -> None:
            if operation != "automation":
                return
            if terminal_result_seen.wait(configured.automation_operation_timeout_seconds):
                return
            if not process.is_alive():
                return

            captures, capture_errors = _capture_automation_timeout_screens(
                configured,
                selectors,
                run_workspace,
            )
            if terminal_result_seen.is_set() or not process.is_alive():
                return
            with latest_steps_lock:
                active_steps = dict(latest_steps)
            result = OperationResult(
                status="error",
                operation="automation",
                message="error: automation exceeded its configured global timeout",
                steps=[
                    StepResult(
                        step="automation.global_timeout",
                        status="error",
                        message="Automation exceeded its configured global timeout",
                        context={
                            "timeout_seconds": configured.automation_operation_timeout_seconds,
                            "active_steps": active_steps,
                            "captures": captures,
                            "capture_errors": capture_errors,
                        },
                    )
                ],
            )
            publish_result(result, stream_format)
            process.terminate()

        threading.Thread(target=enforce_automation_timeout, daemon=True).start()

        def watch_process() -> None:
            try:
                process.join()
                relay_thread.join()
                if not terminal_result_seen.is_set():
                    exit_code = process.exitcode if process.exitcode is not None else -1
                    forced = exit_code < 0
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
                                context={"exit_code": exit_code},
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
            raise HTTPException(status_code=409, detail="No streamed operation is currently active")
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
        return await execute("automation", selectors, request)

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
