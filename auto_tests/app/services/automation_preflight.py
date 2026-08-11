"""Proxmox preflight and snapshot restoration for UI automation."""

from __future__ import annotations

from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed

from app.clients.proxmox import ProxmoxClient
from app.config import Settings
from app.errors import WorkflowError
from app.services.automation_types import WizardProfile
from app.services.common import ResultBuilder

GIB = 1024**3


class AutomationPreflight:
    """Validate all selected VMs before restoring any clean snapshot.

    The factory opens a fresh Proxmox client per concurrent rollback. This
    avoids sharing an HTTP session between worker threads while preserving the
    all-VM preflight barrier used by the original implementation.
    """

    def __init__(
        self,
        proxmox_factory: Callable[[], ProxmoxClient],
        settings: Settings,
    ) -> None:
        self._proxmox_factory = proxmox_factory
        self._settings = settings

    def restore_clean_snapshot(self, result: ResultBuilder, profile: WizardProfile) -> None:
        vmid = profile.vmid
        with self._proxmox_factory() as proxmox:
            node = proxmox.locate_vm(vmid)
            proxmox.assert_snapshot(node, vmid, self._settings.reset_snapshot)
            result.ok(
                "automation.rollback_preflight",
                "VM and snapshot verified before automation",
                target=str(vmid),
                node=node,
                snapshot=self._settings.reset_snapshot,
            )
            proxmox.rollback(node, vmid, self._settings.reset_snapshot)
            verified = proxmox.verify_rollback_state(
                node,
                vmid,
                self._settings.reset_snapshot,
                require_running=True,
            )
            result.ok(
                "automation.reset_vm_done",
                f"VM{vmid} reset completed: configured snapshot restored and Proxmox task verified",
                target=str(vmid),
                node=node,
                snapshot=self._settings.reset_snapshot,
                **verified,
            )

    def restore_clean_snapshots(
        self,
        result: ResultBuilder,
        profiles: Sequence[WizardProfile],
    ) -> None:
        locations: dict[int, str] = {}
        with self._proxmox_factory() as proxmox:
            for profile in profiles:
                node = proxmox.locate_vm(profile.vmid)
                proxmox.assert_snapshot(node, profile.vmid, self._settings.reset_snapshot)
                self.assert_vm_not_in_io_error(proxmox, node, profile.vmid, result)
                locations[profile.vmid] = node
                result.ok(
                    "automation.rollback_preflight",
                    "VM and snapshot verified before automation",
                    target=str(profile.vmid),
                    node=node,
                    snapshot=self._settings.reset_snapshot,
                )
            self.assert_proxmox_storage_headroom(proxmox, locations, len(profiles), result)

        def restore(profile: WizardProfile) -> tuple[int, str, dict[str, object]]:
            node = locations[profile.vmid]
            with self._proxmox_factory() as proxmox:
                proxmox.rollback(node, profile.vmid, self._settings.reset_snapshot)
                verified = proxmox.verify_rollback_state(
                    node,
                    profile.vmid,
                    self._settings.reset_snapshot,
                    require_running=True,
                )
            return profile.vmid, node, verified

        with ThreadPoolExecutor(max_workers=len(profiles)) as executor:
            futures = {executor.submit(restore, profile): profile for profile in profiles}
            for future in as_completed(futures):
                vmid, node, verified = future.result()
                result.ok(
                    "automation.reset_vm_done",
                    f"VM{vmid} reset completed: configured snapshot restored "
                    "and Proxmox task verified",
                    target=str(vmid),
                    node=node,
                    snapshot=self._settings.reset_snapshot,
                    **verified,
                )

    @staticmethod
    def assert_vm_not_in_io_error(
        proxmox: ProxmoxClient,
        node: str,
        vmid: int,
        result: ResultBuilder,
    ) -> None:
        data = proxmox.get_vm_status(node, vmid, step="automation.vm_status")
        qmpstatus = str(data.get("qmpstatus") or "")
        status = str(data.get("status") or "")
        if qmpstatus == "io-error":
            raise WorkflowError(
                "automation.vm_io_error",
                "Automation refused: the VM is in Proxmox io-error before rollback",
                details={"vmid": vmid, "node": node, "status": status, "qmpstatus": qmpstatus},
            )
        result.ok(
            "automation.vm_status",
            "Proxmox VM status verified before rollback",
            target=str(vmid),
            node=node,
            status=status,
            qmpstatus=qmpstatus,
        )

    def assert_proxmox_storage_headroom(
        self,
        proxmox: ProxmoxClient,
        locations: dict[int, str],
        vm_count: int,
        result: ResultBuilder,
    ) -> None:
        storage = self._settings.proxmox_storage
        for node in sorted(set(locations.values())):
            data = proxmox._request(
                "GET",
                f"/nodes/{node}/storage/{storage}/status",
                step="automation.storage",
            )
            if not isinstance(data, dict):
                raise WorkflowError(
                    "automation.storage",
                    "Invalid Proxmox response while checking storage",
                    details={"node": node, "storage": storage},
                )
            total = int(data.get("total") or 0)
            used = int(data.get("used") or 0)
            available = int(data.get("avail") or 0)
            minimum_free = max(
                self._settings.proxmox_storage_min_free_gib * GIB,
                self._settings.proxmox_storage_min_free_per_vm_gib * GIB * vm_count,
            )
            used_percent = (used / total * 100.0) if total else 100.0
            if available < minimum_free:
                raise WorkflowError(
                    "automation.storage_headroom",
                    f"Automation refused: insufficient {storage} headroom to avoid io-error",
                    details={
                        "node": node,
                        "storage": storage,
                        "available_gib": round(available / GIB, 2),
                        "required_gib": round(minimum_free / GIB, 2),
                        "used_percent": round(used_percent, 2),
                    },
                )
            result.ok(
                "automation.storage_headroom",
                f"{storage} headroom verified before rollback",
                target=node,
                storage=storage,
                available_gib=round(available / GIB, 2),
                required_gib=round(minimum_free / GIB, 2),
                used_percent=round(used_percent, 2),
            )
