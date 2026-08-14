"""Proxmox preflight and snapshot restoration for UI automation."""

from __future__ import annotations

import ipaddress
import time
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed

from app.clients.proxmox import ProxmoxClient
from app.config import Settings
from app.errors import WorkflowError
from app.services.automation_types import WizardProfile
from app.services.common import ResultBuilder

GIB = 1024**3
WINDOWS_GUEST_AGENT_READY_TIMEOUT_SECONDS = 180.0
WINDOWS_GUEST_AGENT_COMMAND_TIMEOUT_SECONDS = 30.0


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
            network = self.configure_windows_guest_network(proxmox, node, profile)
            result.ok(
                "automation.reset_vm_done",
                f"VM{vmid} reset completed: configured snapshot restored and Proxmox task verified",
                target=str(vmid),
                node=node,
                snapshot=self._settings.reset_snapshot,
                **verified,
            )
            result.ok(
                "automation.guest_network_ready",
                "Windows test VM static network verified through the QEMU guest agent",
                target=profile.vm_host,
                vm=profile.vm_name,
                vmid=vmid,
                **network,
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

        def restore(
            profile: WizardProfile,
        ) -> tuple[int, str, dict[str, object], dict[str, object]]:
            node = locations[profile.vmid]
            with self._proxmox_factory() as proxmox:
                proxmox.rollback(node, profile.vmid, self._settings.reset_snapshot)
                verified = proxmox.verify_rollback_state(
                    node,
                    profile.vmid,
                    self._settings.reset_snapshot,
                    require_running=True,
                )
                network = self.configure_windows_guest_network(proxmox, node, profile)
            return profile.vmid, node, verified, network

        with ThreadPoolExecutor(max_workers=len(profiles)) as executor:
            futures = {executor.submit(restore, profile): profile for profile in profiles}
            for future in as_completed(futures):
                profile = futures[future]
                vmid, node, verified, network = future.result()
                result.ok(
                    "automation.reset_vm_done",
                    f"VM{vmid} reset completed: configured snapshot restored "
                    "and Proxmox task verified",
                    target=str(vmid),
                    node=node,
                    snapshot=self._settings.reset_snapshot,
                    **verified,
                )
                result.ok(
                    "automation.guest_network_ready",
                    "Windows test VM static network verified through the QEMU guest agent",
                    target=profile.vm_host,
                    vm=profile.vm_name,
                    vmid=vmid,
                    **network,
                )

    def configure_windows_guest_network(
        self,
        proxmox: ProxmoxClient,
        node: str,
        profile: WizardProfile,
    ) -> dict[str, object]:
        deadline = time.monotonic() + WINDOWS_GUEST_AGENT_READY_TIMEOUT_SECONDS
        last_error: WorkflowError | None = None
        interfaces: list[dict[str, object]] = []
        while time.monotonic() < deadline:
            try:
                interfaces = proxmox.get_guest_network_interfaces(
                    node,
                    profile.vmid,
                    step="automation.guest_network_discovery",
                )
                break
            except WorkflowError as exc:
                last_error = exc
                time.sleep(2)
        else:
            raise WorkflowError(
                "automation.guest_network_discovery",
                "QEMU guest agent did not expose Windows networking after snapshot restore",
                details={
                    "vm": profile.vm_name,
                    "vmid": profile.vmid,
                    "node": node,
                    "last_error": str(last_error) if last_error else "",
                },
            ) from last_error

        candidates = [
            item
            for item in interfaces
            if str(item.get("name") or "").strip()
            and str(item.get("name") or "").casefold() != "loopback pseudo-interface 1"
            and str(item.get("hardware-address") or "").strip()
        ]
        if len(candidates) != 1:
            raise WorkflowError(
                "automation.guest_network_discovery",
                "Windows test VM must expose exactly one configurable network interface",
                details={
                    "vm": profile.vm_name,
                    "vmid": profile.vmid,
                    "node": node,
                    "candidate_count": len(candidates),
                    "candidate_names": [str(item.get("name") or "") for item in candidates],
                },
            )

        interface_name = str(candidates[0]["name"])
        prefix_length = self._settings.development_static_ipv4_prefix_length
        netmask = str(ipaddress.IPv4Network(f"0.0.0.0/{prefix_length}").netmask)
        gateway = self._settings.development_static_ipv4_gateway
        dns_servers = self._settings.development_dns_servers
        commands = [
            [
                "netsh.exe",
                "interface",
                "ipv4",
                "set",
                "address",
                f"name={interface_name}",
                "source=static",
                f"address={profile.vm_host}",
                f"mask={netmask}",
                f"gateway={gateway}",
                "gwmetric=1",
            ],
            [
                "netsh.exe",
                "interface",
                "ipv4",
                "set",
                "dnsservers",
                f"name={interface_name}",
                "source=static",
                f"address={dns_servers[0]}",
                "register=primary",
                "validate=no",
            ],
            *[
                [
                    "netsh.exe",
                    "interface",
                    "ipv4",
                    "add",
                    "dnsservers",
                    f"name={interface_name}",
                    f"address={dns_server}",
                    f"index={index}",
                    "validate=no",
                ]
                for index, dns_server in enumerate(dns_servers[1:], start=2)
            ],
        ]
        for command in commands:
            execution = proxmox.execute_guest_agent_command(
                node,
                profile.vmid,
                command,
                step="automation.guest_network_configure",
                timeout=WINDOWS_GUEST_AGENT_COMMAND_TIMEOUT_SECONDS,
            )
            if execution.get("exitcode") != 0:
                raise WorkflowError(
                    "automation.guest_network_configure",
                    "Windows rejected the configured static test network",
                    details={
                        "vm": profile.vm_name,
                        "vmid": profile.vmid,
                        "node": node,
                        "program": command[0],
                        "exitcode": execution.get("exitcode"),
                        "stdout": str(execution.get("out-data") or "")[-2000:],
                        "stderr": str(execution.get("err-data") or "")[-2000:],
                    },
                )

        while time.monotonic() < deadline:
            interfaces = proxmox.get_guest_network_interfaces(
                node,
                profile.vmid,
                step="automation.guest_network_verify",
            )
            selected = next(
                (item for item in interfaces if str(item.get("name") or "") == interface_name),
                None,
            )
            addresses = (
                [
                    str(address.get("ip-address") or "")
                    for address in selected.get("ip-addresses", [])
                    if isinstance(address, dict) and address.get("ip-address-type") == "ipv4"
                ]
                if isinstance(selected, dict)
                else []
            )
            if profile.vm_host in addresses:
                return {
                    "interface": interface_name,
                    "ipv4": profile.vm_host,
                    "prefix_length": prefix_length,
                    "gateway": gateway,
                    "dns_server_count": len(dns_servers),
                }
            time.sleep(1)

        raise WorkflowError(
            "automation.guest_network_verify",
            "QEMU guest agent did not confirm the configured Windows test address",
            details={
                "vm": profile.vm_name,
                "vmid": profile.vmid,
                "node": node,
                "expected_ipv4": profile.vm_host,
            },
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
