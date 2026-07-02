from fastapi.testclient import TestClient

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
    assert "LinuxGate" in response.text
    assert "/api/v1/validation/stream" in response.text
    assert "/api/v1/reset/stream" in response.text


def test_protected_endpoint_rejects_bad_key_without_running_workflow() -> None:
    with TestClient(create_app(settings())) as client:
        response = client.post("/api/v1/validation", headers={"X-API-Key": "wrong"})
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
