"""Proxmox preflight and snapshot restoration for UI automation."""

from __future__ import annotations

from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed

from app.clients.proxmox import ProxmoxClient
from app.errors import WorkflowError
from app.services.automation_types import WizardProfile
from app.services.common import ResultBuilder
from app.services.reset import RESET_SNAPSHOT

GIB = 1024**3
LOCAL_LVM_MIN_FREE_BYTES = 20 * GIB
LOCAL_LVM_MIN_FREE_PER_VM_BYTES = 20 * GIB


class AutomationPreflight:
    """Validate all selected VMs before restoring any clean snapshot.

    The factory opens a fresh Proxmox client per concurrent rollback. This
    avoids sharing an HTTP session between worker threads while preserving the
    all-VM preflight barrier used by the original implementation.
    """

    def __init__(self, proxmox_factory: Callable[[], ProxmoxClient]) -> None:
        self._proxmox_factory = proxmox_factory

    def restore_clean_snapshot(self, result: ResultBuilder, profile: WizardProfile) -> None:
        vmid = profile.vmid
        with self._proxmox_factory() as proxmox:
            node = proxmox.locate_vm(vmid)
            proxmox.assert_snapshot(node, vmid, RESET_SNAPSHOT)
            result.ok(
                "automation.rollback_preflight",
                "VM et snapshot vérifiés avant automation",
                target=str(vmid),
                node=node,
                snapshot=RESET_SNAPSHOT,
            )
            proxmox.rollback(node, vmid, RESET_SNAPSHOT)
            result.ok(
                "automation.reset_vm_done",
                f"Reset VM{vmid} terminé: snapshot clean2 restauré et tâche Proxmox validée",
                target=str(vmid),
                node=node,
                snapshot=RESET_SNAPSHOT,
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
                proxmox.assert_snapshot(node, profile.vmid, RESET_SNAPSHOT)
                self.assert_vm_not_in_io_error(proxmox, node, profile.vmid, result)
                locations[profile.vmid] = node
                result.ok(
                    "automation.rollback_preflight",
                    "VM et snapshot vérifiés avant automation",
                    target=str(profile.vmid),
                    node=node,
                    snapshot=RESET_SNAPSHOT,
                )
            self.assert_proxmox_storage_headroom(proxmox, locations, len(profiles), result)

        def restore(profile: WizardProfile) -> tuple[int, str]:
            node = locations[profile.vmid]
            with self._proxmox_factory() as proxmox:
                proxmox.rollback(node, profile.vmid, RESET_SNAPSHOT)
            return profile.vmid, node

        with ThreadPoolExecutor(max_workers=len(profiles)) as executor:
            futures = {executor.submit(restore, profile): profile for profile in profiles}
            for future in as_completed(futures):
                vmid, node = future.result()
                result.ok(
                    "automation.reset_vm_done",
                    f"Reset VM{vmid} terminé: snapshot clean2 restauré et tâche Proxmox validée",
                    target=str(vmid),
                    node=node,
                    snapshot=RESET_SNAPSHOT,
                )

    @staticmethod
    def assert_vm_not_in_io_error(
        proxmox: ProxmoxClient,
        node: str,
        vmid: int,
        result: ResultBuilder,
    ) -> None:
        data = proxmox._request(
            "GET",
            f"/nodes/{node}/qemu/{vmid}/status/current",
            step="automation.vm_status",
        )
        if not isinstance(data, dict):
            raise WorkflowError(
                "automation.vm_status",
                "Réponse Proxmox invalide pendant la vérification d'état VM",
                details={"vmid": vmid, "node": node},
            )
        qmpstatus = str(data.get("qmpstatus") or "")
        status = str(data.get("status") or "")
        if qmpstatus == "io-error":
            raise WorkflowError(
                "automation.vm_io_error",
                "Automation refusée: la VM est en io-error Proxmox avant rollback",
                details={"vmid": vmid, "node": node, "status": status, "qmpstatus": qmpstatus},
            )
        result.ok(
            "automation.vm_status",
            "État VM Proxmox vérifié avant rollback",
            target=str(vmid),
            node=node,
            status=status,
            qmpstatus=qmpstatus,
        )

    @staticmethod
    def assert_proxmox_storage_headroom(
        proxmox: ProxmoxClient,
        locations: dict[int, str],
        vm_count: int,
        result: ResultBuilder,
    ) -> None:
        for node in sorted(set(locations.values())):
            data = proxmox._request(
                "GET",
                f"/nodes/{node}/storage/local-lvm/status",
                step="automation.storage",
            )
            if not isinstance(data, dict):
                raise WorkflowError(
                    "automation.storage",
                    "Réponse Proxmox invalide pendant la vérification stockage",
                    details={"node": node, "storage": "local-lvm"},
                )
            total = int(data.get("total") or 0)
            used = int(data.get("used") or 0)
            available = int(data.get("avail") or 0)
            minimum_free = max(
                LOCAL_LVM_MIN_FREE_BYTES,
                LOCAL_LVM_MIN_FREE_PER_VM_BYTES * vm_count,
            )
            used_percent = (used / total * 100.0) if total else 100.0
            if available < minimum_free:
                raise WorkflowError(
                    "automation.storage_headroom",
                    "Automation refusée: marge local-lvm insuffisante pour éviter un io-error",
                    details={
                        "node": node,
                        "storage": "local-lvm",
                        "available_gib": round(available / GIB, 2),
                        "required_gib": round(minimum_free / GIB, 2),
                        "used_percent": round(used_percent, 2),
                    },
                )
            result.ok(
                "automation.storage_headroom",
                "Marge local-lvm vérifiée avant rollback",
                target=node,
                storage="local-lvm",
                available_gib=round(available / GIB, 2),
                required_gib=round(minimum_free / GIB, 2),
                used_percent=round(used_percent, 2),
            )
