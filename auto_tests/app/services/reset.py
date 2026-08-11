from __future__ import annotations

import logging
import shlex
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed

from app.clients.proxmox import ProxmoxClient
from app.clients.ssh import SSHClient
from app.config import Settings, VMConfig
from app.errors import WorkflowError
from app.models import OperationResult, StepResult
from app.services.common import ResultBuilder
from app.services.validation import ValidationService

logger = logging.getLogger(__name__)


class ResetService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.validation = ValidationService(settings)

    def run(
        self,
        selectors: Sequence[str] | None = None,
        on_step: Callable[[StepResult], None] | None = None,
    ) -> OperationResult:
        result = ResultBuilder("reset", on_step=on_step)
        try:
            selected_vms = self._selected_vms(selectors)
            vmids = tuple(vm.vmid for vm in selected_vms)
            locations = self._preflight_proxmox(result, vmids)
            if selectors is None:
                self._empty_smb(result)
            else:
                result.ok(
                    "reset.scope",
                    f"Selective reset requested: {self.settings.smb_root} is preserved",
                    targets=[str(vmid) for vmid in vmids],
                )
            self._restore_snapshots(locations, vmids, result)
            if selectors is None:
                return result.success(
                    f"Reset completed for {self.settings.smb_root} and VMs "
                    + ", ".join(str(vmid) for vmid in vmids)
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
        return tuple(vm.vmid for vm in self._selected_vms(selectors))

    def _selected_vms(self, selectors: Sequence[str] | None) -> tuple[VMConfig, ...]:
        if selectors is not None and not selectors:
            raise WorkflowError("reset.selector", "No VM requested")
        return self.validation.select_vms(selectors)

    def _preflight_proxmox(
        self,
        result: ResultBuilder,
        vmids: Sequence[int],
    ) -> dict[int, str]:
        locations: dict[int, str] = {}
        with self._proxmox() as proxmox:
            for vmid in vmids:
                node = proxmox.locate_vm(vmid)
                proxmox.assert_snapshot(node, vmid, self.settings.reset_snapshot)
                locations[vmid] = node
                result.ok(
                    "proxmox.preflight",
                    "VM and snapshot verified",
                    target=str(vmid),
                    node=node,
                    snapshot=self.settings.reset_snapshot,
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
            remote_os="linux",
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
                    f"The {s.smb_root} directory is not empty after deletion",
                )
        result.ok(
            "reset.empty_smb",
            f"{s.smb_root} contents deleted and empty state verified",
            target=s.main_ssh_host,
        )

    def _restore_snapshots(
        self,
        locations: dict[int, str],
        vmids: Sequence[int],
        result: ResultBuilder,
    ) -> None:
        for vmid in vmids:
            if vmid not in locations:
                raise WorkflowError(
                    "proxmox.guard",
                    "VM is outside the guard or its location is missing",
                    details={"vmid": vmid},
                )

        def restore_one(vmid: int) -> tuple[int, str, dict[str, object]]:
            node = locations[vmid]
            with self._proxmox() as proxmox:
                proxmox.rollback(node, vmid, self.settings.reset_snapshot)
                verified = proxmox.verify_rollback_state(
                    node,
                    vmid,
                    self.settings.reset_snapshot,
                    require_running=False,
                )
            return vmid, node, verified

        with ThreadPoolExecutor(max_workers=len(vmids)) as executor:
            futures = {executor.submit(restore_one, vmid): vmid for vmid in vmids}
            for future in as_completed(futures):
                vmid, node, verified = future.result()
                result.ok(
                    "proxmox.rollback",
                    "Snapshot restored successfully",
                    target=str(vmid),
                    node=node,
                    snapshot=self.settings.reset_snapshot,
                    **verified,
                )
