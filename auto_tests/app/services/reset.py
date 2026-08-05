from __future__ import annotations

import logging
import shlex
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed

from app.clients.proxmox import ProxmoxClient
from app.clients.ssh import SSHClient
from app.config import Settings
from app.errors import WorkflowError
from app.models import OperationResult, StepResult
from app.services.common import ResultBuilder

logger = logging.getLogger(__name__)

RESET_SNAPSHOT = "clean2"


class ResetService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    def run(
        self,
        selectors: Sequence[str] | None = None,
        on_step: Callable[[StepResult], None] | None = None,
    ) -> OperationResult:
        result = ResultBuilder("reset", on_step=on_step)
        try:
            reset_vm_ids = tuple(vm.vmid for vm in self.settings.vms)
            vmids = self._selected_vmids(selectors)
            locations = self._preflight_proxmox(result, vmids)
            if selectors is None:
                self._empty_smb(result)
            else:
                result.ok(
                    "reset.scope",
                    "Selective reset requested: /root/smb is preserved",
                    targets=[str(vmid) for vmid in vmids],
                )
            self._restore_snapshots(locations, vmids, result)
            if selectors is None:
                return result.success(
                    "Reset completed for /root/smb and VMs "
                    + ", ".join(str(vmid) for vmid in reset_vm_ids)
                )
            return result.success("Reset completed for " + ", ".join(str(vmid) for vmid in vmids))
        except WorkflowError as exc:
            return result.failure(exc)
        except Exception as exc:
            logger.exception("Unexpected internal error during reset")
            return result.failure(
                WorkflowError(
                    "internal", "Unexpected internal error", details={"type": type(exc).__name__}
                )
            )

    def _proxmox(self) -> ProxmoxClient:
        s = self.settings
        return ProxmoxClient(
            s.proxmox_url,
            s.proxmox_token_id,
            s.proxmox_token_secret.get_secret_value(),
            timeout=s.proxmox_timeout_seconds,
            task_timeout=s.proxmox_task_timeout_seconds,
            verify_tls=s.proxmox_verify_tls,
            ca_bundle=s.proxmox_ca_bundle,
        )

    def _selected_vmids(self, selectors: Sequence[str] | None) -> tuple[int, ...]:
        if selectors is None:
            return tuple(vm.vmid for vm in self.settings.vms)
        if not selectors:
            raise WorkflowError("reset.selector", "No VM requested")

        aliases: dict[str, int] = {
            "500": 500,
            "vm500": 500,
            "win10-bios": 500,
            "windows10-bios": 500,
            "501": 501,
            "vm501": 501,
            "win10-uefi": 501,
            "windows10-uefi": 501,
            "502": 502,
            "vm502": 502,
            "win11": 502,
            "win11-uefi": 502,
            "windows11-uefi": 502,
        }
        for vm in self.settings.vms:
            aliases[vm.name.strip().lower()] = vm.vmid
        selected: list[int] = []
        for selector in selectors:
            key = selector.strip().lower()
            vmid = aliases.get(key)
            if vmid is None:
                raise WorkflowError(
                    "reset.selector",
                    "Unknown VM requested for reset",
                    details={"selector": selector},
                )
            if vmid not in selected:
                selected.append(vmid)
        return tuple(selected)

    def _preflight_proxmox(self, result: ResultBuilder, vmids: Sequence[int]) -> dict[int, str]:
        locations: dict[int, str] = {}
        with self._proxmox() as proxmox:
            for vmid in vmids:
                node = proxmox.locate_vm(vmid)
                proxmox.assert_snapshot(node, vmid, RESET_SNAPSHOT)
                locations[vmid] = node
                result.ok(
                    "proxmox.preflight",
                    "VM and snapshot verified",
                    target=str(vmid),
                    node=node,
                    snapshot=RESET_SNAPSHOT,
                )
        if set(locations) != set(vmids):
            raise WorkflowError("proxmox.guard", "Reset scope guard failed")
        return locations

    def _empty_smb(self, result: ResultBuilder) -> None:
        s = self.settings
        if s.smb_root not in s.allowed_smb_roots:
            raise WorkflowError(
                "reset.guard", "SMB cleanup refused outside the configured allowlist"
            )
        with SSHClient(
            s.main_ssh_host,
            s.main_ssh_user,
            s.main_ssh_password.get_secret_value(),
            known_hosts_path=s.ssh_known_hosts,
            port=s.ssh_port,
            connect_timeout=s.ssh_timeout_seconds,
        ) as ssh:
            root = shlex.quote(s.smb_root)
            ssh.run(
                f"test -d {root} && test ! -L {root} && find {root} -mindepth 1 -delete",
                step="reset.empty_smb",
                timeout=s.command_timeout_seconds,
            )
            verification = ssh.run(
                f"find {root} -mindepth 1 -maxdepth 1 -print -quit",
                step="reset.verify_smb_empty",
                timeout=s.command_timeout_seconds,
            )
            if verification.stdout:
                raise WorkflowError(
                    "reset.verify_smb_empty",
                    "The /root/smb directory is not empty after deletion",
                )
        result.ok(
            "reset.empty_smb",
            "/root/smb contents deleted and empty state verified",
            target=s.main_ssh_host,
        )

    def _restore_snapshots(
        self, locations: dict[int, str], vmids: Sequence[int], result: ResultBuilder
    ) -> None:
        for vmid in vmids:
            if vmid not in locations:
                raise WorkflowError(
                    "proxmox.guard",
                    "VM is outside the guard or its location is missing",
                    details={"vmid": vmid},
                )

        def restore_one(vmid: int) -> tuple[int, str]:
            node = locations[vmid]
            with self._proxmox() as proxmox:
                proxmox.rollback(node, vmid, RESET_SNAPSHOT)
            return vmid, node

        with ThreadPoolExecutor(max_workers=len(vmids)) as executor:
            futures = {executor.submit(restore_one, vmid): vmid for vmid in vmids}
            for future in as_completed(futures):
                vmid, node = future.result()
                result.ok(
                    "proxmox.rollback",
                    "Snapshot restored successfully",
                    target=str(vmid),
                    node=node,
                    snapshot=RESET_SNAPSHOT,
                )
