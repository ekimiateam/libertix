#!/usr/bin/env python3
"""Load and validate the shared Libertix installation policy."""

from __future__ import annotations

import argparse
import json
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any


@dataclass(frozen=True)
class StoragePolicy:
    minimum_final_size_gib: int
    target_windows_free_space_gib: int
    windows_free_space_tolerance_gib: int
    windows_free_space_retry_window_gib: int
    preflight_shrink_safety_gib: int
    maximum_direct_fat32_size_gib: int
    large_installation_staging_size_gib: int
    partition_alignment_bytes: int
    recommended_linux_fraction_of_free_space: float
    maximum_recommended_linux_size_gib: int


@dataclass(frozen=True)
class MemoryPolicy:
    windows_minimum_mib: int
    low_memory_threshold_mib: int
    live_minimum_mib: int


@dataclass(frozen=True)
class AccountPolicy:
    reserved_usernames_source: str
    reserved_usernames: frozenset[str]


@dataclass(frozen=True)
class VolumeLabelPolicy:
    installation_media: str
    staging: str
    legacy_staging_for_recovery: tuple[str, ...]


@dataclass(frozen=True)
class InstallationPolicy:
    storage: StoragePolicy
    memory: MemoryPolicy
    volume_labels: VolumeLabelPolicy
    account: AccountPolicy


def _require_integer(mapping: dict[str, Any], name: str) -> int:
    value = mapping.get(name)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"installation policy {name} must be an integer")
    return value


def _require_number(mapping: dict[str, Any], name: str) -> float:
    value = mapping.get(name)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"installation policy {name} must be a number")
    return float(value)


def load_installation_policy(path: Path | None = None) -> InstallationPolicy:
    if path is None:
        installed_path = Path(__file__).with_name("Libertix.InstallationPolicy.json")
        source_path = (
            Path(__file__).resolve().parents[2]
            / "Scripts"
            / "config"
            / ("Libertix.InstallationPolicy.json")
        )
        policy_path = installed_path if installed_path.is_file() else source_path
    else:
        policy_path = path
    raw = json.loads(policy_path.read_text(encoding="utf-8-sig"))
    if not isinstance(raw, dict) or raw.get("schemaVersion") != 1:
        raise ValueError("installation policy schemaVersion is unsupported")
    storage_raw = raw.get("storage")
    memory_raw = raw.get("memory")
    account_raw = raw.get("account")
    volume_labels_raw = raw.get("volumeLabels")
    if (
        not isinstance(storage_raw, dict)
        or not isinstance(memory_raw, dict)
        or not isinstance(volume_labels_raw, dict)
        or not isinstance(account_raw, dict)
    ):
        raise ValueError("installation policy is incomplete")

    storage = StoragePolicy(
        minimum_final_size_gib=_require_integer(storage_raw, "minimumFinalSizeGiB"),
        target_windows_free_space_gib=_require_integer(storage_raw, "targetWindowsFreeSpaceGiB"),
        windows_free_space_tolerance_gib=_require_integer(
            storage_raw, "windowsFreeSpaceToleranceGiB"
        ),
        windows_free_space_retry_window_gib=_require_integer(
            storage_raw, "windowsFreeSpaceRetryWindowGiB"
        ),
        preflight_shrink_safety_gib=_require_integer(storage_raw, "preflightShrinkSafetyGiB"),
        maximum_direct_fat32_size_gib=_require_integer(storage_raw, "maximumDirectFat32SizeGiB"),
        large_installation_staging_size_gib=_require_integer(
            storage_raw, "largeInstallationStagingSizeGiB"
        ),
        partition_alignment_bytes=_require_integer(storage_raw, "partitionAlignmentBytes"),
        recommended_linux_fraction_of_free_space=_require_number(
            storage_raw, "recommendedLinuxFractionOfFreeSpace"
        ),
        maximum_recommended_linux_size_gib=_require_integer(
            storage_raw, "maximumRecommendedLinuxSizeGiB"
        ),
    )
    memory = MemoryPolicy(
        windows_minimum_mib=_require_integer(memory_raw, "windowsMinimumMiB"),
        low_memory_threshold_mib=_require_integer(memory_raw, "lowMemoryThresholdMiB"),
        live_minimum_mib=_require_integer(memory_raw, "liveMinimumMiB"),
    )
    installation_media_label = volume_labels_raw.get("installationMedia")
    staging_label = volume_labels_raw.get("staging")
    legacy_staging_labels = volume_labels_raw.get("legacyStagingForRecovery")
    all_volume_labels = [installation_media_label, staging_label]
    if isinstance(legacy_staging_labels, list):
        all_volume_labels.extend(legacy_staging_labels)
    if (
        not isinstance(installation_media_label, str)
        or not isinstance(staging_label, str)
        or not isinstance(legacy_staging_labels, list)
        or not all(isinstance(label, str) for label in all_volume_labels)
        or not all(re.fullmatch(r"[A-Z0-9]{1,11}", label) for label in all_volume_labels)
        or len(all_volume_labels) != len(set(all_volume_labels))
    ):
        raise ValueError("installation volume-label policy contains invalid values")
    volume_labels = VolumeLabelPolicy(
        installation_media=installation_media_label,
        staging=staging_label,
        legacy_staging_for_recovery=tuple(legacy_staging_labels),
    )
    reserved_source = account_raw.get("reservedUsernamesSource")
    reserved_raw = account_raw.get("reservedUsernames")
    if (
        not isinstance(reserved_source, str)
        or not reserved_source.startswith("https://")
        or not isinstance(reserved_raw, list)
        or not reserved_raw
        or not all(
            isinstance(name, str)
            and re.fullmatch(r"[A-Za-z](?:[A-Za-z0-9-]{0,30}[A-Za-z0-9])?", name)
            for name in reserved_raw
        )
    ):
        raise ValueError("installation account policy contains invalid values")
    normalized_reserved = [name.casefold() for name in reserved_raw]
    if len(normalized_reserved) != len(set(normalized_reserved)):
        raise ValueError("installation account policy contains duplicate usernames")
    account = AccountPolicy(
        reserved_usernames_source=reserved_source,
        reserved_usernames=frozenset(normalized_reserved),
    )
    if (
        storage.minimum_final_size_gib <= 0
        or storage.target_windows_free_space_gib <= 0
        or storage.windows_free_space_tolerance_gib < 0
        or storage.windows_free_space_tolerance_gib >= storage.target_windows_free_space_gib
        or storage.windows_free_space_retry_window_gib < 0
        or storage.preflight_shrink_safety_gib < 0
        or storage.recommended_linux_fraction_of_free_space <= 0
        or storage.recommended_linux_fraction_of_free_space > 1
        or storage.maximum_recommended_linux_size_gib < storage.minimum_final_size_gib
        or storage.maximum_direct_fat32_size_gib < storage.minimum_final_size_gib
        or storage.large_installation_staging_size_gib <= 0
        or storage.large_installation_staging_size_gib > storage.maximum_direct_fat32_size_gib
        or storage.partition_alignment_bytes <= 0
        or storage.partition_alignment_bytes & (storage.partition_alignment_bytes - 1) != 0
        or memory.live_minimum_mib <= 0
        or memory.windows_minimum_mib < memory.live_minimum_mib
        or memory.low_memory_threshold_mib <= memory.windows_minimum_mib
    ):
        raise ValueError("installation policy contains invalid values")
    return InstallationPolicy(
        storage=storage,
        memory=memory,
        volume_labels=volume_labels,
        account=account,
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", type=Path)
    parser.add_argument(
        "field",
        choices=("installation-media-volume-label", "staging-volume-label"),
    )
    args = parser.parse_args()
    policy = load_installation_policy(args.policy)
    if args.field == "installation-media-volume-label":
        print(policy.volume_labels.installation_media)
    else:
        print(policy.volume_labels.staging)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
