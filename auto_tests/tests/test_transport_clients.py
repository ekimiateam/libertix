from __future__ import annotations

from pathlib import Path
from types import SimpleNamespace

import pytest

import app.clients.ssh as ssh_module
import app.clients.vnc as vnc_module
from app.clients.ssh import SSHClient
from app.clients.vnc import VNCClient
from app.errors import WorkflowError


class FakeChannel:
    def __init__(self, stdout: bytes = b"", stderr: bytes = b"", exit_code: int = 0) -> None:
        self.stdout = bytearray(stdout)
        self.stderr = bytearray(stderr)
        self.exit_code = exit_code
        self.closed = False
        self.input_closed = False

    def recv_ready(self) -> bool:
        return bool(self.stdout)

    def recv_stderr_ready(self) -> bool:
        return bool(self.stderr)

    def recv(self, size: int) -> bytes:
        chunk = bytes(self.stdout[:size])
        del self.stdout[:size]
        return chunk

    def recv_stderr(self, size: int) -> bytes:
        chunk = bytes(self.stderr[:size])
        del self.stderr[:size]
        return chunk

    def exit_status_ready(self) -> bool:
        return not self.stdout and not self.stderr

    def recv_exit_status(self) -> int:
        return self.exit_code

    def close(self) -> None:
        self.closed = True

    def shutdown_write(self) -> None:
        self.input_closed = True


class FakeStdin:
    def __init__(self, channel: FakeChannel) -> None:
        self.channel = channel
        self.content = ""

    def write(self, content: str) -> None:
        self.content += content

    def flush(self) -> None:
        pass


class FakeParamikoClient:
    def __init__(self, channel: FakeChannel | None = None) -> None:
        self.channel = channel or FakeChannel()
        self.connect_kwargs: dict[str, object] | None = None
        self.loaded_host_keys: str | None = None
        self.missing_host_key_policy: object | None = None
        self.closed = False
        self.last_stdin: FakeStdin | None = None

    def load_host_keys(self, path: str) -> None:
        self.loaded_host_keys = path

    def set_missing_host_key_policy(self, policy: object) -> None:
        self.missing_host_key_policy = policy

    def connect(self, host: str, **kwargs: object) -> None:
        self.connect_kwargs = {"host": host, **kwargs}

    def exec_command(self, _command: str, *, timeout: float):
        assert timeout > 0
        stream = SimpleNamespace(channel=self.channel)
        self.last_stdin = FakeStdin(self.channel)
        return self.last_stdin, stream, stream

    def get_transport(self):
        key = SimpleNamespace(asbytes=lambda: b"ephemeral-test-key")
        return SimpleNamespace(get_remote_server_key=lambda: key)

    def close(self) -> None:
        self.closed = True


def test_ssh_client_connects_with_password_only_and_drains_both_streams(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport = FakeParamikoClient(FakeChannel(b"result\n", b"warning\n", 0))
    monkeypatch.setattr(ssh_module.paramiko, "SSHClient", lambda: transport)

    with SSHClient(
        "example.test",
        "oem",
        "secret",
        known_hosts_path="/tmp/test-known-hosts",
        port=2222,
        connect_timeout=4,
    ) as client:
        result = client.run("hostname", step="ssh.hostname", timeout=5)

    assert result.stdout == "result"
    assert result.stderr == "warning"
    assert result.exit_code == 0
    assert transport.connect_kwargs == {
        "host": "example.test",
        "port": 2222,
        "username": "oem",
        "password": "secret",
        "timeout": 4,
        "banner_timeout": 4,
        "auth_timeout": 4,
        "look_for_keys": False,
        "allow_agent": False,
    }
    assert transport.closed is True
    assert transport.loaded_host_keys == "/tmp/test-known-hosts"
    assert isinstance(transport.missing_host_key_policy, ssh_module.paramiko.RejectPolicy)


def test_ssh_failure_never_exposes_a_sensitive_command(monkeypatch: pytest.MonkeyPatch) -> None:
    transport = FakeParamikoClient(FakeChannel(b"partial", b"denied", 5))
    monkeypatch.setattr(ssh_module.paramiko, "SSHClient", lambda: transport)

    with (
        SSHClient(
            "example.test", "oem", "secret", known_hosts_path="/tmp/test-known-hosts"
        ) as client,
        pytest.raises(WorkflowError) as caught,
    ):
        client.run(
            "command --password top-secret",
            step="ssh.sensitive",
            timeout=5,
            sensitive=True,
        )

    assert caught.value.details["command"] == "[COMMANDE SENSIBLE MASQUÉE]"
    assert "top-secret" not in str(caught.value.as_dict())
    assert caught.value.details["exit_code"] == 5


def test_ssh_client_writes_sensitive_input_to_stdin(monkeypatch: pytest.MonkeyPatch) -> None:
    transport = FakeParamikoClient()
    monkeypatch.setattr(ssh_module.paramiko, "SSHClient", lambda: transport)

    with SSHClient(
        "example.test", "oem", "secret", known_hosts_path="/tmp/test-known-hosts"
    ) as client:
        client.run(
            "sudo -S true",
            step="ssh.stdin",
            timeout=5,
            sensitive=True,
            stdin_data="secret\n",
        )

    assert transport.last_stdin is not None
    assert transport.last_stdin.content == "secret\n"
    assert transport.channel.input_closed is True


def test_ssh_connection_failure_closes_the_partial_transport(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    transport = FakeParamikoClient()

    def fail_connect(_host: str, **_kwargs: object) -> None:
        raise OSError("network unavailable")

    transport.connect = fail_connect  # type: ignore[method-assign]
    monkeypatch.setattr(ssh_module.paramiko, "SSHClient", lambda: transport)

    with (
        pytest.raises(WorkflowError) as caught,
        SSHClient("example.test", "oem", "secret", known_hosts_path="/tmp/test-known-hosts"),
    ):
        pass

    assert caught.value.step == "ssh.connect"
    assert caught.value.details["exception_type"] == "OSError"
    assert transport.closed is True


class FakeVncConnection:
    def __init__(self, *, fail_capture: bool = False) -> None:
        self.fail_capture = fail_capture
        self.events: list[tuple[object, ...]] = []
        self.disconnected = False

    def mouseMove(self, x: int, y: int) -> None:  # noqa: N802
        self.events.append(("move", x, y))

    def mousePress(self, button: int) -> None:  # noqa: N802
        self.events.append(("press", button))

    def keyPress(self, key: str) -> None:  # noqa: N802
        self.events.append(("key", key))

    def captureScreen(self, destination: str) -> None:  # noqa: N802
        self.events.append(("capture", destination))
        if self.fail_capture:
            raise RuntimeError("capture failed")
        Path(destination).write_bytes(b"png")

    def disconnect(self) -> None:
        self.disconnected = True


def test_vnc_capture_wakes_the_display_and_always_disconnects(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    connection = FakeVncConnection()
    addresses: list[str] = []
    monkeypatch.setattr(
        vnc_module.api,
        "connect",
        lambda address: addresses.append(address) or connection,
    )
    monkeypatch.setattr(vnc_module.time, "sleep", lambda _seconds: None)

    destination = tmp_path / "capture.png"
    result = VNCClient().capture("192.0.2.10:12", destination)

    assert result == destination
    assert destination.read_bytes() == b"png"
    assert addresses == ["192.0.2.10::5912"]
    assert connection.events[0] == ("move", 1, 1)
    assert connection.disconnected is True


def test_vnc_capture_failure_removes_only_its_incomplete_output(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    connection = FakeVncConnection(fail_capture=True)
    monkeypatch.setattr(vnc_module.api, "connect", lambda _address: connection)
    monkeypatch.setattr(vnc_module.time, "sleep", lambda _seconds: None)
    destination = tmp_path / "capture.png"
    destination.write_bytes(b"stale")

    with pytest.raises(WorkflowError, match="Capture VNC impossible"):
        VNCClient().capture("192.0.2.10:12", destination)

    assert not destination.exists()
    assert connection.disconnected is True


@pytest.mark.parametrize("address", ["", "host", ":10", "host:not-a-display"])
def test_vnc_rejects_invalid_addresses_before_connecting(address: str) -> None:
    with pytest.raises(WorkflowError) as caught:
        VNCClient._vncdotool_address(address)

    assert caught.value.step == "vnc.address"
