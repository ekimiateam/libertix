from __future__ import annotations

import logging
import time
from pathlib import Path

from vncdotool import api

from app.errors import WorkflowError

logger = logging.getLogger(__name__)
CAPTURE_MAX_ATTEMPTS = 3
CAPTURE_RETRY_SECONDS = 2


class VNCClient:
    def __init__(self, connect_timeout: float = 15) -> None:
        if connect_timeout <= 0:
            raise ValueError("connect_timeout must be positive")
        self.connect_timeout = connect_timeout

    def connect(self, address: str):
        return api.connect(self.vncdotool_address(address), timeout=self.connect_timeout)

    @staticmethod
    def vncdotool_address(address: str) -> str:
        host, separator, display = address.rpartition(":")
        if not separator or not host or not display.isdigit():
            raise WorkflowError("vnc.address", "Invalid VNC address", details={"address": address})
        # vncdotool expects host::port, while Proxmox exposes host:display and
        # maps display N to TCP port 5900 + N.
        return f"{host}::{5900 + int(display)}"

    def capture(self, address: str, destination: Path) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        logger.info("VNC capture started", extra={"step": "vnc.capture", "target": address})
        last_error: Exception | None = None
        for attempt in range(1, CAPTURE_MAX_ATTEMPTS + 1):
            client = None
            try:
                client = self.connect(address)
                # Long downloads can let Windows blank the virtual display. A pointer move wakes
                # it without changing focus, clicking a control, or sending keyboard input.
                client.mouseMove(1, 1)
                time.sleep(0.25)
                client.captureScreen(str(destination))
                last_error = None
                break
            except Exception as exc:
                last_error = exc
                destination.unlink(missing_ok=True)
                if attempt < CAPTURE_MAX_ATTEMPTS:
                    logger.warning(
                        "Transient VNC capture failure; retrying",
                        extra={"step": "vnc.capture_retry", "target": address},
                    )
                    time.sleep(CAPTURE_RETRY_SECONDS)
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
        if not destination.is_file() or destination.stat().st_size == 0:
            raise WorkflowError(
                "vnc.capture", "The VNC capture is missing or empty", details={"address": address}
            )
        logger.info("VNC capture completed", extra={"step": "vnc.capture", "target": address})
        return destination
