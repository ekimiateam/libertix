from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import PureWindowsPath
from typing import Literal

from app.distributions import DistributionProfile, load_distribution_profile
from app.models import AutomationRequest, BootGuardianFault
from app.storage_fixtures import StorageFixtureRequest


@dataclass(frozen=True)
class AutomationOptions:
    linux_username: str
    linux_password: str
    monitor_iso: bool
    linux_size_gib: int = 100
    installation_target: Literal["windows", "secondary"] = "windows"
    expected_compatibility_refusal: Literal["COMPAT_E_MBR_PRIMARY_LIMIT"] | None = None
    distribution: DistributionProfile = field(
        default_factory=lambda: load_distribution_profile("mint")
    )
    share_windows_files_in_linux: bool = True
    share_linux_files_in_windows: bool = True
    migrate_windows_preferences: bool = False
    preference_wallpaper: Literal["custom", "windows-default"] = "custom"
    use_default_filepool: bool = False
    local_filepool: bool = False
    simulate_stale_firmware_entries: bool = False
    force_offline_ntfs_resize: bool = False
    boot_guardian_fault: BootGuardianFault = "none"
    rollback_baseline: dict[str, str] | None = None
    preference_fixture: dict[str, str] | None = None
    first_boot: Literal["windows", "linux"] = "windows"
    storage_fixture: StorageFixtureRequest = field(default_factory=StorageFixtureRequest)
    secondary_snapshot: bool = False
    storage_fixture_receipt: dict[str, object] | None = None
    verify_uninstall: bool = False
    deployed_executable: PureWindowsPath | None = None
    release_sha256: str | None = None

    @classmethod
    def from_request(
        cls, request: AutomationRequest, *, release_sha256: str | None = None
    ) -> AutomationOptions:
        return cls(
            linux_username=request.linux_username,
            linux_password=request.linux_password,
            monitor_iso=request.monitor_iso,
            linux_size_gib=request.linux_size_gib,
            installation_target=request.installation_target,
            expected_compatibility_refusal=request.expected_compatibility_refusal,
            distribution=load_distribution_profile(request.distribution),
            share_windows_files_in_linux=request.share_windows_files_in_linux,
            share_linux_files_in_windows=request.share_linux_files_in_windows,
            migrate_windows_preferences=request.migrate_windows_preferences,
            preference_wallpaper=request.preference_wallpaper,
            use_default_filepool=request.source == "published" or request.local_filepool,
            local_filepool=request.local_filepool,
            simulate_stale_firmware_entries=request.simulate_stale_firmware_entries,
            force_offline_ntfs_resize=request.force_offline_ntfs_resize,
            boot_guardian_fault=request.boot_guardian_fault,
            first_boot=request.first_boot,
            storage_fixture=request.storage_fixture,
            secondary_snapshot=request.snapshot_mode == "secondary-disk",
            verify_uninstall=request.verify_uninstall,
            release_sha256=release_sha256,
        )


@dataclass(frozen=True)
class WizardProfile:
    name: str
    vm_name: str
    vm_host: str
    vmid: int
