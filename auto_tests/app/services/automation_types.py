from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class AutomationOptions:
    apply: bool
    linux_username: str
    linux_password: str
    monitor_iso: bool
    share_windows_files_in_linux: bool = True
    share_linux_files_in_windows: bool = True


@dataclass(frozen=True)
class Point:
    x: int
    y: int


@dataclass(frozen=True)
class WizardLayout:
    welcome_next: Point
    distribution: Point
    next_button: Point
    sharing_next: Point
    windows_to_linux_checkbox: Point
    linux_to_windows_checkbox: Point
    username: Point
    password: Point
    password_confirmation: Point
    warning_acknowledgement: Point


@dataclass(frozen=True)
class WizardProfile:
    name: str
    vm_name: str
    vm_host: str
    vmid: int
    launch_only_label: str
