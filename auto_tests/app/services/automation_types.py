from __future__ import annotations

from dataclasses import dataclass, field

from app.distributions import DistributionProfile, load_distribution_profile


@dataclass(frozen=True)
class AutomationOptions:
    apply: bool
    linux_username: str
    linux_password: str
    monitor_iso: bool
    distribution: DistributionProfile = field(
        default_factory=lambda: load_distribution_profile("mint")
    )
    share_windows_files_in_linux: bool = True
    share_linux_files_in_windows: bool = True


@dataclass(frozen=True)
class Point:
    x: int
    y: int


@dataclass(frozen=True)
class WizardProfile:
    name: str
    vm_name: str
    vm_host: str
    vmid: int
    launch_only_label: str
