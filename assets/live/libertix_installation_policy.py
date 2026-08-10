#!/usr/bin/env python3
"""Load and validate the shared Libertix installation policy."""

from __future__ import annotations

import json
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


@dataclass(frozen=True)
class MemoryPolicy:
    windows_minimum_mib: int
    low_memory_threshold_mib: int
    live_minimum_mib: int


@dataclass(frozen=True)
class InstallationPolicy:
    storage: StoragePolicy
    memory: MemoryPolicy


def _require_integer(mapping: dict[str, Any], name: str) -> int:
    value = mapping.get(name)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError(f"installation policy {name} must be an integer")
    return value


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
    if not isinstance(storage_raw, dict) or not isinstance(memory_raw, dict):
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
    )
    memory = MemoryPolicy(
        windows_minimum_mib=_require_integer(memory_raw, "windowsMinimumMiB"),
        low_memory_threshold_mib=_require_integer(memory_raw, "lowMemoryThresholdMiB"),
        live_minimum_mib=_require_integer(memory_raw, "liveMinimumMiB"),
    )
    if (
        storage.minimum_final_size_gib <= 0
        or storage.target_windows_free_space_gib <= 0
        or storage.windows_free_space_tolerance_gib < 0
        or storage.windows_free_space_tolerance_gib >= storage.target_windows_free_space_gib
        or storage.windows_free_space_retry_window_gib < 0
        or storage.preflight_shrink_safety_gib < 0
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
    return InstallationPolicy(storage=storage, memory=memory)
