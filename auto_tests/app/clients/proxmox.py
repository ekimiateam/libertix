from __future__ import annotations

import logging
import re
import ssl
import time
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import quote, urlencode

import httpx

from app.errors import WorkflowError

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class SerialTerminalProxy:
    user: str
    ticket: str
    port: int
    upid: str


class ProxmoxClient:
    def __init__(
        self,
        base_url: str,
        token_id: str,
        token_secret: str,
        *,
        timeout: float,
        task_timeout: float,
        verify_tls: bool = True,
        ca_bundle: Path | None = None,
    ) -> None:
        self.api_origin = base_url.rstrip("/")
        self.base_url = self.api_origin + "/api2/json"
        self.task_timeout = task_timeout
        self.timeout = timeout
        self.authorization = f"PVEAPIToken={token_id}={token_secret}"

        # TLS verification is the safe default. Private Proxmox deployments may
        # opt into their own CA bundle; disabling verification requires an
        # explicit runtime setting and is never hidden in the transport client.
        tls_verification: bool | ssl.SSLContext = verify_tls
        websocket_ssl_context: ssl.SSLContext | None = None
        if ca_bundle is not None:
            tls_verification = ssl.create_default_context(cafile=str(ca_bundle))
            websocket_ssl_context = ssl.create_default_context(cafile=str(ca_bundle))
        elif self.api_origin.startswith("https://"):
            websocket_ssl_context = ssl.create_default_context()
            if not verify_tls:
                websocket_ssl_context.check_hostname = False
                websocket_ssl_context.verify_mode = ssl.CERT_NONE
        self.websocket_ssl_context = websocket_ssl_context
        self.client = httpx.Client(
            headers={"Authorization": self.authorization},
            verify=tls_verification,
            timeout=timeout,
        )

    def __enter__(self) -> ProxmoxClient:
        return self

    def __exit__(self, *_args: object) -> None:
        self.client.close()

    def _request(
        self,
        method: str,
        path: str,
        *,
        step: str,
        data: dict[str, object] | None = None,
    ) -> object:
        logger.info("Proxmox request", extra={"step": step, "target": path})
        try:
            response = self.client.request(method, f"{self.base_url}{path}", data=data)
            response.raise_for_status()
            return response.json()["data"]
        except (httpx.HTTPError, ValueError, KeyError) as exc:
            response = getattr(exc, "response", None)
            raise WorkflowError(
                step,
                "Proxmox request failed",
                details={
                    "path": path,
                    "http_status": getattr(response, "status_code", None),
                    "response_body": getattr(response, "text", "")[-2000:],
                    "exception_type": type(exc).__name__,
                    "error": str(exc),
                },
            ) from exc

    def locate_vm(self, vmid: int) -> str:
        nodes = self._request("GET", "/nodes", step="proxmox.list_nodes")
        if not isinstance(nodes, list):
            raise WorkflowError("proxmox.list_nodes", "Invalid node-list response")
        for item in nodes:
            if not isinstance(item, dict) or not item.get("node"):
                continue
            node = str(item["node"])
            path = f"/nodes/{node}/qemu/{vmid}/status/current"
            logger.info("Looking up target VM", extra={"step": "proxmox.locate_vm", "target": path})
            try:
                response = self.client.get(f"{self.base_url}{path}")
            except httpx.HTTPError as exc:
                raise WorkflowError(
                    "proxmox.locate_vm",
                    "Network failure while locating target VM",
                    details={"vmid": vmid, "node": node, "error": str(exc)},
                ) from exc
            if response.status_code == 200:
                return node
            if response.status_code in (401, 403):
                raise WorkflowError(
                    "proxmox.permissions",
                    "The Proxmox token lacks VM.Audit on the target VM",
                    details={
                        "vmid": vmid,
                        "node": node,
                        "http_status": response.status_code,
                        "response_body": response.text[-2000:],
                    },
                )
            if response.status_code != 404:
                raise WorkflowError(
                    "proxmox.locate_vm",
                    "Unexpected target VM response",
                    details={"vmid": vmid, "node": node, "http_status": response.status_code},
                )
        raise WorkflowError("proxmox.locate_vm", "Target VM not found", details={"vmid": vmid})

    def assert_snapshot(self, node: str, vmid: int, snapshot: str) -> None:
        data = self._request(
            "GET", f"/nodes/{node}/qemu/{vmid}/snapshot", step="proxmox.check_snapshot"
        )
        names = (
            {item.get("name") for item in data if isinstance(item, dict)}
            if isinstance(data, list)
            else set()
        )
        if snapshot not in names:
            raise WorkflowError(
                "proxmox.check_snapshot",
                "Required snapshot is missing",
                details={"vmid": vmid, "snapshot": snapshot},
            )

    def get_vm_status(self, node: str, vmid: int, *, step: str) -> dict[str, object]:
        data = self._request("GET", f"/nodes/{node}/qemu/{vmid}/status/current", step=step)
        if not isinstance(data, dict):
            raise WorkflowError(
                step,
                "Invalid Proxmox VM-status response",
                details={"vmid": vmid, "node": node},
            )
        return data

    def create_serial_terminal_proxy(
        self,
        node: str,
        vmid: int,
        *,
        serial: str = "serial0",
    ) -> SerialTerminalProxy:
        data = self._request(
            "POST",
            f"/nodes/{node}/qemu/{vmid}/termproxy",
            step="proxmox.serial_proxy",
            data={"serial": serial},
        )
        if not isinstance(data, dict):
            raise WorkflowError(
                "proxmox.serial_proxy",
                "Invalid Proxmox serial-terminal proxy response",
                details={"node": node, "vmid": vmid},
            )
        user = data.get("user")
        ticket = data.get("ticket")
        raw_port = data.get("port")
        upid = data.get("upid")
        if isinstance(raw_port, int):
            port = raw_port
        elif isinstance(raw_port, str) and raw_port.isascii() and raw_port.isdigit():
            port = int(raw_port)
        else:
            port = None
        if (
            not isinstance(user, str)
            or not user
            or not isinstance(ticket, str)
            or not ticket
            or port is None
            or not 5900 <= port <= 5999
            or not isinstance(upid, str)
            or not upid.startswith("UPID:")
        ):
            raise WorkflowError(
                "proxmox.serial_proxy",
                "Incomplete Proxmox serial-terminal proxy response",
                details={
                    "node": node,
                    "vmid": vmid,
                    "has_user": isinstance(user, str) and bool(user),
                    "has_ticket": isinstance(ticket, str) and bool(ticket),
                    "port": port,
                    "has_upid": isinstance(upid, str) and upid.startswith("UPID:"),
                },
            )
        return SerialTerminalProxy(user=user, ticket=ticket, port=port, upid=upid)

    def get_guest_network_interfaces(
        self,
        node: str,
        vmid: int,
        *,
        step: str,
    ) -> list[dict[str, object]]:
        data = self._request(
            "GET",
            f"/nodes/{node}/qemu/{vmid}/agent/network-get-interfaces",
            step=step,
        )
        result = data.get("result", data) if isinstance(data, dict) else data
        if not isinstance(result, list) or not all(isinstance(item, dict) for item in result):
            raise WorkflowError(
                step,
                "Invalid QEMU guest-agent network response",
                details={"vmid": vmid, "node": node},
            )
        return result

    def execute_guest_agent_command(
        self,
        node: str,
        vmid: int,
        command: list[str],
        *,
        step: str,
        timeout: float,
    ) -> dict[str, object]:
        if not command or any(
            not isinstance(argument, str) or "\0" in argument for argument in command
        ):
            raise ValueError("command must contain non-NUL string arguments")

        path = f"/nodes/{node}/qemu/{vmid}/agent/exec"
        try:
            response = self.client.post(
                f"{self.base_url}{path}",
                content=urlencode([("command", argument) for argument in command]).encode("ascii"),
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )
            response.raise_for_status()
            data = response.json()["data"]
        except (httpx.HTTPError, ValueError, KeyError) as exc:
            response = getattr(exc, "response", None)
            raise WorkflowError(
                step,
                "QEMU guest-agent command could not be started",
                details={
                    "vmid": vmid,
                    "node": node,
                    "http_status": getattr(response, "status_code", None),
                    "response_body": getattr(response, "text", "")[-2000:],
                    "exception_type": type(exc).__name__,
                    "error": str(exc),
                },
            ) from exc

        result = data.get("result", data) if isinstance(data, dict) else data
        pid = result.get("pid") if isinstance(result, dict) else None
        if not isinstance(pid, int):
            raise WorkflowError(
                step,
                "QEMU guest-agent command returned no process identifier",
                details={"vmid": vmid, "node": node},
            )

        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                response = self.client.get(
                    f"{self.base_url}/nodes/{node}/qemu/{vmid}/agent/exec-status",
                    params={"pid": pid},
                )
                response.raise_for_status()
                data = response.json()["data"]
            except (httpx.HTTPError, ValueError, KeyError) as exc:
                response = getattr(exc, "response", None)
                raise WorkflowError(
                    step,
                    "QEMU guest-agent command status could not be read",
                    details={
                        "vmid": vmid,
                        "node": node,
                        "http_status": getattr(response, "status_code", None),
                        "response_body": getattr(response, "text", "")[-2000:],
                        "exception_type": type(exc).__name__,
                        "error": str(exc),
                    },
                ) from exc
            result = data.get("result", data) if isinstance(data, dict) else data
            if isinstance(result, dict) and result.get("exited"):
                return result
            time.sleep(0.5)

        raise WorkflowError(
            step,
            "QEMU guest-agent command timed out",
            details={"vmid": vmid, "node": node, "timeout_seconds": timeout},
        )

    def verify_rollback_state(
        self,
        node: str,
        vmid: int,
        snapshot: str,
        *,
        require_running: bool,
    ) -> dict[str, object]:
        snapshots = self._request(
            "GET",
            f"/nodes/{node}/qemu/{vmid}/snapshot",
            step="proxmox.verify_rollback_snapshot",
        )
        current = (
            [item for item in snapshots if isinstance(item, dict) and item.get("name") == "current"]
            if isinstance(snapshots, list)
            else []
        )
        if len(current) != 1 or str(current[0].get("parent") or "") != snapshot:
            raise WorkflowError(
                "proxmox.verify_rollback_snapshot",
                "The VM current state is not based on the requested snapshot",
                details={
                    "vmid": vmid,
                    "node": node,
                    "expected_snapshot": snapshot,
                    "current_count": len(current),
                    "current_parent": (
                        str(current[0].get("parent") or "") if len(current) == 1 else ""
                    ),
                },
            )

        status_data = self.get_vm_status(node, vmid, step="proxmox.verify_rollback_status")
        status = str(status_data.get("status") or "")
        qmpstatus = str(status_data.get("qmpstatus") or "")
        if status not in {"running", "stopped"} or qmpstatus == "io-error":
            raise WorkflowError(
                "proxmox.verify_rollback_status",
                "The VM is not in a healthy post-rollback state",
                details={
                    "vmid": vmid,
                    "node": node,
                    "status": status,
                    "qmpstatus": qmpstatus,
                },
            )
        if require_running and (status != "running" or qmpstatus != "running"):
            raise WorkflowError(
                "proxmox.verify_rollback_status",
                "The automation VM is not running after snapshot rollback",
                details={
                    "vmid": vmid,
                    "node": node,
                    "status": status,
                    "qmpstatus": qmpstatus,
                },
            )
        return {
            "snapshot_parent": snapshot,
            "status": status,
            "qmpstatus": qmpstatus,
        }

    def rollback(self, node: str, vmid: int, snapshot: str) -> None:
        data = self._request(
            "POST",
            f"/nodes/{node}/qemu/{vmid}/snapshot/{snapshot}/rollback",
            step="proxmox.rollback",
        )
        if not isinstance(data, str) or not data.startswith("UPID:"):
            raise WorkflowError("proxmox.rollback", "Invalid Proxmox UPID", details={"vmid": vmid})
        self._wait_task(node, data, vmid, action="rollback")

    def _wait_task(self, node: str, upid: str, vmid: int, *, action: str) -> None:
        deadline = time.monotonic() + self.task_timeout
        encoded = quote(upid, safe="")
        while time.monotonic() < deadline:
            data = self._request(
                "GET", f"/nodes/{node}/tasks/{encoded}/status", step="proxmox.wait_task"
            )
            if isinstance(data, dict) and data.get("status") == "stopped":
                exit_status = str(data.get("exitstatus") or "")
                if exit_status == "OK":
                    return
                if re.fullmatch(r"WARNINGS: [1-9][0-9]*", exit_status):
                    # Proxmox reports completed tasks with non-fatal warnings
                    # separately from failed tasks. The caller validates the
                    # resulting VM state after the task completes.
                    logger.warning(
                        "Proxmox task completed with warnings",
                        extra={"step": "proxmox.wait_task", "target": str(vmid)},
                    )
                    return
                else:
                    raise WorkflowError(
                        "proxmox.wait_task",
                        "Proxmox task failed",
                        details={
                            "vmid": vmid,
                            "action": action,
                            "exitstatus": exit_status,
                        },
                    )
            time.sleep(2)
        raise WorkflowError(
            "proxmox.wait_task",
            "Proxmox task timeout exceeded",
            details={"vmid": vmid, "action": action},
        )
