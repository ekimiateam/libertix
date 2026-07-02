from __future__ import annotations

import logging
import traceback
from collections.abc import Callable

from app.errors import WorkflowError
from app.models import OperationResult, StepResult

logger = logging.getLogger(__name__)


class ResultBuilder:
    def __init__(self, operation: str, on_step: Callable[[StepResult], None] | None = None) -> None:
        self.operation = operation
        self.steps: list[StepResult] = []
        self.on_step = on_step

    def ok(self, step: str, message: str, **context: object) -> None:
        item = StepResult(step=step, status="ok", message=message, context=context)
        self.steps.append(item)
        if self.on_step:
            self.on_step(item)
        logger.info(message, extra={"step": step, "target": str(context.get("target", ""))})

    def success(self, message: str) -> OperationResult:
        return OperationResult(
            status="ok",
            operation=self.operation,
            message=message,
            steps=self.steps,  # type: ignore[arg-type]
        )

    def failure(self, error: WorkflowError) -> OperationResult:
        error.details.setdefault("exception_type", type(error).__name__)
        current_traceback = traceback.format_exc()
        if current_traceback.strip() != "NoneType: None":
            error.details.setdefault("python_traceback", current_traceback[-8000:])
        item = StepResult(
            step=error.step, status="problème", message=error.message, context=error.details
        )
        self.steps.append(item)
        if self.on_step:
            self.on_step(item)
        logger.error(
            error.message, extra={"step": error.step, "target": str(error.details.get("host", ""))}
        )
        return OperationResult(
            status="problème",
            operation=self.operation,  # type: ignore[arg-type]
            message=f"problème: {error.message}",
            steps=self.steps,
        )
