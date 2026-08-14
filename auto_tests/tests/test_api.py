import json
from pathlib import Path

from app import main as main_module
from app.main import create_app
from app.models import OperationResult

from .asgi_client import AsgiTestClient
from .test_core import settings


def test_stream_worker_shuts_down_vnc_runtime_and_flushes_result(
    monkeypatch, tmp_path: Path
) -> None:
    events: list[tuple[str, object]] = []
    calls: list[str] = []

    class FakeConnection:
        def send(self, item: tuple[str, object]) -> None:
            events.append(item)

        def close(self) -> None:
            calls.append("close")

    monkeypatch.setattr(
        main_module,
        "_run_operation",
        lambda *_args, **_kwargs: OperationResult(
            status="ok", operation="automation", message="ok", steps=[]
        ),
    )
    monkeypatch.setattr(main_module.vnc_api, "shutdown", lambda: calls.append("vnc_shutdown"))

    workspace = tmp_path / "automation-worker"
    workspace.mkdir()
    main_module._stream_operation_worker(
        settings(), "automation", ["vm1"], None, FakeConnection(), workspace
    )

    assert events == [
        (
            "result",
            OperationResult(status="ok", operation="automation", message="ok", steps=[]).model_dump(
                mode="json"
            ),
        )
    ]
    assert calls == ["vnc_shutdown", "close"]


def test_stream_worker_finishes_when_its_parent_event_pipe_is_gone(
    monkeypatch, tmp_path: Path
) -> None:
    calls: list[str] = []

    class BrokenConnection:
        def send(self, _item: tuple[str, object]) -> None:
            calls.append("send")
            raise BrokenPipeError

        def close(self) -> None:
            calls.append("close")

    def run_operation(
        _settings, _operation, _selectors, _request, on_step, _run_workspace
    ) -> OperationResult:
        on_step(
            main_module.StepResult(
                step="automation.deploy",
                status="ok",
                message="step complete",
                context={"vm": "vm1"},
            )
        )
        calls.append("operation_complete")
        return OperationResult(status="ok", operation="automation", message="ok", steps=[])

    monkeypatch.setattr(main_module, "_run_operation", run_operation)
    monkeypatch.setattr(main_module.vnc_api, "shutdown", lambda: calls.append("vnc_shutdown"))

    workspace = tmp_path / "automation-worker"
    workspace.mkdir()
    main_module._stream_operation_worker(
        settings(), "automation", ["vm1"], None, BrokenConnection(), workspace
    )

    assert calls == ["send", "operation_complete", "vnc_shutdown", "close"]


def test_health_endpoint() -> None:
    with AsgiTestClient(create_app(settings())) as client:
        response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_filepool_prefers_generated_runtime_metadata(tmp_path: Path) -> None:
    runtime_metadata = tmp_path / "filepool" / "catalog.json"
    runtime_metadata.parent.mkdir(parents=True)
    expected = [{"name": "generated-runtime-catalogue"}]
    runtime_metadata.write_text(json.dumps(expected), encoding="utf-8")

    configured = settings(
        runtime_dir=tmp_path,
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )
    with AsgiTestClient(create_app(configured)) as client:
        response = client.get("/filepool/catalog.json")

    assert response.status_code == 200
    assert response.json() == expected


def test_distribution_metadata_resolution_returns_none_when_both_sources_are_missing(
    tmp_path: Path,
) -> None:
    from app.main import _resolve_distribution_metadata

    assert _resolve_distribution_metadata(tmp_path / "runtime", tmp_path / "source") is None


def test_filepool_exposes_every_regular_file_in_its_directory() -> None:
    filepool_dir = Path(main_module.__file__).resolve().parent / "filepool"
    expected_files = sorted(path.name for path in filepool_dir.iterdir() if path.is_file())
    assert expected_files

    with AsgiTestClient(create_app(settings())) as client:
        for filename in expected_files:
            assert client.head(f"/filepool/{filename}").status_code == 200
        assert client.get("/filepool/../main.py").status_code == 404


def test_web_ui_is_served() -> None:
    with AsgiTestClient(create_app(settings())) as client:
        response = client.get("/")
    assert response.status_code == 200
    assert "Libertix" in response.text
    assert "/health" in response.text
    assert "/api/v1/vms" in response.text
    assert "/api/v1/validation" in response.text
    assert "/api/v1/validation/stream" in response.text
    assert "/api/v1/automation" in response.text
    assert "/api/v1/automation/stream" in response.text
    assert "/api/v1/reset" in response.text
    assert "/api/v1/reset/stream" in response.text
    assert "/filepool/catalog.json" in response.text
    assert "/filepool/libertix-installer-bios.iso" in response.text
    assert "/filepool/libertix-installer-uefi.iso" in response.text
    assert "/filepool/mint.iso" not in response.text
    assert "/filepool/aria2-64.zip" in response.text
    assert "monitor_iso" in response.text
    assert "linux_password" in response.text
    assert "distribution" in response.text
    assert "Zorin OS 18.1 Core" in response.text
    assert "source" in response.text
    assert "Working tree local" in response.text
    assert "Le partage SMB sera conservé" in response.text
    assert "Automation unattended" in response.text
    assert "apply: true" in response.text
    assert "automationDry" not in response.text
    assert "launch-only" not in response.text


def test_control_endpoint_allows_local_request_without_api_key() -> None:
    with AsgiTestClient(create_app(settings())) as client:
        response = client.get("/api/v1/vms")
    assert response.status_code == 200


def test_control_endpoint_allows_remote_laboratory_request() -> None:
    with AsgiTestClient(create_app(settings()), client=("203.0.113.20", 54321)) as client:
        response = client.get("/api/v1/vms")
    assert response.status_code == 200


def test_automation_endpoint_requires_an_explicit_linux_password() -> None:
    with AsgiTestClient(create_app(settings())) as client:
        response = client.post(
            "/api/v1/automation",
            json={"vms": ["vm1"], "source": "local", "apply": True},
        )

    assert response.status_code == 422


def test_automation_endpoint_rejects_an_unknown_distribution() -> None:
    with AsgiTestClient(create_app(settings())) as client:
        response = client.post(
            "/api/v1/automation",
            json={
                "vms": ["vm1"],
                "apply": True,
                "source": "local",
                "linux_password": "testtest",
                "distribution": "unknown",
            },
        )

    assert response.status_code == 422


def test_automation_endpoint_rejects_a_reserved_linux_username() -> None:
    with AsgiTestClient(create_app(settings())) as client:
        response = client.post(
            "/api/v1/automation",
            json={
                "vms": ["vm1"],
                "apply": True,
                "source": "local",
                "linux_username": "admin",
                "linux_password": "testtest",
            },
        )

    assert response.status_code == 422


def test_automation_endpoints_reject_a_request_without_a_body() -> None:
    with AsgiTestClient(create_app(settings())) as client:
        response = client.post("/api/v1/automation")
        stream_response = client.post("/api/v1/automation/stream")

    assert response.status_code == 422
    assert stream_response.status_code == 422


def test_automation_requires_explicit_true_apply_authorization() -> None:
    base_request = {
        "vms": ["vm1"],
        "source": "local",
        "linux_password": "testtest",
    }
    with AsgiTestClient(create_app(settings())) as client:
        missing = client.post("/api/v1/automation", json=base_request)
        refused = client.post(
            "/api/v1/automation",
            json={**base_request, "apply": False},
        )

    assert missing.status_code == 422
    assert refused.status_code == 422


def test_configured_vms_endpoint_returns_safe_vm_metadata_without_api_key() -> None:
    with AsgiTestClient(create_app(settings())) as client:
        response = client.get("/api/v1/vms")

    assert response.status_code == 200
    assert response.json()["vms"][1] == {
        "name": "vm2",
        "host": "192.0.2.241",
        "os": "Windows 10 UEFI",
        "vnc": "192.0.2.166:11",
        "username": "admin",
    }


def test_force_kill_endpoint_terminates_only_the_active_operation() -> None:
    class FakeProcess:
        pid = 98765

        def __init__(self) -> None:
            self.alive = True
            self.killed = False

        def is_alive(self) -> bool:
            return self.alive

        def kill(self) -> None:
            self.killed = True
            self.alive = False

    process = FakeProcess()
    app = create_app(settings())
    app.state.operation_process.register(process, "automation")
    with AsgiTestClient(app) as client:
        accepted = client.post("/api/v1/operation/kill")
        health = client.get("/health")
        no_operation = client.post("/api/v1/operation/kill")

    assert accepted.status_code == 202
    assert accepted.json() == {
        "status": "killing",
        "operation": "automation",
        "pid": 98765,
        "warning": "The operation was terminated without cleanup; the API server remains active.",
    }
    assert process.killed is True
    assert health.status_code == 200
    assert no_operation.status_code == 409
