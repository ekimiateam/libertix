from __future__ import annotations

import logging
import tempfile
import time
from pathlib import Path
from uuid import uuid4

from vncdotool import api

from app.errors import WorkflowError

logger = logging.getLogger(__name__)


class VNCClient:
    @staticmethod
    def _vncdotool_address(address: str) -> str:
        host, separator, display = address.rpartition(":")
        if not separator or not host or not display.isdigit():
            raise WorkflowError("vnc.address", "Invalid VNC address", details={"address": address})
        # vncdotool expects host::port, while Proxmox exposes host:display and
        # maps display N to TCP port 5900 + N.
        return f"{host}::{5900 + int(display)}"

    def capture(self, address: str, destination: Path) -> Path:
        destination.parent.mkdir(parents=True, exist_ok=True)
        logger.info("VNC capture started", extra={"step": "vnc.capture", "target": address})
        client = None
        try:
            client = api.connect(self._vncdotool_address(address))
            # Long downloads can let Windows blank the virtual display. A pointer move wakes
            # it without changing focus, clicking a control, or sending keyboard input.
            client.mouseMove(1, 1)
            time.sleep(0.25)
            client.captureScreen(str(destination))
        except Exception as exc:
            destination.unlink(missing_ok=True)
            raise WorkflowError(
                "vnc.capture",
                "VNC capture failed",
                details={"address": address, "error": str(exc)},
            ) from exc
        finally:
            if client is not None:
                try:
                    client.disconnect()
                except Exception:
                    logger.warning(
                        "Fermeture VNC imparfaite", extra={"step": "vnc.close", "target": address}
                    )
        if not destination.is_file() or destination.stat().st_size == 0:
            raise WorkflowError(
                "vnc.capture", "The VNC capture is missing or empty", details={"address": address}
            )
        logger.info("VNC capture completed", extra={"step": "vnc.capture", "target": address})
        return destination

    def launch_desktop_shortcut(self, address: str, *, width: int, height: int) -> None:
        logger.info("Lancement interactif VNC", extra={"step": "vnc.launch", "target": address})
        client = None
        try:
            client = api.connect(self._vncdotool_address(address))
            time.sleep(1)
            # The clean2 snapshots place the Libertix shortcut in the fourth
            # desktop-icon slot; the following capture synchronizes the click.
            client.mouseMove(48, 330)
            client.mousePress(1)
            sync_path = Path(tempfile.gettempdir()) / f"vnc-sync-{uuid4().hex}.png"
            try:
                client.captureScreen(str(sync_path))
            finally:
                sync_path.unlink(missing_ok=True)
            client.keyPress("enter")
            time.sleep(1)
        except Exception as exc:
            raise WorkflowError(
                "vnc.launch",
                "Failed to activate the Libertix desktop shortcut",
                details={"address": address, "error": str(exc)},
            ) from exc
        finally:
            if client is not None:
                try:
                    client.disconnect()
                except Exception:
                    logger.warning(
                        "Fermeture VNC imparfaite", extra={"step": "vnc.close", "target": address}
                    )
