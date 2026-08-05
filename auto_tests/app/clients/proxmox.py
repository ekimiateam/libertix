from __future__ import annotations

import logging
import ssl
import time
from pathlib import Path
from urllib.parse import quote

import httpx

from app.errors import WorkflowError

logger = logging.getLogger(__name__)


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
        self.base_url = base_url.rstrip("/") + "/api2/json"
        self.task_timeout = task_timeout

        # TLS verification is the safe default. Private Proxmox deployments may
        # opt into their own CA bundle; disabling verification requires an
        # explicit runtime setting and is never hidden in the transport client.
        tls_verification: bool | ssl.SSLContext = verify_tls
        if ca_bundle is not None:
            tls_verification = ssl.create_default_context(cafile=str(ca_bundle))
        self.client = httpx.Client(
            headers={"Authorization": f"PVEAPIToken={token_id}={token_secret}"},
            verify=tls_verification,
            timeout=timeout,
        )

    def __enter__(self) -> ProxmoxClient:
        return self

    def __exit__(self, *_args: object) -> None:
        self.client.close()

    def _request(self, method: str, path: str, *, step: str) -> object:
        logger.info("Proxmox request", extra={"step": step, "target": path})
        try:
            response = self.client.request(method, f"{self.base_url}{path}")
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

    def rollback(self, node: str, vmid: int, snapshot: str) -> None:
        data = self._request(
            "POST",
            f"/nodes/{node}/qemu/{vmid}/snapshot/{snapshot}/rollback",
            step="proxmox.rollback",
        )
        if not isinstance(data, str) or not data.startswith("UPID:"):
            raise WorkflowError("proxmox.rollback", "Invalid Proxmox UPID", details={"vmid": vmid})
        self._wait_task(node, data, vmid)

    def _wait_task(self, node: str, upid: str, vmid: int) -> None:
        deadline = time.monotonic() + self.task_timeout
        encoded = quote(upid, safe="")
        while time.monotonic() < deadline:
            data = self._request(
                "GET", f"/nodes/{node}/tasks/{encoded}/status", step="proxmox.wait_task"
            )
            if isinstance(data, dict) and data.get("status") == "stopped":
                if data.get("exitstatus") != "OK":
                    raise WorkflowError(
                        "proxmox.wait_task",
                        "Proxmox rollback failed",
                        details={"vmid": vmid, "exitstatus": data.get("exitstatus")},
                    )
                return
            time.sleep(2)
        raise WorkflowError(
            "proxmox.wait_task", "Rollback timeout exceeded", details={"vmid": vmid}
        )
