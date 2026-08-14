from pathlib import Path
from threading import Event

import httpx
import pytest
from websockets.exceptions import InvalidMessage

import app.clients.proxmox as proxmox_module
from app.clients.proxmox import ProxmoxClient
from app.clients.proxmox_serial import ProxmoxSerialCapture
from app.errors import WorkflowError


@pytest.mark.parametrize(("verify_tls", "expected"), ((True, True), (False, False)))
def test_tls_verification_is_explicit(
    monkeypatch: pytest.MonkeyPatch, verify_tls: bool, expected: bool
) -> None:
    captured: dict[str, object] = {}

    class FakeHttpClient:
        def __init__(self, **kwargs: object) -> None:
            captured.update(kwargs)

    monkeypatch.setattr(proxmox_module.httpx, "Client", FakeHttpClient)

    ProxmoxClient(
        "https://proxmox.test:8006",
        "token",
        "secret",
        timeout=1,
        task_timeout=1,
        verify_tls=verify_tls,
    )

    assert captured["verify"] is expected


def test_vm_lookup_only_queries_nodes_and_target_vmid() -> None:
    paths: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        if request.url.path.endswith("/nodes"):
            return httpx.Response(200, json={"data": [{"node": "TPM-28"}]})
        if request.url.path.endswith("/nodes/TPM-28/qemu/500/status/current"):
            return httpx.Response(200, json={"data": {"status": "running"}})
        return httpx.Response(404, json={"data": None})

    proxmox = ProxmoxClient(
        "https://proxmox.test:8006",
        "token",
        "secret",
        timeout=1,
        task_timeout=1,
    )
    proxmox.client.close()
    proxmox.client = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        assert proxmox.locate_vm(500) == "TPM-28"
    finally:
        proxmox.client.close()

    assert paths == [
        "/api2/json/nodes",
        "/api2/json/nodes/TPM-28/qemu/500/status/current",
    ]
    assert all("cluster/resources" not in path for path in paths)


def test_post_rollback_verification_requires_snapshot_parent_and_running_state(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    client = object.__new__(ProxmoxClient)
    paths: list[str] = []

    def request(_method: str, path: str, **_kwargs: object) -> object:
        paths.append(path)
        if path.endswith("/snapshot"):
            return [{"name": "clean2"}, {"name": "current", "parent": "clean2"}]
        return {"status": "running", "qmpstatus": "running"}

    monkeypatch.setattr(client, "_request", request)

    verified = client.verify_rollback_state("node-a", 500, "clean2", require_running=True)

    assert verified == {
        "snapshot_parent": "clean2",
        "status": "running",
        "qmpstatus": "running",
    }
    assert paths == [
        "/nodes/node-a/qemu/500/snapshot",
        "/nodes/node-a/qemu/500/status/current",
    ]


@pytest.mark.parametrize(
    ("current", "status", "step"),
    (
        ({"name": "current", "parent": "other"}, {"status": "running"}, "snapshot"),
        (
            {"name": "current", "parent": "clean2"},
            {"status": "running", "qmpstatus": "io-error"},
            "status",
        ),
        (
            {"name": "current", "parent": "clean2"},
            {"status": "stopped", "qmpstatus": "stopped"},
            "status",
        ),
    ),
)
def test_post_rollback_verification_fails_closed(
    monkeypatch: pytest.MonkeyPatch,
    current: dict[str, object],
    status: dict[str, object],
    step: str,
) -> None:
    client = object.__new__(ProxmoxClient)

    def request(_method: str, path: str, **_kwargs: object) -> object:
        if path.endswith("/snapshot"):
            return [{"name": "clean2"}, current]
        return status

    monkeypatch.setattr(client, "_request", request)

    with pytest.raises(WorkflowError) as caught:
        client.verify_rollback_state("node-a", 500, "clean2", require_running=True)

    assert step in caught.value.step


def test_guest_agent_command_preserves_argument_boundaries() -> None:
    requests: list[tuple[str, str, bytes]] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append((request.method, request.url.path, request.content))
        if request.method == "POST":
            return httpx.Response(200, json={"data": {"result": {"pid": 42}}})
        return httpx.Response(
            200,
            json={
                "data": {
                    "result": {
                        "exited": True,
                        "exitcode": 0,
                        "out-data": "ok",
                    }
                }
            },
        )

    proxmox = ProxmoxClient(
        "https://proxmox.test:8006",
        "token",
        "secret",
        timeout=1,
        task_timeout=1,
    )
    proxmox.client.close()
    proxmox.client = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        result = proxmox.execute_guest_agent_command(
            "node-a",
            500,
            ["netsh.exe", "name=Ethernet 2", "address=192.0.2.240"],
            step="test.guest_exec",
            timeout=1,
        )
    finally:
        proxmox.client.close()

    assert result["exitcode"] == 0
    assert requests[0][0] == "POST"
    assert requests[0][2] == (
        b"command=netsh.exe&command=name%3DEthernet+2&command=address%3D192.0.2.240"
    )
    assert requests[1][0] == "GET"
    assert "pid=42" in str(requests[1][1]) or requests[1][1].endswith("exec-status")


def test_serial_terminal_proxy_is_requested_for_serial_zero() -> None:
    requests: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        requests.append(request)
        return httpx.Response(
            200,
            json={
                "data": {
                    "user": "automation@pve",
                    "ticket": "private-console-ticket",
                    "port": "5901",
                    "upid": "UPID:node-a:1234:serial",
                }
            },
        )

    proxmox = ProxmoxClient(
        "https://proxmox.test:8006",
        "token",
        "secret",
        timeout=1,
        task_timeout=1,
    )
    proxmox.client.close()
    proxmox.client = httpx.Client(transport=httpx.MockTransport(handler))
    try:
        proxy = proxmox.create_serial_terminal_proxy("node-a", 500)
    finally:
        proxmox.client.close()

    assert proxy.port == 5901
    assert requests[0].url.path.endswith("/nodes/node-a/qemu/500/termproxy")
    assert requests[0].content == b"serial=serial0"


def test_serial_capture_reconnects_and_never_persists_console_ticket(tmp_path: Path) -> None:
    stop_event = Event()
    ready_event = Event()
    connection_number = 0

    class FakeProxy:
        user = "automation@pve"
        ticket = "private-console-ticket"
        port = 5901
        upid = "UPID:node-a:1234:serial"

    class FakeProxmox:
        api_origin = "https://proxmox.test:8006"
        authorization = "PVEAPIToken=token=private-api-secret"
        websocket_ssl_context = None
        timeout = 1

        def create_serial_terminal_proxy(self, _node: str, _vmid: int) -> FakeProxy:
            return FakeProxy()

    class FakeWebSocket:
        def __init__(self, number: int) -> None:
            self.number = number
            self.calls = 0
            self.sent: list[str] = []

        def __enter__(self) -> "FakeWebSocket":
            return self

        def __exit__(self, *_args: object) -> None:
            pass

        def send(self, value: str) -> None:
            assert value == "automation@pve:private-console-ticket\n"
            self.sent.append(value)

        def recv(self, **_kwargs: object) -> bytes:
            self.calls += 1
            if self.number == 1 and self.calls > 1:
                raise EOFError("guest reboot")
            if self.number == 2:
                stop_event.set()
                return b"OKsecond boot\n"
            return b"OKfirst boot\n"

    def fake_connect(url: str, **kwargs: object) -> FakeWebSocket:
        nonlocal connection_number
        connection_number += 1
        assert "private-console-ticket" in url
        assert kwargs["additional_headers"] == {
            "Authorization": "PVEAPIToken=token=private-api-secret"
        }
        return FakeWebSocket(connection_number)

    destination = tmp_path / "serial" / "vm1-serial-console.log"
    report = ProxmoxSerialCapture(
        FakeProxmox(),  # type: ignore[arg-type]
        reconnect_seconds=0.001,
        connect_factory=fake_connect,
    ).run("node-a", 500, destination, stop_event, ready_event)

    saved = destination.read_bytes()
    assert ready_event.is_set()
    assert report.payload_bytes == len(b"first boot\nsecond boot\n")
    assert report.connections == 2
    assert report.disconnects == 1
    assert b"first boot\n" in saved
    assert b"second boot\n" in saved
    assert b"private-console-ticket" not in saved
    assert b"private-api-secret" not in saved


def test_serial_capture_retries_a_transient_invalid_websocket_handshake(tmp_path: Path) -> None:
    stop_event = Event()
    ready_event = Event()
    connection_number = 0

    class FakeProxy:
        user = "automation@pve"
        ticket = "private-console-ticket"
        port = 5901
        upid = "UPID:node-a:1234:serial"

    class FakeProxmox:
        api_origin = "https://proxmox.test:8006"
        authorization = "PVEAPIToken=token=private-api-secret"
        websocket_ssl_context = None
        timeout = 1

        def create_serial_terminal_proxy(self, _node: str, _vmid: int) -> FakeProxy:
            return FakeProxy()

    class FakeWebSocket:
        def __enter__(self) -> "FakeWebSocket":
            return self

        def __exit__(self, *_args: object) -> None:
            pass

        def send(self, value: str) -> None:
            assert value == "automation@pve:private-console-ticket\n"

        def recv(self, **_kwargs: object) -> bytes:
            stop_event.set()
            return b"OKguest output\n"

    def fake_connect(_url: str, **_kwargs: object) -> FakeWebSocket:
        nonlocal connection_number
        connection_number += 1
        if connection_number == 1:
            raise InvalidMessage("temporary invalid proxy response")
        return FakeWebSocket()

    destination = tmp_path / "serial" / "vm1-serial-console.log"
    report = ProxmoxSerialCapture(
        FakeProxmox(),  # type: ignore[arg-type]
        reconnect_seconds=0.001,
        connect_factory=fake_connect,
    ).run("node-a", 500, destination, stop_event, ready_event)

    assert ready_event.is_set()
    assert report.payload_bytes == len(b"guest output\n")
    assert report.connections == 1
    assert report.disconnects == 1
