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
            step = StepResult(
                step="automation.deploy",
                status="ok",
                message="step complete",
                context={"vm": "vm1"},
            )
            on_step(step)
            return OperationResult(
                status="ok",
                operation="automation",
                message="complete",
                steps=[step],
            )

    monkeypatch.setattr(main_module, "AutomationService", FakeAutomationService)
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )

    with TestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            headers={"X-API-Key": "secret"},
            json={
                "vms": ["vm1"],
                "apply": False,
                "source": "local",
                "linux_password": "test-passphrase",
            },
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
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )

    with TestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            headers={"X-API-Key": "secret"},
            json={
                "vms": ["vm1"],
                "source": "local",
                "linux_password": "test-passphrase",
            },
        )

    events = [json.loads(line) for line in response.text.splitlines()]
    assert [event["event"] for event in events] == ["result"]
    assert events[0]["data"]["status"] == "error"
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
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )

    with TestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            headers={"X-API-Key": "secret"},
            json={
                "vms": ["vm1"],
                "source": "local",
                "linux_password": "test-passphrase",
            },
        )

    event = json.loads(response.text)
    assert event["event"] == "result"
    assert event["data"]["status"] == "error"
    assert "another operation" in event["data"]["message"]
    assert lock.release_calls == 0


def test_stream_keeps_full_log_but_emits_only_phase_changes(
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
            steps = [
                StepResult(
                    step="automation.capture",
                    status="ok",
                    message="Capture UI enregistrée",
                    context={"vm": "vm1", "capture": "/tmp/private-screen.png"},
                ),
                StepResult(
                    step="automation.compatibility_wait",
                    status="ok",
                    message="Préflight encore en cours",
                    context={"vm": "vm1", "detected_screen": "compatibility"},
                ),
                StepResult(
                    step="automation.compatibility_wait",
                    status="ok",
                    message="Préflight encore en cours",
                    context={"vm": "vm1", "detected_screen": "compatibility"},
                ),
                StepResult(
                    step="automation.monitor_installation",
                    status="ok",
                    message="Capture analysée",
                    context={
                        "vm": "vm1",
                        "visible_text": "Downloading Mint ISO 42%",
                        "summary": "Download in progress",
                        "analysis_source": "strict_json",
                    },
                ),
                StepResult(
                    step="automation.monitor_installation",
                    status="ok",
                    message="Capture analysée",
                    context={
                        "vm": "vm1",
                        "visible_text": "Downloading Mint ISO 81%",
                        "summary": "Download in progress",
                        "analysis_source": "strict_json",
                    },
                ),
                StepResult(
                    step="automation.installation_finished",
                    status="ok",
                    message="Installation terminée",
                    context={"vm": "vm1", "capture": "/tmp/final-screen.png"},
                ),
            ]
            for step in steps:
                on_step(step)
            return OperationResult(
                status="ok",
                operation="automation",
                message="complete",
                steps=steps,
            )

    monkeypatch.setattr(main_module, "AutomationService", FakeAutomationService)
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )

    with TestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            headers={"X-API-Key": "secret"},
            json={
                "vms": ["vm1"],
                "source": "local",
                "linux_password": "test-passphrase",
            },
        )

    events = [json.loads(line) for line in response.text.splitlines()]
    assert [event["data"]["step"] for event in events if event["event"] == "step"] == [
        "automation.wizard_phase",
        "automation.installation_phase",
        "automation.installation_finished",
    ]
    assert "42%" not in response.text
    assert "81%" not in response.text
    assert "private-screen.png" not in response.text
    assert events[-1]["data"]["steps"] == []

    detailed_log = Path(events[-1]["data"]["detailed_log"])
    assert detailed_log.parent == tmp_path / "logs"
    details = detailed_log.read_text(encoding="utf-8")
    assert "private-screen.png" in details
    assert "42%" in details
    assert "81%" in details
    assert (tmp_path / "logs" / "api-runtime.txt").is_file()


def test_stream_preserves_complete_installation_errors(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    monkeypatch.setattr(main_module, "operation_lock", lock)

    class FailingInstallationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, _selectors, *, on_step, **_kwargs) -> OperationResult:
            capture = StepResult(
                step="automation.capture",
                status="ok",
                message="Capture UI enregistrée",
                context={"vm": "vm1", "capture": "/tmp/private-screen.png"},
            )
            failure = StepResult(
                step="automation.monitor_installation",
                status="error",
                message="Échec de l'installation Linux",
                context={
                    "vm": "vm1",
                    "stage": "150-final-verify",
                    "stderr": "final verify: MBR partition count is 5",
                    "capture": "/tmp/failure-screen.png",
                },
            )
            on_step(capture)
            on_step(failure)
            return OperationResult(
                status="error",
                operation="automation",
                message="installation failed",
                steps=[capture, failure],
            )

    monkeypatch.setattr(main_module, "AutomationService", FailingInstallationService)
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )

    with TestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            headers={"X-API-Key": "secret"},
            json={
                "vms": ["vm1"],
                "source": "local",
                "linux_password": "test-passphrase",
            },
        )

    events = [json.loads(line) for line in response.text.splitlines()]
    assert [event["event"] for event in events] == ["step", "result"]
    assert "private-screen.png" not in response.text
    assert events[0]["data"]["context"]["stage"] == "150-final-verify"
    assert "MBR partition count is 5" in events[0]["data"]["context"]["stderr"]
    assert events[-1]["data"]["steps"] == [events[0]["data"]]


def test_compact_stream_uses_short_success_lines_and_verbose_errors(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    monkeypatch.setattr(main_module, "operation_lock", lock)

    class FakeAutomationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, _selectors, *, on_step, **_kwargs) -> OperationResult:
            checks = [
                StepResult(
                    step="automation.test.linux",
                    status="ok",
                    message="linux.identity: OK",
                    context={"vm": "vm1", "test": "linux.identity", "stdout": "test"},
                ),
                StepResult(
                    step="automation.test.linux",
                    status="error",
                    message="linux.fstab: FAILED",
                    context={
                        "vm": "vm1",
                        "test": "linux.fstab",
                        "exit_code": 1,
                        "stderr": "fstab diagnostic",
                    },
                ),
            ]
            for check in checks:
                on_step(check)
            return OperationResult(
                status="error",
                operation="automation",
                message="checks failed",
                steps=checks,
            )

    monkeypatch.setattr(main_module, "AutomationService", FakeAutomationService)
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )

    with TestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream",
            headers={"X-API-Key": "secret"},
            json={"vms": ["vm1"], "linux_password": "test-passphrase"},
        )

    lines = response.text.splitlines()
    assert lines[0] == "TEST vm1 linux.identity OK"
    assert lines[1].startswith('ERROR {"step":"automation.test.linux"')
    assert "fstab diagnostic" in lines[1]
    assert lines[2].startswith("RESULT ERROR log=")
    detailed_log = Path(lines[2].split("log=", 1)[1])
    assert '"stdout": "test"' in detailed_log.read_text(encoding="utf-8")
