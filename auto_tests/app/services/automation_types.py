from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class AutomationOptions:
    apply: bool
    linux_username: str
    linux_password: str
    monitor_iso: bool


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
    disable_defender_for_automation: bool = False
