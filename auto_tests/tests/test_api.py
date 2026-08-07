import json
from pathlib import Path

from starlette.testclient import TestClient

from app.main import create_app

from .test_core import settings


def test_health_endpoint() -> None:
    with TestClient(create_app(settings())) as client:
        response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


def test_filepool_prefers_generated_runtime_metadata(tmp_path: Path) -> None:
    runtime_metadata = tmp_path / "filepool" / "distros.json"
    runtime_metadata.parent.mkdir(parents=True)
    expected = [{"name": "generated-runtime-catalogue"}]
    runtime_metadata.write_text(json.dumps(expected), encoding="utf-8")

    configured = settings(
        runtime_dir=tmp_path,
        capture_dir=tmp_path / "captures",
        operation_log_dir=tmp_path / "logs",
    )
    with TestClient(create_app(configured)) as client:
        response = client.get("/filepool/distros.json")

    assert response.status_code == 200
    assert response.json() == expected


def test_web_ui_is_served() -> None:
    with TestClient(create_app(settings())) as client:
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
    assert "/filepool/distros.json" in response.text
    assert "/filepool/libertix-installer-bios.iso" in response.text
    assert "/filepool/libertix-installer-uefi.iso" in response.text
    assert "/filepool/mint.iso" not in response.text
    assert "/filepool/aria2-64.zip" in response.text
    assert "monitor_iso" in response.text
    assert "linux_password" in response.text
    assert "source" in response.text
    assert "Working tree local" in response.text


def test_protected_endpoint_rejects_bad_key_without_running_workflow() -> None:
    with TestClient(create_app(settings())) as client:
        response = client.post("/api/v1/validation", headers={"X-API-Key": "wrong"})
    assert response.status_code == 401


def test_automation_endpoint_requires_auth() -> None:
    with TestClient(create_app(settings())) as client:
        response = client.post("/api/v1/automation", headers={"X-API-Key": "wrong"})
    assert response.status_code == 401


def test_automation_endpoint_requires_an_explicit_linux_password() -> None:
    with TestClient(create_app(settings())) as client:
        response = client.post(
            "/api/v1/automation",
            headers={"X-API-Key": "secret"},
            json={"vms": ["vm1"], "source": "local"},
        )

    assert response.status_code == 422


def test_configured_vms_endpoint_requires_auth_and_returns_safe_vm_metadata() -> None:
    with TestClient(create_app(settings())) as client:
        rejected = client.get("/api/v1/vms", headers={"X-API-Key": "wrong"})
        accepted = client.get("/api/v1/vms", headers={"X-API-Key": "secret"})

    assert rejected.status_code == 401
    assert accepted.status_code == 200
    assert accepted.json()["vms"][1] == {
        "name": "vm2",
        "host": "192.0.2.241",
        "os": "Windows 10 UEFI",
        "vnc": "192.0.2.166:11",
        "username": "admin",
    }
