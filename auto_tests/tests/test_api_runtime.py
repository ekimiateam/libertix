from __future__ import annotations

import json
from pathlib import Path

import pytest
from starlette.testclient import TestClient

import app.main as main_module
from app.api_runtime import ProcessOperationLock, cleanup_capture_workspaces
from app.main import create_app
from app.models import OperationResult, StepResult

from .test_core import settings


class FakeOperationLock:
    def __init__(self) -> None:
        self.held = False
        self.acquire_calls = 0
        self.release_calls = 0

    def acquire(self, *, blocking: bool = False) -> bool:
        assert blocking is False
        self.acquire_calls += 1
        if self.held:
            return False
        self.held = True
        return True

    def release(self) -> None:
        assert self.held is True
        self.held = False
        self.release_calls += 1


def test_process_operation_lock_can_be_reused_without_network(tmp_path: Path) -> None:
    lock = ProcessOperationLock(tmp_path / "operation.lock")

    assert lock.acquire() is True
    assert lock.acquire() is False
    lock.release()
    assert lock.acquire() is True
    lock.release()


def test_capture_cleanup_is_scoped_to_the_configured_workspace(tmp_path: Path) -> None:
    capture_dir = tmp_path / "captures"
    capture_dir.mkdir()
    (capture_dir / "run-a").mkdir()
    (capture_dir / "run-a" / "screen.png").write_bytes(b"png")
    (capture_dir / "orphan.png").write_bytes(b"png")
    outside = tmp_path / "outside.png"
    outside.write_bytes(b"keep")

    cleanup_capture_workspaces(settings(capture_dir=capture_dir))

    assert list(capture_dir.iterdir()) == []
    assert outside.read_bytes() == b"keep"


def test_stream_emits_steps_then_one_terminal_result_and_releases_lock(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    monkeypatch.setattr(main_module, "operation_lock", lock)

    class FakeAutomationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, selectors, *, on_step, **_kwargs) -> OperationResult:
            assert selectors == ["vm1"]
            step = StepResult(step="automation.fake", status="ok", message="step complete")
            on_step(step)
            return OperationResult(
                status="ok",
                operation="automation",
                message="complete",
                steps=[step],
            )

    monkeypatch.setattr(main_module, "AutomationService", FakeAutomationService)
    configured = settings(capture_dir=tmp_path / "captures")

    with TestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream",
            headers={"X-API-Key": "secret"},
            json={"vms": ["vm1"], "apply": False, "source": "local"},
        )

    events = [json.loads(line) for line in response.text.splitlines()]
    assert response.status_code == 200
    assert [event["event"] for event in events] == ["step", "result"]
    assert events[-1]["data"]["status"] == "ok"
    assert lock.acquire_calls == 1
    assert lock.release_calls == 1
    assert lock.held is False


def test_stream_converts_worker_exception_to_safe_terminal_result(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    monkeypatch.setattr(main_module, "operation_lock", lock)

    class FailingAutomationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, _selectors, **_kwargs):
            raise RuntimeError("private diagnostic detail")

    monkeypatch.setattr(main_module, "AutomationService", FailingAutomationService)
    configured = settings(capture_dir=tmp_path / "captures")

    with TestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream",
            headers={"X-API-Key": "secret"},
            json={"vms": ["vm1"], "source": "local"},
        )

    events = [json.loads(line) for line in response.text.splitlines()]
    assert [event["event"] for event in events] == ["result"]
    assert events[0]["data"]["status"] == "problème"
    assert events[0]["data"]["steps"][0]["context"] == {"exception_type": "RuntimeError"}
    assert "private diagnostic detail" not in response.text
    assert lock.release_calls == 1
    assert lock.held is False


def test_stream_refuses_concurrent_operation_without_starting_service(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    lock.held = True
    monkeypatch.setattr(main_module, "operation_lock", lock)

    class ForbiddenAutomationService:
        def __init__(self, _settings) -> None:
            raise AssertionError("service must not start while the operation lock is held")

    monkeypatch.setattr(main_module, "AutomationService", ForbiddenAutomationService)
    configured = settings(capture_dir=tmp_path / "captures")

    with TestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream",
            headers={"X-API-Key": "secret"},
            json={"vms": ["vm1"], "source": "local"},
        )

    event = json.loads(response.text)
    assert event["event"] == "result"
    assert event["data"]["status"] == "problème"
    assert "autre opération" in event["data"]["message"]
    assert lock.release_calls == 0
