#!/usr/bin/env python3
"""Apply durable, validated Libertix installation-state transitions."""

from __future__ import annotations

import argparse
import contextlib
import json
import os
import re
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from libertix_json_schema import validate_json_schema

HEX_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
STEP_PATTERN = re.compile(r"^(windows|live|target)\.[a-z0-9]+(?:-[a-z0-9]+)*$")
INSTALLATION_PHASES = {"windows", "live", "target"}
TERMINAL_STATUSES = {"succeeded", "rolled-back"}
ALL_STATUSES = {
    "pending",
    "running",
    "failed",
    "rollback-running",
    "rolled-back",
    "succeeded",
}
ALL_PHASES = INSTALLATION_PHASES | {"rollback", "complete"}
FAILURE_COMPONENTS = {"windows", "live", "target", "rollback"}
ORDERED_STEPS = (
    "windows.preflight-verified",
    "windows.artifacts-verified",
    "windows.recovery-armed",
    "windows.system-volume-shrunk",
    "windows.installer-partition-created",
    "windows.live-media-prepared",
    "windows.temporary-boot-prepared",
    "live.preflight-verified",
    "live.installer-partition-expanded",
    "live.target-filesystem-created",
    "live.distribution-extracted",
    "target.system-configured",
    "target.bootloader-installed",
    "target.installation-verified",
)
COMPENSATABLE_STEPS = {
    "windows.recovery-armed",
    "windows.system-volume-shrunk",
    "windows.installer-partition-created",
    "windows.live-media-prepared",
    "windows.temporary-boot-prepared",
    "live.installer-partition-expanded",
    "live.target-filesystem-created",
    "live.distribution-extracted",
    "target.system-configured",
    "target.bootloader-installed",
}


class StateTransitionError(ValueError):
    """Raised when an execution state or transition is invalid."""


def utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def require_step(step: str) -> str:
    if not STEP_PATTERN.fullmatch(step):
        raise StateTransitionError(f"invalid installation step: {step!r}")
    return step.split(".", 1)[0]


def validate_state(value: Any) -> dict[str, Any]:
    try:
        validate_json_schema("installation-state.schema.json", value)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise StateTransitionError(f"execution state schema validation failed: {error}") from error

    if not isinstance(value, dict):
        raise StateTransitionError("execution state must be an object")
    if value.get("schemaVersion") != 1:
        raise StateTransitionError("unsupported execution-state schemaVersion")
    if not HEX_ID_PATTERN.fullmatch(str(value.get("planId", ""))):
        raise StateTransitionError("execution state has an invalid planId")
    revision = value.get("revision")
    if isinstance(revision, bool) or not isinstance(revision, int) or revision < 0:
        raise StateTransitionError("execution state revision cannot be negative")
    if value.get("status") not in ALL_STATUSES:
        raise StateTransitionError("execution state has an invalid status")
    if value.get("phase") not in ALL_PHASES:
        raise StateTransitionError("execution state has an invalid phase")
    updated_at = value.get("updatedAtUtc")
    if not isinstance(updated_at, str) or not updated_at.strip():
        raise StateTransitionError("execution state updatedAtUtc is required")
    try:
        parsed_updated_at = datetime.fromisoformat(updated_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise StateTransitionError("execution state updatedAtUtc is invalid") from error
    if parsed_updated_at.utcoffset() != datetime.now(UTC).utcoffset():
        raise StateTransitionError("execution state updatedAtUtc must use UTC")

    active_step = value.get("activeStep")
    if active_step is not None:
        require_step(active_step)
    completed = value.get("completedSteps")
    compensated = value.get("compensatedSteps")
    if not isinstance(completed, list) or not isinstance(compensated, list):
        raise StateTransitionError("completedSteps and compensatedSteps must be arrays")
    for step in completed + compensated:
        require_step(step)
    if len(set(completed)) != len(completed):
        raise StateTransitionError("completedSteps contains duplicates")
    if len(set(compensated)) != len(compensated):
        raise StateTransitionError("compensatedSteps contains duplicates")
    if not set(compensated).issubset(completed):
        raise StateTransitionError("a compensated step did not complete")
    if completed != list(ORDERED_STEPS[: len(completed)]):
        raise StateTransitionError("completedSteps is not an ordered workflow prefix")
    if active_step is not None and (
        len(completed) >= len(ORDERED_STEPS) or active_step != ORDERED_STEPS[len(completed)]
    ):
        raise StateTransitionError("activeStep is not the next workflow step")

    status = value["status"]
    failure = value.get("failure")
    if status == "failed" and not isinstance(failure, dict):
        raise StateTransitionError("a failed state requires failure details")
    if failure is not None:
        if not isinstance(failure, dict):
            raise StateTransitionError("failure must be an object or null")
        if not str(failure.get("code", "")).strip() or not str(failure.get("message", "")).strip():
            raise StateTransitionError("failure code and message are required")
        if failure.get("component") not in FAILURE_COMPONENTS:
            raise StateTransitionError("failure component is invalid")
        # Rollback states retain the originating failure as diagnostics.
        # Pending, running, and successful states cannot describe an inactive
        # failure.
        if status in {"pending", "running", "succeeded"}:
            raise StateTransitionError("only failed and rollback states can carry failure details")
    if status == "rollback-running" and value["phase"] != "rollback":
        raise StateTransitionError("rollback-running requires the rollback phase")
    if status in TERMINAL_STATUSES and value["phase"] != "complete":
        raise StateTransitionError("terminal states require the complete phase")
    if status == "succeeded" and completed != list(ORDERED_STEPS):
        raise StateTransitionError("a successful state requires every installation step")
    if status == "rolled-back":
        required_compensations = {step for step in completed if step in COMPENSATABLE_STEPS}
        if set(compensated) != required_compensations:
            raise StateTransitionError("a rolled-back state requires every applicable compensation")
    if status in {"failed", "rollback-running"} | TERMINAL_STATUSES and active_step is not None:
        raise StateTransitionError(
            "failed, rollback, and terminal states cannot have an active step"
        )
    return value


def read_state(path: Path) -> dict[str, Any]:
    try:
        return validate_state(json.loads(path.read_text(encoding="utf-8-sig")))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise StateTransitionError(f"cannot read execution state {path}: {error}") from error


def write_state_atomic(path: Path, state: dict[str, Any]) -> None:
    validate_state(state)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{path.name}.",
        suffix=".tmp",
        dir=path.parent,
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(state, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary_path, path)
    finally:
        with contextlib.suppress(OSError):
            temporary_path.unlink(missing_ok=True)


def touch(state: dict[str, Any]) -> None:
    state["revision"] += 1
    state["updatedAtUtc"] = utc_now()


def start_step(state: dict[str, Any], step: str) -> None:
    phase = require_step(step)
    if state["status"] in TERMINAL_STATUSES:
        raise StateTransitionError("installation is already terminal")
    if state["status"] == "rollback-running":
        raise StateTransitionError("an installation step cannot start during rollback")
    if state["activeStep"] is not None:
        raise StateTransitionError(f"step {state['activeStep']!r} is already active")
    if step in state["completedSteps"]:
        raise StateTransitionError(f"step {step!r} is already complete")
    expected_index = len(state["completedSteps"])
    expected = (
        ORDERED_STEPS[expected_index] if expected_index < len(ORDERED_STEPS) else "no further step"
    )
    if step != expected:
        raise StateTransitionError(f"step {step!r} is out of order; expected {expected!r}")
    # A recovery retry may legitimately resume after a recorded failure. Drop
    # that failure here: without this, the ledger can reach "succeeded" while
    # still carrying the diagnostics of a run that did not succeed.
    if state["status"] == "failed":
        state["failure"] = None
    state.update(status="running", phase=phase, activeStep=step)
    touch(state)


def complete_step(state: dict[str, Any], step: str) -> None:
    require_step(step)
    if state["status"] != "running" or state["activeStep"] != step:
        raise StateTransitionError(
            f"cannot complete {step!r}; active step is {state['activeStep']!r}"
        )
    state["completedSteps"].append(step)
    state["activeStep"] = None
    touch(state)


def fail(state: dict[str, Any], code: str, component: str, message: str) -> None:
    if state["status"] in TERMINAL_STATUSES or state["status"] == "rollback-running":
        raise StateTransitionError("the current state cannot transition to failed")
    if not code.strip() or not message.strip() or component not in FAILURE_COMPONENTS:
        raise StateTransitionError("failure code, message, or component is invalid")
    state.update(
        status="failed",
        activeStep=None,
        failure={"code": code, "message": message, "component": component},
    )
    touch(state)


def begin_rollback(state: dict[str, Any]) -> None:
    if state["status"] not in {"running", "failed"}:
        raise StateTransitionError("rollback can only begin from running or failed")
    state.update(status="rollback-running", phase="rollback", activeStep=None)
    touch(state)


def compensate(state: dict[str, Any], step: str) -> None:
    require_step(step)
    if state["status"] != "rollback-running":
        raise StateTransitionError("compensation requires a running rollback")
    if step not in state["completedSteps"]:
        raise StateTransitionError(f"cannot compensate incomplete step {step!r}")
    if step not in state["compensatedSteps"]:
        state["compensatedSteps"].append(step)
        touch(state)


def complete_rollback(state: dict[str, Any]) -> None:
    if state["status"] != "rollback-running":
        raise StateTransitionError("no rollback is running")
    uncompensated = next(
        (
            step
            for step in state["completedSteps"]
            if step in COMPENSATABLE_STEPS and step not in state["compensatedSteps"]
        ),
        None,
    )
    if uncompensated is not None:
        raise StateTransitionError(
            f"rollback cannot complete before compensating {uncompensated!r}"
        )
    state.update(status="rolled-back", phase="complete", activeStep=None)
    touch(state)


def complete_installation(state: dict[str, Any]) -> None:
    if state["status"] != "running" or state["activeStep"] is not None:
        raise StateTransitionError("installation can complete only between successful steps")
    if state["completedSteps"] != list(ORDERED_STEPS):
        raise StateTransitionError("installation cannot complete before final target verification")
    state.update(status="succeeded", phase="complete")
    touch(state)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    initialize = subparsers.add_parser("init")
    initialize.add_argument("path", type=Path)
    initialize.add_argument("plan_id")

    for command in ("start", "complete", "compensate"):
        transition = subparsers.add_parser(command)
        transition.add_argument("path", type=Path)
        transition.add_argument("step")

    step_status = subparsers.add_parser("step-status")
    step_status.add_argument("path", type=Path)
    step_status.add_argument("step")

    failure = subparsers.add_parser("fail")
    failure.add_argument("path", type=Path)
    failure.add_argument("code")
    failure.add_argument("component", choices=sorted(FAILURE_COMPONENTS))
    failure.add_argument("message")

    for command in (
        "begin-rollback",
        "complete-rollback",
        "complete-installation",
        "validate",
        "plan-id",
        "status",
    ):
        transition = subparsers.add_parser(command)
        transition.add_argument("path", type=Path)

    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.command == "init":
        if not HEX_ID_PATTERN.fullmatch(args.plan_id):
            raise StateTransitionError("planId must contain 32 lowercase hexadecimal characters")
        state = {
            "schemaVersion": 1,
            "planId": args.plan_id,
            "revision": 0,
            "status": "pending",
            "phase": "windows",
            "activeStep": None,
            "completedSteps": [],
            "compensatedSteps": [],
            "failure": None,
            "updatedAtUtc": utc_now(),
        }
    else:
        state = read_state(args.path)

    if args.command == "plan-id":
        print(state["planId"])
        return 0
    if args.command == "status":
        print(state["status"])
        return 0
    if args.command == "step-status":
        require_step(args.step)
        if args.step in state["completedSteps"]:
            print("completed")
        elif state["activeStep"] == args.step:
            print("active")
        else:
            print("pending")
        return 0

    transitions = {
        "start": lambda: start_step(state, args.step),
        "complete": lambda: complete_step(state, args.step),
        "fail": lambda: fail(state, args.code, args.component, args.message),
        "begin-rollback": lambda: begin_rollback(state),
        "compensate": lambda: compensate(state, args.step),
        "complete-rollback": lambda: complete_rollback(state),
        "complete-installation": lambda: complete_installation(state),
        "validate": lambda: None,
        "init": lambda: None,
    }
    transitions[args.command]()
    if args.command != "validate":
        write_state_atomic(args.path, state)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except StateTransitionError as error:
        print(f"LIVE_E_INSTALLATION_STATE: {error}", file=sys.stderr)
        raise SystemExit(2) from error
