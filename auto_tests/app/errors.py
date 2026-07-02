from __future__ import annotations


class WorkflowError(RuntimeError):
    """Failure carrying a safe, actionable workflow context."""

    def __init__(self, step: str, message: str, *, details: dict | None = None) -> None:
        super().__init__(message)
        self.step = step
        self.message = message
        self.details = details or {}

    def as_dict(self) -> dict:
        return {"step": self.step, "message": self.message, "details": self.details}
