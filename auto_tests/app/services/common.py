from __future__ import annotations

import logging
from collections.abc import Callable

from app.errors import WorkflowError
from app.models import OperationResult, StepResult

logger = logging.getLogger(__name__)


class ResultBuilder:
    def __init__(self, operation: str, on_step: Callable[[StepResult], None] | None = None) -> None:
        self.operation = operation
        self.steps: list[StepResult] = []
        self.on_step = on_step
        self._failed = False

    def ok(self, step: str, message: str, **context: object) -> None:
        item = StepResult(step=step, status="ok", message=message, context=context)
        self.steps.append(item)
        if self.on_step:
            self.on_step(item)
        logger.info(message, extra={"step": step, "target": str(context.get("target", ""))})

    def success(self, message: str) -> OperationResult:
        if self._failed or any(step.status == "problème" for step in self.steps):
            return OperationResult(
                status="problème",
                operation=self.operation,
                message="problème: une étape fatale a échoué",
                steps=self.steps,  # type: ignore[arg-type]
            )
        return OperationResult(
            status="ok",
            operation=self.operation,
            message=message,
            steps=self.steps,  # type: ignore[arg-type]
        )

    def failure(self, error: WorkflowError) -> OperationResult:
        self._failed = True
        details = dict(error.details)
        details.setdefault("exception_type", type(error).__name__)
        item = StepResult(
            step=error.step, status="problème", message=error.message, context=details
        )
        self.steps.append(item)
        if self.on_step:
            self.on_step(item)
        logger.error(
            error.message, extra={"step": error.step, "target": str(details.get("host", ""))}
        )
        return OperationResult(
            status="problème",
            operation=self.operation,  # type: ignore[arg-type]
            message=f"problème: {error.message}",
            steps=self.steps,
        )
