from __future__ import annotations

import asyncio
import hmac
import json
import queue
import threading
from contextlib import asynccontextmanager
from pathlib import Path
from threading import Lock
from typing import Annotated, Literal

from fastapi import Body, Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import HTMLResponse, StreamingResponse

from app.config import Settings, get_settings
from app.logging_config import configure_logging
from app.models import OperationResult, StepResult, ValidationRequest
from app.services.reset import ResetService
from app.services.validation import ValidationService

operation_lock = Lock()


def create_app(settings: Settings | None = None) -> FastAPI:
    configured = settings or get_settings()

    @asynccontextmanager
    async def lifespan(_app: FastAPI):
        configure_logging(configured.log_level)
        configured.capture_dir.mkdir(parents=True, exist_ok=True)
        yield

    api = FastAPI(
        title="LinuxGate Automated Validation",
        version="0.1.0",
        description="Validation SSH/VNC/LLM vision et reset contrôlé Proxmox.",
        lifespan=lifespan,
    )
    api.state.settings = configured

    def authorize(x_api_key: str = Header(..., alias="X-API-Key")) -> None:
        expected = configured.api_access_token.get_secret_value()
        if not hmac.compare_digest(x_api_key, expected):
            raise HTTPException(status_code=401, detail="Clé API invalide")

    def validation_selectors(
        body: ValidationRequest | None, query_vms: list[str] | None
    ) -> list[str] | None:
        selectors: list[str] = []
        if body:
            selectors.extend(body.selectors() or [])
        if query_vms:
            selectors.extend(query_vms)
        return selectors or None

    async def execute(operation: str, selectors: list[str] | None = None) -> OperationResult:
        if not operation_lock.acquire(blocking=False):
            return OperationResult(
                status="problème",
                operation=operation,  # type: ignore[arg-type]
                message="problème: une autre opération est déjà en cours",
                steps=[],
            )
        try:
            if operation == "validation":
                return await asyncio.to_thread(ValidationService(configured).run, selectors)
            return await asyncio.to_thread(ResetService(configured).run)
        finally:
            operation_lock.release()

    def stream_operation(
        operation: Literal["validation", "reset"], selectors: list[str] | None = None
    ):
        events: queue.Queue[dict | None] = queue.Queue()
        if not operation_lock.acquire(blocking=False):
            result = OperationResult(
                status="problème",
                operation=operation,
                message="problème: une autre opération est déjà en cours",
                steps=[],
            )
            events.put({"event": "result", "data": result.model_dump(mode="json")})
            events.put(None)
        else:

            def on_step(step: StepResult) -> None:
                events.put({"event": "step", "data": step.model_dump(mode="json")})

            def worker() -> None:
                try:
                    if operation == "validation":
                        result = ValidationService(configured).run(selectors, on_step=on_step)
                    else:
                        result = ResetService(configured).run(on_step=on_step)
                    events.put({"event": "result", "data": result.model_dump(mode="json")})
                finally:
                    operation_lock.release()
                    events.put(None)

            threading.Thread(target=worker, daemon=True).start()

        async def generator():
            while True:
                event = await asyncio.to_thread(events.get)
                if event is None:
                    break
                yield json.dumps(event, ensure_ascii=False) + "\n"

        return generator()

    @api.get("/health")
    async def health() -> dict[str, str]:
        return {"status": "ok"}

    @api.get("/", response_class=HTMLResponse)
    async def web_ui() -> HTMLResponse:
        html_path = Path(__file__).resolve().parent / "web" / "index.html"
        return HTMLResponse(html_path.read_text(encoding="utf-8"))

    @api.get("/api/v1/vms", dependencies=[Depends(authorize)])
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
        "/api/v1/validation", response_model=OperationResult, dependencies=[Depends(authorize)]
    )
    async def validation(
        body: Annotated[ValidationRequest | None, Body()] = None,
        vm: Annotated[list[str] | None, Query()] = None,
    ) -> OperationResult:
        return await execute("validation", validation_selectors(body, vm))

    @api.post("/api/v1/validation/stream", dependencies=[Depends(authorize)])
    async def validation_stream(
        body: Annotated[ValidationRequest | None, Body()] = None,
        vm: Annotated[list[str] | None, Query()] = None,
    ) -> StreamingResponse:
        return StreamingResponse(
            stream_operation("validation", validation_selectors(body, vm)),
            media_type="application/x-ndjson",
        )

    @api.post("/api/v1/reset", response_model=OperationResult, dependencies=[Depends(authorize)])
    async def reset() -> OperationResult:
        return await execute("reset")

    @api.post("/api/v1/reset/stream", dependencies=[Depends(authorize)])
    async def reset_stream() -> StreamingResponse:
        return StreamingResponse(stream_operation("reset"), media_type="application/x-ndjson")

    return api


app = create_app()
