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

RESET_VM_IDS = (500, 501, 502)
RESET_SNAPSHOT = "clean2"
CONFIGURED_VM_IDS = (500, 501, 502)


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
            vmids = self._selected_vmids(selectors)
            locations = self._preflight_proxmox(result, vmids)
            if selectors is None:
                self._empty_smb(result)
            else:
                result.ok(
                    "reset.scope",
                    "Reset sélectif demandé: /root/smb est conservé",
                    targets=[str(vmid) for vmid in vmids],
                )
            self._restore_snapshots(locations, vmids, result)
            if selectors is None:
                return result.success("Reset terminé pour /root/smb et les VM 500, 501, 502")
            return result.success(
                "Reset terminé pour " + ", ".join(str(vmid) for vmid in vmids)
            )
        except WorkflowError as exc:
            return result.failure(exc)
        except Exception as exc:
            logger.exception("Erreur interne inattendue pendant le reset")
            return result.failure(
                WorkflowError(
                    "internal", "Erreur interne inattendue", details={"type": type(exc).__name__}
                )
            )

    def _proxmox(self) -> ProxmoxClient:
        s = self.settings
        return ProxmoxClient(
            s.proxmox_url,
            s.proxmox_token_id,
            s.proxmox_token_secret.get_secret_value(),
            verify_tls=s.proxmox_verify_tls,
            timeout=s.proxmox_timeout_seconds,
            task_timeout=s.proxmox_task_timeout_seconds,
        )

    def _selected_vmids(self, selectors: Sequence[str] | None) -> tuple[int, ...]:
        if selectors is None:
            return RESET_VM_IDS
        if not selectors:
            raise WorkflowError("reset.selector", "Aucune VM demandée")

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
        for vm, vmid in zip(self.settings.vms, CONFIGURED_VM_IDS, strict=True):
            aliases[vm.name.strip().lower()] = vmid
        selected: list[int] = []
        for selector in selectors:
            key = selector.strip().lower()
            vmid = aliases.get(key)
            if vmid is None:
                raise WorkflowError(
                    "reset.selector",
                    "VM inconnue pour le reset",
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
                    "VM et snapshot vérifiés",
                    target=str(vmid),
                    node=node,
                    snapshot=RESET_SNAPSHOT,
                )
        if set(locations) != set(vmids):
            raise WorkflowError("proxmox.guard", "La garde de périmètre du reset a échoué")
        return locations

    def _empty_smb(self, result: ResultBuilder) -> None:
        s = self.settings
        if s.smb_root != "/root/smb":
            raise WorkflowError("reset.guard", "Suppression refusée hors de /root/smb")
        with SSHClient(
            s.main_ssh_host,
            s.main_ssh_user,
            s.main_ssh_password.get_secret_value(),
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
                    "Le dossier /root/smb n'est pas vide après suppression",
                )
        result.ok(
            "reset.empty_smb",
            "Contenu de /root/smb supprimé et état vide vérifié",
            target=s.main_ssh_host,
        )

    def _restore_snapshots(
        self, locations: dict[int, str], vmids: Sequence[int], result: ResultBuilder
    ) -> None:
        for vmid in vmids:
            if vmid not in locations:
                raise WorkflowError(
                    "proxmox.guard",
                    "VM hors garde ou localisation absente",
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
                    "Snapshot restauré avec succès",
                    target=str(vmid),
                    node=node,
                    snapshot=RESET_SNAPSHOT,
                )
