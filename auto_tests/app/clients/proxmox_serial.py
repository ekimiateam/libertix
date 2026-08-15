from __future__ import annotations

import os
import stat
import threading
from collections.abc import Callable
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import urlencode, urlsplit, urlunsplit

from websockets.exceptions import ConnectionClosed, InvalidHandshake
from websockets.sync.client import connect

from app.clients.proxmox import ProxmoxClient
from app.errors import WorkflowError


@dataclass(frozen=True)
class SerialCaptureReport:
    path: Path
    payload_bytes: int
    connections: int
    disconnects: int
    unavailable_reason: str | None = None


class ProxmoxSerialCapture:
    """Persist one VM serial stream across guest reboots."""

    _UNAVAILABLE_MARKERS = (
        b"serial interface 'serial0' is not configured",
        b'serial interface "serial0" is not configured',
    )

    def __init__(
        self,
        proxmox: ProxmoxClient,
        *,
        reconnect_seconds: float = 1,
        receive_timeout_seconds: float = 1,
        connect_factory: Callable[..., object] = connect,
    ) -> None:
        if reconnect_seconds <= 0 or receive_timeout_seconds <= 0:
            raise ValueError("Serial capture timeouts must be positive")
        self.proxmox = proxmox
        self.reconnect_seconds = reconnect_seconds
        self.receive_timeout_seconds = receive_timeout_seconds
        self.connect_factory = connect_factory

    @staticmethod
    def _timestamp() -> str:
        return datetime.now(UTC).isoformat(timespec="milliseconds")

    @staticmethod
    def _open_private_append_file(path: Path):
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor = os.open(
            path,
            os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_CLOEXEC | os.O_NOFOLLOW,
            0o600,
        )
        metadata = os.fstat(descriptor)
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != os.getuid()
            or metadata.st_nlink != 1
        ):
            os.close(descriptor)
            raise OSError("Serial capture target must be a private regular file")
        os.fchmod(descriptor, 0o600)
        return os.fdopen(descriptor, "ab", buffering=0)

    def _websocket_url(self, node: str, vmid: int, port: int, ticket: str) -> str:
        parsed = urlsplit(self.proxmox.api_origin)
        scheme = "wss" if parsed.scheme == "https" else "ws"
        path = f"/api2/json/nodes/{node}/qemu/{vmid}/vncwebsocket"
        query = urlencode({"port": port, "vncticket": ticket})
        return urlunsplit((scheme, parsed.netloc, path, query, ""))

    def run(
        self,
        node: str,
        vmid: int,
        destination: Path,
        stop_event: threading.Event,
        ready_event: threading.Event,
    ) -> SerialCaptureReport:
        payload_bytes = 0
        connections = 0
        disconnects = 0
        last_error: Exception | None = None
        diagnostic_tail = bytearray()
        unavailable_reason: str | None = None

        with self._open_private_append_file(destination) as output:
            output.write(
                f"\n[{self._timestamp()}] SERIAL_CAPTURE_START vmid={vmid} serial=serial0\n".encode(
                    "ascii"
                )
            )
            while not stop_event.is_set():
                try:
                    proxy = self.proxmox.create_serial_terminal_proxy(node, vmid)
                    url = self._websocket_url(node, vmid, proxy.port, proxy.ticket)
                    with self.connect_factory(
                        url,
                        ssl=self.proxmox.websocket_ssl_context,
                        subprotocols=["binary"],
                        compression=None,
                        additional_headers={"Authorization": self.proxmox.authorization},
                        proxy=None,
                        open_timeout=self.proxmox.timeout,
                        close_timeout=1,
                        ping_interval=20,
                        ping_timeout=10,
                        max_size=None,
                    ) as websocket:
                        connections += 1
                        output.write(
                            f"\n[{self._timestamp()}] SERIAL_CONNECTION_OPEN "
                            f"number={connections}\n".encode("ascii")
                        )
                        websocket.send(f"{proxy.user}:{proxy.ticket}\n")
                        authenticated = False
                        authentication_reply = bytearray()
                        while not stop_event.is_set():
                            try:
                                frame = websocket.recv(
                                    timeout=self.receive_timeout_seconds,
                                    decode=False,
                                )
                            except TimeoutError:
                                continue
                            if isinstance(frame, str):
                                chunk = frame.encode("utf-8", errors="replace")
                            else:
                                chunk = bytes(frame)
                            if not chunk:
                                continue
                            if not authenticated:
                                authentication_reply.extend(chunk)
                                if len(authentication_reply) < 2:
                                    continue
                                if authentication_reply[:2] != b"OK":
                                    raise WorkflowError(
                                        "automation.serial_capture",
                                        "The Proxmox serial-console proxy rejected authentication",
                                        details={"node": node, "vmid": vmid},
                                    )
                                authenticated = True
                                ready_event.set()
                                chunk = bytes(authentication_reply[2:])
                                authentication_reply.clear()
                            if chunk:
                                output.write(chunk)
                                payload_bytes += len(chunk)
                                diagnostic_tail.extend(chunk.lower())
                                if len(diagnostic_tail) > 4096:
                                    del diagnostic_tail[:-4096]
                                if any(
                                    marker in diagnostic_tail
                                    for marker in self._UNAVAILABLE_MARKERS
                                ):
                                    unavailable_reason = "serial0 is not configured on the VM"
                    last_error = None
                except (
                    ConnectionClosed,
                    InvalidHandshake,
                    EOFError,
                    OSError,
                    WorkflowError,
                ) as exc:
                    last_error = exc
                    disconnects += 1
                    output.write(
                        f"\n[{self._timestamp()}] SERIAL_CONNECTION_CLOSED "
                        f"number={disconnects} reason={type(exc).__name__}\n".encode("ascii")
                    )
                if not stop_event.is_set():
                    stop_event.wait(self.reconnect_seconds)

            output.write(
                f"\n[{self._timestamp()}] SERIAL_CAPTURE_STOP payload_bytes={payload_bytes} "
                f"connections={connections} disconnects={disconnects}\n".encode("ascii")
            )

        if connections == 0 and last_error is not None:
            raise WorkflowError(
                "automation.serial_capture",
                "The Proxmox serial console could not be opened",
                details={
                    "node": node,
                    "vmid": vmid,
                    "error_type": type(last_error).__name__,
                },
            ) from last_error
        return SerialCaptureReport(
            path=destination,
            payload_bytes=payload_bytes,
            connections=connections,
            disconnects=disconnects,
            unavailable_reason=unavailable_reason,
        )
