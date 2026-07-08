from starlette.testclient import TestClient

from app.main import create_app

from .test_core import settings


def test_health_endpoint() -> None:
    with TestClient(create_app(settings())) as client:
        response = client.get("/health")
    assert response.status_code == 200
    assert response.json() == {"status": "ok"}


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
    assert "/filepool/mint.iso" in response.text
    assert "/filepool/aria2-1.37.0-win-64bit-build1.zip" in response.text
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


def test_configured_vms_endpoint_requires_auth_and_returns_safe_vm_metadata() -> None:
    with TestClient(create_app(settings())) as client:
        rejected = client.get("/api/v1/vms", headers={"X-API-Key": "wrong"})
        accepted = client.get("/api/v1/vms", headers={"X-API-Key": "secret"})

    assert rejected.status_code == 401
    assert accepted.status_code == 200
    assert accepted.json()["vms"][1] == {
        "name": "vm2",
        "host": "192.168.1.241",
        "os": "Windows 10 UEFI",
        "vnc": "192.168.1.166:11",
        "username": "admin",
    }
