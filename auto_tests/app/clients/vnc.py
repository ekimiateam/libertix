from __future__ import annotations

import logging
import threading
import time
from collections.abc import Callable
from pathlib import Path

from PIL import Image
from vncdotool import api, rfb
from vncdotool.client import VNCDoToolClient, VNCDoToolFactory

from app.errors import WorkflowError

logger = logging.getLogger(__name__)
CAPTURE_MAX_ATTEMPTS = 5
CAPTURE_RETRY_SECONDS = 5


class CompressedVNCProtocol(VNCDoToolClient):
    # Raw full-screen transfers exceed the capture deadline on slow lab links.
    encoding = rfb.Encoding.ZRLE


class CompressedVNCFactory(VNCDoToolFactory):
    protocol = CompressedVNCProtocol


def _is_valid_capture(path: Path) -> bool:
    if not path.is_file() or path.stat().st_size == 0:
        return False
    try:
        with Image.open(path) as capture:
            capture.verify()
    except (OSError, ValueError, SyntaxError):
        return False
    return True


class VNCClient:
    _connect_lock = threading.Lock()

    def __init__(self, connect_timeout: float = 15) -> None:
        if connect_timeout <= 0:
            raise ValueError("connect_timeout must be positive")
        self.connect_timeout = connect_timeout

    def connect(self, address: str):
        # vncdotool lazily starts one process-wide Twisted reactor. Concurrent
        # first connections can both observe it as stopped and race to start it.
        # Serialize only connection establishment; VM workflows remain parallel.
        with self._connect_lock:
            return api.connect(
                self.vncdotool_address(address),
                factory_class=CompressedVNCFactory,
                timeout=self.connect_timeout,
            )

    @staticmethod
    def vncdotool_address(address: str) -> str:
        host, separator, display = address.rpartition(":")
        if not separator or not host or not display.isdigit():
            raise WorkflowError("vnc.address", "Invalid VNC address", details={"address": address})
        # vncdotool expects host::port, while Proxmox exposes host:display and
        # maps display N to TCP port 5900 + N.
        return f"{host}::{5900 + int(display)}"

    def capture(
        self,
        address: str,
        destination: Path,
        *,
        on_captured: Callable[[Path], None] | None = None,
    ) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        logger.info("VNC capture started", extra={"step": "vnc.capture", "target": address})
        last_error: Exception | None = None
        for attempt in range(1, CAPTURE_MAX_ATTEMPTS + 1):
            client = None
            destination.unlink(missing_ok=True)
            try:
                client = self.connect(address)
                # Long downloads can let Windows blank the virtual display. A pointer move wakes
                # it without changing focus, clicking a control, or sending keyboard input.
                client.mouseMove(1, 1)
                time.sleep(0.25)
                client.captureScreen(str(destination))
                if not _is_valid_capture(destination):
                    raise ValueError("VNC capture is not a complete image")
                last_error = None
                break
            except Exception as exc:
                # A reboot can close VNC after captureScreen has written the complete PNG but
                # before its protocol request returns. The image remains valid evidence.
                if _is_valid_capture(destination):
                    logger.info(
                        "VNC capture completed before the transport disconnected",
                        extra={"step": "vnc.capture_transport_closed", "target": address},
                    )
                    last_error = None
                    break
                last_error = exc
                if attempt < CAPTURE_MAX_ATTEMPTS:
                    logger.warning(
                        "Transient VNC capture failure; retrying",
                        extra={"step": "vnc.capture_retry", "target": address},
                    )
                    time.sleep(CAPTURE_RETRY_SECONDS)
            finally:
                try:
                    # Coordination deadlines must not include slow VNC disconnects.
                    if (
                        on_captured is not None
                        and last_error is None
                        and _is_valid_capture(destination)
                    ):
                        on_captured(destination)
                finally:
                    if client is not None:
                        try:
                            client.disconnect()
                        except Exception:
                            logger.warning(
                                "VNC connection did not close cleanly",
                                extra={"step": "vnc.close", "target": address},
                            )
        if last_error is not None:
            raise WorkflowError(
                "vnc.capture",
                "VNC capture failed",
                details={
                    "address": address,
                    "attempts": CAPTURE_MAX_ATTEMPTS,
                    "error": str(last_error),
                },
            ) from last_error
        if not _is_valid_capture(destination):
            raise WorkflowError(
                "vnc.capture",
                "The VNC capture is missing or invalid",
                details={"address": address},
            )
        logger.info("VNC capture completed", extra={"step": "vnc.capture", "target": address})
        return destination
