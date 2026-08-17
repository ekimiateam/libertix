from __future__ import annotations

import json
import multiprocessing
import os
import pickle
import threading
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest
from pydantic import ValidationError

import app.main as main_module
from app.api_runtime import (
    ProcessOperationLock,
    capture_workspace_cleanup_candidates,
    cleanup_operation_artifacts,
    create_capture_workspace,
    mark_capture_workspace_complete,
    mark_capture_workspace_owned,
)
from app.config import VMConfig
from app.main import create_app
from app.models import AutomationRequest, OperationResult, StepResult

from .asgi_client import AsgiTestClient
from .test_core import settings


@pytest.fixture(autouse=True)
def preserve_monkeypatched_workers_with_a_fork_test_context(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    real_get_context = multiprocessing.get_context

    def get_test_context(method: str):
        assert method == "spawn"
        return real_get_context("fork")

    monkeypatch.setattr(main_module.multiprocessing, "get_context", get_test_context)


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


def test_spawn_worker_arguments_and_target_are_serializable() -> None:
    request = AutomationRequest(
        apply=True,
        linux_password="test-passphrase",
        simulate_stale_firmware_entries=True,
        force_offline_ntfs_resize=True,
        boot_guardian_fault="boot-order",
    )

    assert pickle.loads(pickle.dumps(main_module._stream_operation_worker)) is (  # noqa: SLF001
        main_module._stream_operation_worker  # noqa: SLF001
    )
    restored_settings, restored_request = pickle.loads(pickle.dumps((settings(), request)))
    assert restored_request.linux_password == "test-passphrase"
    assert restored_request.simulate_stale_firmware_entries is True
    assert restored_request.force_offline_ntfs_resize is True
    assert restored_request.boot_guardian_fault == "boot-order"


def test_stream_worker_serializes_parallel_vm_events(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    class ConcurrentWriteDetector:
        def __init__(self) -> None:
            self._state_lock = threading.Lock()
            self._active_writers = 0
            self.overlap_detected = False
            self.events: list[tuple[str, object]] = []

        def send(self, event: tuple[str, object]) -> None:
            with self._state_lock:
                self._active_writers += 1
                if self._active_writers > 1:
                    self.overlap_detected = True
            time.sleep(0.01)
            self.events.append(event)
            with self._state_lock:
                self._active_writers -= 1

        def close(self) -> None:
            pass

    def run_parallel_steps(
        _configured,
        _operation,
        _selectors,
        _request,
        on_step,
        _run_workspace,
    ) -> OperationResult:
        barrier = threading.Barrier(3)

        def publish_vm_step(index: int) -> None:
            barrier.wait()
            on_step(
                StepResult(
                    step="automation.deploy",
                    status="ok",
                    message="deployed",
                    context={"vm": f"vm{index}"},
                )
            )

        with ThreadPoolExecutor(max_workers=3) as executor:
            list(executor.map(publish_vm_step, range(1, 4)))
        return OperationResult(
            status="ok",
            operation="automation",
            message="complete",
            steps=[],
        )

    connection = ConcurrentWriteDetector()
    workspace = tmp_path / "automation-20260813T120000Z-a0000000"
    workspace.mkdir()
    monkeypatch.setattr(main_module, "_run_operation", run_parallel_steps)
    monkeypatch.setattr(main_module.vnc_api, "shutdown", lambda: None)

    main_module._stream_operation_worker(  # noqa: SLF001
        settings(capture_dir=tmp_path / "captures"),
        "automation",
        ["vm1", "vm2", "vm3"],
        AutomationRequest(apply=True, linux_password="test"),
        connection,  # type: ignore[arg-type]
        workspace,
    )

    assert connection.overlap_detected is False
    assert [event_type for event_type, _payload in connection.events] == [
        "step",
        "step",
        "step",
        "result",
    ]


def test_stream_publishes_only_one_terminal_result_when_timeout_races_completion(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    barrier = multiprocessing.Barrier(2)

    def finish_at_timeout(
        _configured,
        _operation,
        _selectors,
        _request,
        _on_step,
        _run_workspace,
    ) -> OperationResult:
        barrier.wait(timeout=5)
        return OperationResult(
            status="ok",
            operation="automation",
            message="complete",
            steps=[],
        )

    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
        automation_operation_timeout_seconds=0.05,
    )
    monkeypatch.setattr(main_module, "_run_operation", finish_at_timeout)

    def release_worker_at_timeout(*_args):
        barrier.wait(timeout=5)
        return {}, {}

    monkeypatch.setattr(
        main_module,
        "_capture_automation_timeout_screens",
        release_worker_at_timeout,
    )
    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            json={"apply": True, "linux_password": "test"},
        )
    terminal_events = [
        json.loads(line)
        for line in response.text.splitlines()
        if json.loads(line).get("event") == "result"
    ]

    assert len(terminal_events) == 1


def test_automation_password_accepts_four_characters_and_rejects_three() -> None:
    assert AutomationRequest(apply=True, linux_password="test").linux_password == "test"

    with pytest.raises(ValidationError):
        AutomationRequest(apply=True, linux_password="bad")


def test_automation_first_boot_accepts_both_orders_and_rejects_unknown_values() -> None:
    assert AutomationRequest(apply=True, linux_password="pass").first_boot == "windows"
    assert (
        AutomationRequest(apply=True, linux_password="pass", first_boot="linux").first_boot
        == "linux"
    )

    with pytest.raises(ValidationError):
        AutomationRequest(  # type: ignore[arg-type]
            apply=True, linux_password="pass", first_boot="other"
        )


def test_offline_ntfs_resize_fixture_is_opt_in() -> None:
    assert AutomationRequest(apply=True, linux_password="pass").force_offline_ntfs_resize is False
    request = AutomationRequest(
        apply=True,
        linux_password="pass",
        force_offline_ntfs_resize=True,
    )
    assert request.force_offline_ntfs_resize is True


def test_boot_guardian_fault_accepts_only_explicit_fixture_modes() -> None:
    assert AutomationRequest(apply=True, linux_password="pass").boot_guardian_fault == "none"
    for mode in (
        "boot-order",
        "bootnext-rollback",
        "preferred-path",
        "preferred-path-rollback",
    ):
        assert (
            AutomationRequest(
                apply=True,
                linux_password="pass",
                boot_guardian_fault=mode,
            ).boot_guardian_fault
            == mode
        )
    with pytest.raises(ValidationError):
        AutomationRequest(
            apply=True,
            linux_password="pass",
            boot_guardian_fault="unsafe",  # type: ignore[arg-type]
        )


def test_automation_account_and_storage_constraints_follow_the_shared_policy() -> None:
    policy = json.loads(
        (
            Path(__file__).resolve().parents[2] / "Scripts/config/Libertix.InstallationPolicy.json"
        ).read_text(encoding="utf-8")
    )
    minimum_size = policy["storage"]["minimumFinalSizeGiB"]

    assert (
        AutomationRequest(
            apply=True, linux_password="pass", linux_size_gib=minimum_size
        ).linux_size_gib
        == minimum_size
    )
    for username in ("root", "admin"):
        with pytest.raises(ValidationError):
            AutomationRequest(apply=True, linux_password="pass", linux_username=username)
    with pytest.raises(ValidationError):
        AutomationRequest(apply=True, linux_password="pass", linux_size_gib=minimum_size - 1)


def test_process_operation_lock_refuses_a_symlink(tmp_path: Path) -> None:
    outside = tmp_path / "outside.lock"
    outside.write_text("unchanged\n", encoding="ascii")
    lock_path = tmp_path / "operation.lock"
    lock_path.symlink_to(outside)

    with pytest.raises(OSError):
        ProcessOperationLock(lock_path).acquire()
    assert outside.read_text(encoding="ascii") == "unchanged\n"


def test_process_operation_lock_releases_thread_lock_after_open_failure(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = ProcessOperationLock(tmp_path / "operation.lock")
    real_open = os.open
    calls = 0

    def fail_once(*args, **kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            raise PermissionError("lock path is not writable")
        return real_open(*args, **kwargs)

    monkeypatch.setattr("app.api_runtime.os.open", fail_once)

    with pytest.raises(PermissionError):
        lock.acquire()
    assert lock.acquire() is True
    lock.release()


def test_vm_name_is_safe_for_paths_tasks_and_generated_linux_hostname() -> None:
    common = {
        "host": "192.0.2.1",
        "os": "Windows",
        "vnc": "192.0.2.2:1",
        "screen_width": 1024,
        "screen_height": 768,
        "vmid": 500,
        "firmware": "uefi",
    }

    assert VMConfig(name="vm-501", **common).name == "vm-501"
    for invalid in ("../vm", "vm_name", ".vm", "vm.", "a" * 58):
        with pytest.raises(ValidationError):
            VMConfig(name=invalid, **common)


def test_capture_cleanup_is_scoped_to_the_configured_workspace(tmp_path: Path) -> None:
    capture_dir = tmp_path / "captures"
    capture_dir.mkdir()
    (capture_dir / "run-a").mkdir()
    (capture_dir / "run-a" / "screen.png").write_bytes(b"png")
    (capture_dir / "orphan.png").write_bytes(b"png")
    completed_runs: list[Path] = []
    for index in range(5):
        run = capture_dir / f"automation-20260813T12000{index}Z-a000000{index}"
        run.mkdir()
        (run / "screen.png").write_bytes(b"png")
        mark_capture_workspace_complete(run)
        timestamp_ns = time.time_ns() - (10 - index) * 1_000_000_000
        os.utime(run, ns=(timestamp_ns, timestamp_ns))
        completed_runs.append(run)
    outside = tmp_path / "outside.png"
    outside.write_bytes(b"keep")

    configured = settings(capture_dir=capture_dir)
    candidates = capture_workspace_cleanup_candidates(configured)

    assert candidates == sorted(completed_runs[:2])

    cleanup_operation_artifacts(configured)

    assert sorted(path.name for path in capture_dir.iterdir()) == [
        "automation-20260813T120002Z-a0000002",
        "automation-20260813T120003Z-a0000003",
        "automation-20260813T120004Z-a0000004",
        "orphan.png",
        "run-a",
    ]
    assert outside.read_bytes() == b"keep"


def test_capture_cleanup_preserves_workspace_owned_by_a_live_process(tmp_path: Path) -> None:
    capture_dir = tmp_path / "captures"
    active = capture_dir / "automation-active"
    active.mkdir(parents=True)
    mark_capture_workspace_owned(active)
    for index in range(4):
        completed = capture_dir / f"automation-20260813T12000{index}Z-b000000{index}"
        completed.mkdir()
        mark_capture_workspace_complete(completed)

    cleanup_operation_artifacts(settings(capture_dir=capture_dir))

    assert (active / ".owner-pid").read_text(encoding="ascii").strip() == str(os.getpid())
    assert len(list(capture_dir.glob("automation-*"))) == 4
    assert len(list(capture_dir.glob("automation-20260813T*-b*"))) == 3


def test_operation_retention_combines_legacy_logs_and_current_workspaces(
    tmp_path: Path,
) -> None:
    capture_dir = tmp_path / "captures"
    log_dir = tmp_path / "logs"
    capture_dir.mkdir()
    log_dir.mkdir()
    legacy_logs: list[Path] = []
    for index in range(3):
        legacy = log_dir / f"automation-20260812T12000{index}Z-c000000{index}.txt"
        legacy.write_text("legacy\n", encoding="utf-8")
        timestamp_ns = time.time_ns() - (20 - index) * 1_000_000_000
        os.utime(legacy, ns=(timestamp_ns, timestamp_ns))
        legacy_logs.append(legacy)
    current = capture_dir / "automation-20260813T120000Z-d0000000"
    current.mkdir()
    mark_capture_workspace_complete(current)

    cleanup_operation_artifacts(settings(capture_dir=capture_dir, operation_log_dir=log_dir))

    assert not legacy_logs[0].exists()
    assert legacy_logs[1].is_file()
    assert legacy_logs[2].is_file()
    assert current.is_dir()


def test_operation_retention_ignores_manual_and_malformed_files(tmp_path: Path) -> None:
    capture_dir = tmp_path / "captures"
    log_dir = tmp_path / "logs"
    capture_dir.mkdir()
    log_dir.mkdir()
    manual_capture = capture_dir / "diagnostic-vm500.png"
    manual_capture.write_bytes(b"png")
    malformed_workspace = capture_dir / "automation-manual"
    malformed_workspace.mkdir()
    manual_log = log_dir / "api-background.log"
    manual_log.write_text("keep\n", encoding="utf-8")

    cleanup_operation_artifacts(
        settings(capture_dir=capture_dir, operation_log_dir=log_dir), keep=1
    )

    assert manual_capture.read_bytes() == b"png"
    assert malformed_workspace.is_dir()
    assert manual_log.read_text(encoding="utf-8") == "keep\n"


def test_create_capture_workspace_uses_a_dedicated_owned_directory(tmp_path: Path) -> None:
    configured = settings(capture_dir=tmp_path / "captures")

    workspace = create_capture_workspace(configured, "automation")

    assert workspace.parent == configured.capture_dir
    assert workspace.name.startswith("automation-")
    assert workspace.stat().st_mode & 0o777 == 0o700
    assert (workspace / ".owner-pid").read_text(encoding="ascii").strip() == str(os.getpid())


def test_capture_cleanup_refuses_a_workspace_named_symlink(tmp_path: Path) -> None:
    capture_dir = tmp_path / "captures"
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep.txt").write_text("keep", encoding="utf-8")
    capture_dir.mkdir()
    linked = capture_dir / "automation-20260813T120000Z-c0000000"
    linked.symlink_to(outside, target_is_directory=True)

    cleanup_operation_artifacts(settings(capture_dir=capture_dir))

    assert (outside / "keep.txt").read_text(encoding="utf-8") == "keep"
    assert linked.is_symlink()


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

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            json={
                "vms": ["vm1"],
                "apply": True,
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


def test_stream_timeout_captures_selected_vms_and_returns_a_terminal_error(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    monkeypatch.setattr(main_module, "operation_lock", lock)
    captured: list[tuple[list[str] | None, Path]] = []

    class HangingAutomationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, _selectors, *, on_step, **_kwargs) -> OperationResult:
            on_step(
                StepResult(
                    step="automation.installed_boot_menu_seen",
                    status="ok",
                    message="GRUB menu detected",
                    context={"vm": "vm2"},
                )
            )
            time.sleep(5)
            raise AssertionError("the timed-out worker must be terminated")

    def capture_timeout_screens(_settings, selectors, workspace):
        captured.append((selectors, workspace))
        destination = workspace / "captures" / "timeout-vm2.png"
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(b"png")
        return {"vm2": str(destination)}, {}

    monkeypatch.setattr(main_module, "AutomationService", HangingAutomationService)
    monkeypatch.setattr(
        main_module,
        "_capture_automation_timeout_screens",
        capture_timeout_screens,
    )
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
        automation_operation_timeout_seconds=0.05,
    )

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            json={
                "vms": ["vm2"],
                "apply": True,
                "source": "local",
                "linux_password": "test-passphrase",
            },
        )

    events = [json.loads(line) for line in response.text.splitlines()]
    assert [event["event"] for event in events] == ["step", "result"]
    result = events[-1]["data"]
    assert result["status"] == "error"
    assert result["steps"][0]["step"] == "automation.inactivity_timeout"
    assert result["steps"][0]["context"]["inactivity_timeout_seconds"] == 0.05
    assert result["steps"][0]["context"]["active_steps"] == {
        "vm2": "automation.installed_boot_menu_seen"
    }
    assert result["steps"][0]["context"]["captures"]["vm2"].endswith("timeout-vm2.png")
    assert captured[0][0] == ["vm2"]
    assert lock.release_calls == 1
    assert lock.held is False


def test_stream_inactivity_timeout_resets_after_each_progress_step(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    monkeypatch.setattr(main_module, "operation_lock", lock)

    class ProgressingAutomationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, _selectors, *, on_step, **_kwargs) -> OperationResult:
            steps: list[StepResult] = []
            for index in range(4):
                step = StepResult(
                    step=f"automation.progress_{index}",
                    status="ok",
                    message="progress",
                    context={"vm": "vm2"},
                )
                steps.append(step)
                on_step(step)
                time.sleep(0.03)
            return OperationResult(
                status="ok",
                operation="automation",
                message="complete",
                steps=steps,
            )

    monkeypatch.setattr(main_module, "AutomationService", ProgressingAutomationService)
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
        automation_operation_timeout_seconds=0.05,
    )

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            json={
                "vms": ["vm2"],
                "apply": True,
                "source": "local",
                "linux_password": "test-passphrase",
            },
        )

    events = [json.loads(line) for line in response.text.splitlines()]
    assert events[-1]["event"] == "result"
    assert events[-1]["data"]["status"] == "ok"
    assert all(
        step["step"] != "automation.inactivity_timeout" for step in events[-1]["data"]["steps"]
    )
    assert lock.release_calls == 1
    assert lock.held is False


def test_synchronous_operation_persists_steps_and_result_in_its_run_workspace(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    monkeypatch.setattr(main_module, "operation_lock", lock)

    class FakeAutomationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, _selectors, *, on_step, **_kwargs) -> OperationResult:
            step = StepResult(
                step="automation.deploy",
                status="ok",
                message="deployment complete",
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

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation",
            json={
                "vms": ["vm1"],
                "apply": True,
                "source": "local",
                "linux_password": "test-passphrase",
            },
        )

    assert response.status_code == 200
    workspaces = list((tmp_path / "captures").glob("automation-*"))
    assert len(workspaces) == 1
    assert (workspaces[0] / ".completed").is_file()
    logs = list(workspaces[0].glob("automation-*.txt"))
    assert len(logs) == 1
    events = [json.loads(line) for line in logs[0].read_text(encoding="utf-8").splitlines()]
    assert [event["event"] for event in events] == ["step", "result"]
    assert events[-1]["data"]["status"] == "ok"
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

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            json={
                "vms": ["vm1"],
                "apply": True,
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

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            json={
                "vms": ["vm1"],
                "apply": True,
                "source": "local",
                "linux_password": "test-passphrase",
            },
        )

    event = json.loads(response.text)
    assert event["event"] == "result"
    assert event["data"]["status"] == "error"
    assert "another operation" in event["data"]["message"]
    assert lock.release_calls == 0
    assert list((tmp_path / "captures").iterdir()) == []


def test_synchronous_operation_refuses_concurrency_without_creating_workspace(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    lock.held = True
    monkeypatch.setattr(main_module, "operation_lock", lock)
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation",
            json={
                "vms": ["vm1"],
                "apply": True,
                "source": "local",
                "linux_password": "test",
            },
        )

    assert response.status_code == 200
    assert response.json()["status"] == "error"
    assert list((tmp_path / "captures").iterdir()) == []
    assert lock.release_calls == 0


def test_workspace_finalization_failure_does_not_hide_operation_result_or_hold_lock(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    lock = FakeOperationLock()
    monkeypatch.setattr(main_module, "operation_lock", lock)

    class FakeAutomationService:
        def __init__(self, _settings) -> None:
            pass

        def run(self, _selectors, **_kwargs) -> OperationResult:
            return OperationResult(
                status="ok",
                operation="automation",
                message="complete",
                steps=[],
            )

    monkeypatch.setattr(main_module, "AutomationService", FakeAutomationService)
    configured = settings(
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )

    with AsgiTestClient(create_app(configured)) as client:
        monkeypatch.setattr(
            main_module,
            "mark_capture_workspace_complete",
            lambda _path: (_ for _ in ()).throw(OSError("read-only workspace")),
        )
        monkeypatch.setattr(
            main_module,
            "cleanup_operation_artifacts",
            lambda _settings: (_ for _ in ()).throw(OSError("retention unavailable")),
        )
        response = client.post(
            "/api/v1/automation",
            json={
                "vms": ["vm1"],
                "apply": True,
                "source": "local",
                "linux_password": "test",
            },
        )

    assert response.status_code == 200
    assert response.json()["status"] == "ok"
    assert lock.release_calls == 1
    assert lock.held is False


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

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            json={
                "vms": ["vm1"],
                "apply": True,
                "source": "local",
                "linux_password": "test-passphrase",
            },
        )

    events = [json.loads(line) for line in response.text.splitlines()]
    assert [event["data"]["step"] for event in events if event["event"] == "step"] == [
        "automation.installation_phase",
        "automation.installation_finished",
    ]
    assert "42%" not in response.text
    assert "81%" not in response.text
    assert "private-screen.png" not in response.text
    assert events[-1]["data"]["steps"] == []

    detailed_log = Path(events[-1]["data"]["detailed_log"])
    assert detailed_log.parent.parent == tmp_path / "captures"
    assert detailed_log.parent.name.startswith("automation-")
    assert (detailed_log.parent / ".completed").is_file()
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

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream?format=ndjson",
            json={
                "vms": ["vm1"],
                "apply": True,
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

    with AsgiTestClient(create_app(configured)) as client:
        response = client.post(
            "/api/v1/automation/stream",
            json={"vms": ["vm1"], "apply": True, "linux_password": "test-passphrase"},
        )

    lines = response.text.splitlines()
    assert lines[0] == "TEST vm1 linux.identity OK"
    assert lines[1].startswith('ERROR {"step":"automation.test.linux"')
    assert "fstab diagnostic" in lines[1]
    assert lines[2].startswith("RESULT ERROR log=")
    detailed_log = Path(lines[2].split("log=", 1)[1])
    assert '"stdout": "test"' in detailed_log.read_text(encoding="utf-8")
