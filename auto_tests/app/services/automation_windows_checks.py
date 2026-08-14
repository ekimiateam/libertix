"""Build the declarative Windows validation plan used after installation."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any

from app.config import VMConfig
from app.services.automation_types import AutomationOptions


@dataclass(frozen=True)
class CrossOsArtifacts:
    windows_relative_path: str
    windows_sha256: str
    linux_relative_path: str
    linux_sha256: str


@dataclass(frozen=True)
class WindowsValidationPlan:
    check_names: tuple[str, ...]
    base_config: dict[str, Any]


def windows_validation_timeout_seconds(check_name: str) -> int:
    if check_name in {"sfc_verify_only", "chkdsk_scan"}:
        return 1800
    if check_name == "finalization":
        # The guest-side check owns a five-minute deadline. Transport must
        # leave enough time for that diagnostic and script cleanup to return.
        return 420
    return 300


def build_windows_validation_plan(
    vm: VMConfig,
    options: AutomationOptions,
    artifacts: CrossOsArtifacts,
) -> WindowsValidationPlan:
    check_names = [
        "finalization",
        "identity",
        "firmware",
        "system_volume",
        "system_resources",
        "partition_layout",
        "partition_geometry",
        "boot_partition",
        "boot_configuration",
        "recovery",
        "bitlocker",
        "temporary_artifacts",
        "network",
        "locale",
        "ssh_service",
        "core_services",
        "hibernation",
        "dism_check_health",
        "sfc_verify_only",
        "chkdsk_scan",
    ]
    expensive_checks_index = check_names.index("dism_check_health")
    if options.share_linux_files_in_windows:
        check_names[expensive_checks_index:expensive_checks_index] = [
            "ext4_driver",
            "ext4_readonly_mount",
            "linux_home",
            "linux_home_hash",
            "ext4_write_denied",
            "explorer_shortcut",
            "explorer_integration",
            "sharing_tasks",
        ]
        expensive_checks_index = check_names.index("dism_check_health")
    if options.share_windows_files_in_linux:
        check_names.insert(expensive_checks_index, "cross_os_hash")
    if not (options.share_windows_files_in_linux and options.share_linux_files_in_windows):
        check_names.insert(check_names.index("dism_check_health"), "sharing_disabled")

    return WindowsValidationPlan(
        check_names=tuple(check_names),
        base_config={
            "expected_firmware": vm.firmware,
            "expected_ipv4": vm.host,
            "installer_iso_file_name": options.distribution.installer_iso_file_name,
            "linux_username": options.linux_username,
            "windows_relative_path": artifacts.windows_relative_path,
            "windows_sha256": artifacts.windows_sha256,
            "linux_relative_path": artifacts.linux_relative_path,
            "linux_sha256": artifacts.linux_sha256,
            "share_windows_files_in_linux": options.share_windows_files_in_linux,
            "share_linux_files_in_windows": options.share_linux_files_in_windows,
        },
    )
