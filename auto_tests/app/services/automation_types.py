from __future__ import annotations

from dataclasses import dataclass, field
from typing import Literal

from app.distributions import DistributionProfile, load_distribution_profile


@dataclass(frozen=True)
class AutomationOptions:
    linux_username: str
    linux_password: str
    monitor_iso: bool
    linux_size_gib: int = 100
    distribution: DistributionProfile = field(
        default_factory=lambda: load_distribution_profile("mint")
    )
    share_windows_files_in_linux: bool = True
    share_linux_files_in_windows: bool = True
    migrate_windows_preferences: bool = False
    use_default_filepool: bool = False
    simulate_stale_firmware_entries: bool = False
    force_offline_ntfs_resize: bool = False
    boot_guardian_fault: Literal[
        "none",
        "bios-rollback",
        "boot-order",
        "bootnext-fallback",
        "bootnext-rollback",
        "preferred-path",
        "preferred-path-rollback",
    ] = "none"
    rollback_baseline: dict[str, str] | None = None
    preference_fixture: dict[str, str] | None = None
    first_boot: Literal["windows", "linux"] = "windows"


@dataclass(frozen=True)
class WizardProfile:
    name: str
    vm_name: str
    vm_host: str
    vmid: int
