#!/usr/bin/env python3
"""Validate and expose the versioned Libertix installation plan to Bash."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import ipaddress
import json
import ntpath
import re
import sys
from pathlib import Path, PureWindowsPath
from typing import Any
from urllib.parse import urlparse

from libertix_installation_policy import load_installation_policy
from libertix_json_schema import validate_json_schema

GIB = 1024**3
INSTALLATION_POLICY = load_installation_policy()
NON_INTERACTIVE_WINDOWS_PROFILES = frozenset(
    name.casefold()
    for name in (
        "All Users",
        "Default",
        "Default User",
        "defaultuser0",
        "Public",
        "WDAGUtilityAccount",
        "WsiAccount",
    )
)
HEX_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
USERNAME_PATTERN = re.compile(r"^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$")
XKB_NAME_PATTERN = re.compile(r"^[a-z0-9_-]+$")
SAFE_IDENTIFIER_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$")
SAFE_GRUB_LABEL_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$")


class PlanValidationError(ValueError):
    """Raised when a plan cannot safely drive an installation."""


def require_safe_absolute_windows_path(value: Any, path: str) -> str:
    text = require_text(value, path)
    windows_path = PureWindowsPath(text)
    if (
        "/" in text
        or not windows_path.drive
        or not windows_path.is_absolute()
        or any(part in {"", ".", ".."} or ":" in part for part in windows_path.parts[1:])
        or ntpath.normcase(ntpath.normpath(text)) != ntpath.normcase(text.rstrip("\\"))
    ):
        raise PlanValidationError(f"{path} must be an absolute safe Windows path")
    return text


def project_windows_profiles(encoded_profiles: str) -> str:
    try:
        decoded = base64.b64decode(encoded_profiles, validate=True).decode("utf-8")
        profiles = json.loads(decoded)
    except (UnicodeDecodeError, ValueError, json.JSONDecodeError) as error:
        raise PlanValidationError("windowsProfilesJsonBase64 must be valid Base64 JSON") from error
    if not isinstance(profiles, list) or not all(isinstance(item, str) for item in profiles):
        raise PlanValidationError("windowsProfilesJsonBase64 must contain a string array")
    projected = [
        profile
        for profile in profiles
        if profile.casefold() not in NON_INTERACTIVE_WINDOWS_PROFILES
    ]
    return base64.b64encode(
        json.dumps(projected, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    ).decode("ascii")


def require_mapping(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise PlanValidationError(f"{path} must be an object")
    return value


def require_property(mapping: dict[str, Any], name: str, path: str) -> Any:
    if name not in mapping:
        raise PlanValidationError(f"installation plan is missing {path}.{name}")
    return mapping[name]


def require_text(value: Any, path: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PlanValidationError(f"{path} must be a non-empty string")
    if "\n" in value or "\r" in value or "\t" in value:
        raise PlanValidationError(f"{path} cannot contain control characters")
    return value


def require_positive_integer(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value <= 0:
        raise PlanValidationError(f"{path} must be a positive integer")
    return value


def require_nonnegative_integer(value: Any, path: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise PlanValidationError(f"{path} must be a non-negative integer")
    return value


def require_microsoft_uefi_authorities(value: Any, path: str, *, allow_empty: bool) -> list[str]:
    if not isinstance(value, list) or not all(isinstance(item, str) for item in value):
        raise PlanValidationError(f"{path} must be a string array")
    if not allow_empty and not value:
        raise PlanValidationError(f"{path} must contain at least one authority")
    if any(item not in {"2011", "2023"} for item in value):
        raise PlanValidationError(f"{path} may contain only 2011 and 2023")
    if len(value) != len(set(value)):
        raise PlanValidationError(f"{path} must not contain duplicates")
    return value


def validate_partition(value: Any, path: str, logical_sector_size: int) -> dict[str, Any]:
    partition = require_mapping(value, path)
    require_positive_integer(require_property(partition, "number", path), f"{path}.number")
    offset = require_positive_integer(
        require_property(partition, "offsetBytes", path),
        f"{path}.offsetBytes",
    )
    size = require_positive_integer(
        require_property(partition, "sizeBytes", path),
        f"{path}.sizeBytes",
    )
    if offset % logical_sector_size != 0 or size % logical_sector_size != 0:
        raise PlanValidationError(f"{path} geometry must align to disk.logicalSectorSizeBytes")
    return partition


def validate_plan(plan: Any, *, require_installer: bool = False) -> dict[str, Any]:
    try:
        validate_json_schema("installation-plan.schema.json", plan)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as error:
        raise PlanValidationError(f"installation plan schema validation failed: {error}") from error

    root = require_mapping(plan, "plan")
    if root.get("schemaVersion") != 4:
        raise PlanValidationError("unsupported installation plan schemaVersion")
    if not HEX_ID_PATTERN.fullmatch(str(root.get("planId", ""))):
        raise PlanValidationError("planId must contain 32 lowercase hexadecimal characters")
    created_at = require_text(root.get("createdAtUtc"), "createdAtUtc")
    try:
        parsed_created_at = dt.datetime.fromisoformat(created_at.replace("Z", "+00:00"))
    except ValueError as error:
        raise PlanValidationError("createdAtUtc must be an ISO-8601 date-time") from error
    if parsed_created_at.utcoffset() != dt.timedelta(0):
        raise PlanValidationError("createdAtUtc must use UTC")

    firmware = root.get("firmware")
    if firmware not in {"bios", "uefi"}:
        raise PlanValidationError("firmware must be 'bios' or 'uefi'")

    distribution = require_mapping(root.get("distribution"), "distribution")
    for name in (
        "id",
        "name",
        "osReleaseId",
        "grubDisplayName",
        "grubIcon",
        "installerIsoFileName",
        "installerIsoUrl",
        "installerIsoWindowsPath",
    ):
        require_text(require_property(distribution, name, "distribution"), f"distribution.{name}")
    for name in ("id", "osReleaseId", "grubIcon"):
        if not SAFE_IDENTIFIER_PATTERN.fullmatch(distribution[name]):
            raise PlanValidationError(f"distribution.{name} must be a safe lowercase identifier")
    if not SAFE_GRUB_LABEL_PATTERN.fullmatch(distribution["grubDisplayName"]):
        raise PlanValidationError(
            "distribution.grubDisplayName contains unsupported GRUB label characters"
        )
    require_microsoft_uefi_authorities(
        distribution.get("secureBootMicrosoftAuthorities"),
        "distribution.secureBootMicrosoftAuthorities",
        allow_empty=False,
    )
    if "/" in distribution["installerIsoFileName"] or "\\" in distribution["installerIsoFileName"]:
        raise PlanValidationError("distribution.installerIsoFileName must not contain a path")
    distribution["installerIsoWindowsPath"] = require_safe_absolute_windows_path(
        distribution["installerIsoWindowsPath"],
        "distribution.installerIsoWindowsPath",
    )
    for name in ("installerIsoSha256", "liveIsoSha256"):
        if not SHA256_PATTERN.fullmatch(str(distribution.get(name, ""))):
            raise PlanValidationError(f"distribution.{name} must be a lowercase SHA-256 hash")
    for name in ("installerIsoUrl", "liveIsoUrl"):
        parsed_url = urlparse(distribution[name])
        if parsed_url.scheme not in {"http", "https"} or not parsed_url.netloc:
            raise PlanValidationError(f"distribution.{name} must be an absolute HTTP(S) URL")

    locale = require_mapping(root.get("locale"), "locale")
    language_code = require_text(locale.get("languageCode"), "locale.languageCode")
    if language_code not in {"en", "fr", "es", "ko"}:
        raise PlanValidationError("locale.languageCode must be one of: en, fr, es, ko")
    for name in ("systemLanguage", "keyboardLayout", "keyboardModel", "timezone"):
        require_text(require_property(locale, name, "locale"), f"locale.{name}")
    for name in ("keyboardLayout", "keyboardModel"):
        if not XKB_NAME_PATTERN.fullmatch(locale[name]):
            raise PlanValidationError(f"locale.{name} is not a valid XKB name")
    if not re.fullmatch(r"[A-Za-z0-9._+-]+(?:/[A-Za-z0-9._+-]+)+", locale["timezone"]):
        raise PlanValidationError("locale.timezone is not a safe IANA timezone name")
    keyboard_variant = locale.get("keyboardVariant", "")
    if not isinstance(keyboard_variant, str) or (
        keyboard_variant and not XKB_NAME_PATTERN.fullmatch(keyboard_variant)
    ):
        raise PlanValidationError("locale.keyboardVariant is not a valid XKB variant name")

    account = require_mapping(root.get("account"), "account")
    username = str(account.get("username", ""))
    if not USERNAME_PATTERN.fullmatch(username):
        raise PlanValidationError("account.username is invalid")
    if username.casefold() in INSTALLATION_POLICY.account.reserved_usernames:
        raise PlanValidationError("account.username is reserved by the operating system")
    password_hash_windows_path = require_safe_absolute_windows_path(
        account.get("passwordHashWindowsPath"),
        "account.passwordHashWindowsPath",
    )
    computer_name = require_text(account.get("computerName"), "account.computerName")
    if not re.fullmatch(r"[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?", computer_name):
        raise PlanValidationError("account.computerName is not a valid Linux hostname")

    disk = require_mapping(root.get("disk"), "disk")
    disk_number = disk.get("number")
    if isinstance(disk_number, bool) or not isinstance(disk_number, int) or disk_number < 0:
        raise PlanValidationError("disk.number cannot be negative")
    require_text(disk.get("uniqueId"), "disk.uniqueId")
    partition_table_id = require_text(disk.get("partitionTableId"), "disk.partitionTableId")
    expected_partition_table_pattern = (
        r"mbr:[0-9a-f]{8}"
        if firmware == "bios"
        else r"gpt:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    )
    if not re.fullmatch(expected_partition_table_pattern, partition_table_id):
        raise PlanValidationError(
            "disk.partitionTableId is not canonical for the selected firmware"
        )
    disk_size = require_positive_integer(disk.get("sizeBytes"), "disk.sizeBytes")
    logical_sector_size = require_positive_integer(
        disk.get("logicalSectorSizeBytes"), "disk.logicalSectorSizeBytes"
    )
    if logical_sector_size not in (512, 4096):
        raise PlanValidationError("disk.logicalSectorSizeBytes must be either 512 or 4096")
    if disk_size % logical_sector_size != 0:
        raise PlanValidationError("disk.sizeBytes must align to disk.logicalSectorSizeBytes")
    system_drive = require_text(disk.get("systemDrive"), "disk.systemDrive")
    if not re.fullmatch(r"[A-Z]:", system_drive):
        raise PlanValidationError("disk.systemDrive must be an uppercase Windows drive")
    expected_style = "MBR" if firmware == "bios" else "GPT"
    if disk.get("partitionStyle") != expected_style:
        raise PlanValidationError(
            f"firmware {firmware!r} requires partitionStyle {expected_style!r}"
        )
    fixed_partitions = {
        name: validate_partition(disk.get(name), f"disk.{name}", logical_sector_size)
        for name in ("windows", "boot", "recovery")
    }
    fixed_extents: dict[str, tuple[int, int]] = {}
    for name, fixed_partition in fixed_partitions.items():
        partition_offset = int(fixed_partition["offsetBytes"])
        partition_size = int(fixed_partition["sizeBytes"])
        partition_end = partition_offset + partition_size
        if partition_end > disk_size:
            raise PlanValidationError(f"disk.{name} must fit within disk.sizeBytes")
        fixed_extents[name] = (partition_offset, partition_end)
    for left, right in (
        ("windows", "boot"),
        ("windows", "recovery"),
        ("boot", "recovery"),
    ):
        left_start, left_end = fixed_extents[left]
        right_start, right_end = fixed_extents[right]
        if left_start < right_end and right_start < left_end:
            raise PlanValidationError(f"disk.{left} and disk.{right} overlap")
    windows_end = fixed_extents["windows"][1]
    recovery_offset = fixed_extents["recovery"][0]
    if windows_end > recovery_offset:
        raise PlanValidationError(
            "disk.recovery must start at or after the original Windows partition end"
        )

    installer = require_mapping(disk.get("installer"), "disk.installer")
    number = require_property(installer, "number", "disk.installer")
    offset = require_property(installer, "offsetBytes", "disk.installer")
    if (number is None) != (offset is None):
        raise PlanValidationError(
            "installer number and offsetBytes must both be set or both be null"
        )
    if number is not None:
        require_positive_integer(number, "disk.installer.number")
        parsed_offset = require_positive_integer(offset, "disk.installer.offsetBytes")
        if parsed_offset % logical_sector_size != 0:
            raise PlanValidationError(
                "disk.installer.offsetBytes must align to disk.logicalSectorSizeBytes"
            )
    if require_installer and number is None:
        raise PlanValidationError("the live installer requires an identified installer partition")
    final_size = require_positive_integer(
        installer.get("finalSizeBytes"), "disk.installer.finalSizeBytes"
    )
    staging_size = require_positive_integer(
        installer.get("stagingSizeBytes"),
        "disk.installer.stagingSizeBytes",
    )
    final_offset = require_positive_integer(
        installer.get("finalOffsetBytes"), "disk.installer.finalOffsetBytes"
    )
    resize_mode = installer.get("resizeMode")
    if resize_mode not in {"windows-online", "live-offline"}:
        raise PlanValidationError(
            "disk.installer.resizeMode must be windows-online or live-offline"
        )
    if final_size % GIB != 0 or staging_size % GIB != 0:
        raise PlanValidationError("installer sizes must be whole numbers of GiB")
    final_size_gib = final_size // GIB
    if final_size_gib < INSTALLATION_POLICY.storage.minimum_final_size_gib:
        raise PlanValidationError(
            "finalSizeBytes must be at least "
            f"{INSTALLATION_POLICY.storage.minimum_final_size_gib} GiB"
        )
    expected_staging_gib = min(
        final_size_gib,
        INSTALLATION_POLICY.storage.staging_size_gib,
    )
    if staging_size != expected_staging_gib * GIB:
        raise PlanValidationError("stagingSizeBytes does not match the shared FAT32 staging policy")
    alignment_bytes = INSTALLATION_POLICY.storage.partition_alignment_bytes
    alignment_padding = windows_end % alignment_bytes
    expected_final_offset = windows_end - alignment_padding - final_size
    if expected_final_offset <= 0 or final_offset != expected_final_offset:
        raise PlanValidationError(
            "disk.installer.finalOffsetBytes does not match the aligned final geometry"
        )
    if final_offset + final_size > recovery_offset:
        raise PlanValidationError("disk.installer final extent would overlap disk.recovery")
    if offset is not None:
        expected_observed_offset = (
            windows_end - alignment_padding - staging_size
            if resize_mode == "live-offline"
            else expected_final_offset
        )
        primary_mbr_offset = expected_observed_offset - alignment_bytes
        offset_matches = parsed_offset == expected_observed_offset or (
            firmware == "bios" and parsed_offset == primary_mbr_offset
        )
        if not offset_matches:
            raise PlanValidationError(
                "disk.installer.offsetBytes does not match the selected Windows shrink geometry"
            )

    features = require_mapping(root.get("features"), "features")
    for name in ("shareWindowsFilesInLinux", "shareLinuxFilesInWindows"):
        if not isinstance(features.get(name), bool):
            raise PlanValidationError(f"features.{name} must be a boolean")
    profiles = require_text(
        features.get("windowsProfilesJsonBase64"),
        "features.windowsProfilesJsonBase64",
    )
    project_windows_profiles(profiles)
    migration = require_mapping(
        features.get("windowsPreferenceMigration"),
        "features.windowsPreferenceMigration",
    )
    migration_enabled = migration.get("enabled")
    if not isinstance(migration_enabled, bool):
        raise PlanValidationError("features.windowsPreferenceMigration.enabled must be a boolean")
    bundle_file_name = require_property(
        migration,
        "bundleFileName",
        "features.windowsPreferenceMigration",
    )
    bundle_sha256 = require_property(
        migration,
        "bundleSha256",
        "features.windowsPreferenceMigration",
    )
    bundle_size = require_nonnegative_integer(
        require_property(
            migration,
            "bundleSizeBytes",
            "features.windowsPreferenceMigration",
        ),
        "features.windowsPreferenceMigration.bundleSizeBytes",
    )
    wifi_profile_count = require_nonnegative_integer(
        require_property(
            migration,
            "wifiProfileCount",
            "features.windowsPreferenceMigration",
        ),
        "features.windowsPreferenceMigration.wifiProfileCount",
    )
    if not migration_enabled:
        if (
            bundle_file_name is not None
            or bundle_sha256 is not None
            or bundle_size != 0
            or wifi_profile_count != 0
        ):
            raise PlanValidationError(
                "disabled Windows preference migration must not describe a bundle"
            )
    else:
        if bundle_file_name != "windows-preferences.secret.json":
            raise PlanValidationError(
                "Windows preference migration must use the fixed transaction bundle name"
            )
        if not SHA256_PATTERN.fullmatch(str(bundle_sha256 or "")):
            raise PlanValidationError(
                "Windows preference migration bundle hash must be a lowercase SHA-256 value"
            )
        if bundle_size <= 0 or bundle_size > 128 * 1024 * 1024:
            raise PlanValidationError(
                "Windows preference migration bundle size is outside the supported range"
            )
        if wifi_profile_count > 256:
            raise PlanValidationError(
                "Windows preference migration Wi-Fi profile count is outside the supported range"
            )

    runtime = require_mapping(root.get("runtime"), "runtime")
    if runtime.get("windowsBitLockerState") not in {"FullyDecrypted", "NotEncryptable"}:
        raise PlanValidationError(
            "runtime.windowsBitLockerState must prove that BitLocker is absent or fully decrypted"
        )
    if not isinstance(runtime.get("lowMemoryMode"), bool):
        raise PlanValidationError("runtime.lowMemoryMode must be a boolean")
    supported_strategies = {
        "bios": {"bios-grub4dos"},
        "uefi": {"uefi-boot-next", "uefi-firmware-boot-order"},
    }
    if runtime.get("bootStrategy") not in supported_strategies[firmware]:
        raise PlanValidationError("runtime.bootStrategy is incompatible with firmware")
    if not isinstance(runtime.get("secureBootEnabled"), bool):
        raise PlanValidationError("runtime.secureBootEnabled must be a boolean")
    trusted_authorities = require_microsoft_uefi_authorities(
        runtime.get("trustedMicrosoftUefiAuthorities"),
        "runtime.trustedMicrosoftUefiAuthorities",
        allow_empty=True,
    )
    if firmware == "bios" and trusted_authorities:
        raise PlanValidationError("a BIOS plan must not contain trusted Microsoft UEFI authorities")
    if firmware == "bios" and runtime["secureBootEnabled"]:
        raise PlanValidationError("a BIOS plan must not enable Secure Boot")
    recovery_root = require_property(runtime, "recoveryRootWindows", "runtime")
    recovery_id = require_property(runtime, "recoveryRunId", "runtime")
    if (recovery_root is None) != (recovery_id is None):
        raise PlanValidationError(
            "recoveryRootWindows and recoveryRunId must both be set or both be null"
        )
    if recovery_root is not None:
        recovery_root = require_safe_absolute_windows_path(
            recovery_root,
            "runtime.recoveryRootWindows",
        )
        if not HEX_ID_PATTERN.fullmatch(str(recovery_id)):
            raise PlanValidationError("runtime.recoveryRunId is invalid")

    windows_paths = {
        "distribution.installerIsoWindowsPath": distribution["installerIsoWindowsPath"],
        "account.passwordHashWindowsPath": password_hash_windows_path,
    }
    if recovery_root is not None:
        windows_paths["runtime.recoveryRootWindows"] = recovery_root
    for path_name, windows_path in windows_paths.items():
        if windows_path[:2].upper() != system_drive:
            raise PlanValidationError(f"{path_name} must be located on disk.systemDrive")
    if recovery_root is not None and ntpath.normcase(password_hash_windows_path) != ntpath.normcase(
        ntpath.join(recovery_root, "account-secret.env")
    ):
        raise PlanValidationError(
            "account.passwordHashWindowsPath must be the plan-owned account-secret.env "
            "under runtime.recoveryRootWindows"
        )

    expected_installer_iso_path = ntpath.join(
        system_drive + "\\",
        "ProgramData",
        "Libertix",
        "Downloads",
        str(root["planId"]),
        distribution["installerIsoFileName"],
    )
    if ntpath.normcase(ntpath.normpath(distribution["installerIsoWindowsPath"])) != ntpath.normcase(
        ntpath.normpath(expected_installer_iso_path)
    ):
        raise PlanValidationError(
            "distribution.installerIsoWindowsPath must use the plan-owned "
            "ProgramData download directory"
        )

    development = root.get("development")
    if development is not None:
        development = require_mapping(development, "development")
        if development.get("enableSsh") is not True:
            raise PlanValidationError("development.enableSsh must be true")
        address_text = require_text(
            development.get("staticIpv4Address"),
            "development.staticIpv4Address",
        )
        try:
            address = ipaddress.IPv4Address(address_text)
        except ipaddress.AddressValueError as error:
            raise PlanValidationError("development.staticIpv4Address must be IPv4") from error
        if (
            address.is_unspecified
            or address.is_loopback
            or address.is_link_local
            or address.is_multicast
            or address.is_reserved
        ):
            raise PlanValidationError(
                "development.staticIpv4Address is not a configurable unicast address"
            )
        prefix_length = development.get("staticIpv4PrefixLength")
        if not isinstance(prefix_length, int) or isinstance(prefix_length, bool):
            raise PlanValidationError("development.staticIpv4PrefixLength must be an integer")
        if not 1 <= prefix_length <= 30:
            raise PlanValidationError("development.staticIpv4PrefixLength must be between 1 and 30")
        network = ipaddress.IPv4Network((address, prefix_length), strict=False)
        if address in {network.network_address, network.broadcast_address}:
            raise PlanValidationError("development.staticIpv4Address must be a usable host address")

        gateway_text = require_text(
            development.get("staticIpv4Gateway"),
            "development.staticIpv4Gateway",
        )
        try:
            gateway = ipaddress.IPv4Address(gateway_text)
        except ipaddress.AddressValueError as error:
            raise PlanValidationError("development.staticIpv4Gateway must be IPv4") from error
        if (
            gateway.is_unspecified
            or gateway.is_loopback
            or gateway.is_link_local
            or gateway.is_multicast
            or gateway.is_reserved
        ):
            raise PlanValidationError(
                "development.staticIpv4Gateway is not a configurable unicast address"
            )
        if gateway not in network or gateway in {
            network.network_address,
            network.broadcast_address,
            address,
        }:
            raise PlanValidationError(
                "development.staticIpv4Gateway must be a different usable address "
                "in the same subnet"
            )

        dns_servers = development.get("dnsServers")
        if not isinstance(dns_servers, list) or not dns_servers:
            raise PlanValidationError(
                "development.dnsServers must contain at least one IPv4 address"
            )
        normalized_dns: list[str] = []
        for dns_server_text in dns_servers:
            try:
                dns_server = ipaddress.IPv4Address(dns_server_text)
            except (ipaddress.AddressValueError, TypeError) as error:
                raise PlanValidationError(
                    "development.dnsServers must contain only IPv4 addresses"
                ) from error
            normalized_dns.append(str(dns_server))
        if len(normalized_dns) != len(set(normalized_dns)):
            raise PlanValidationError("development.dnsServers must not contain duplicates")

    return root


def load_plan(path: Path, *, require_installer: bool = False) -> dict[str, Any]:
    try:
        content = path.read_text(encoding="utf-8-sig")
        raw_plan = json.loads(content)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PlanValidationError(f"cannot read installation plan {path}: {error}") from error
    return validate_plan(raw_plan, require_installer=require_installer)


def shell_values(plan: dict[str, Any]) -> dict[str, str]:
    distribution = plan["distribution"]
    locale = plan["locale"]
    account = plan["account"]
    disk = plan["disk"]
    installer = disk["installer"]
    runtime = plan["runtime"]
    features = plan["features"]
    migration = features["windowsPreferenceMigration"]
    development = plan.get("development")

    final_size = int(installer["finalSizeBytes"])

    values = {
        "INSTALLATION_PLAN_ID": plan["planId"],
        "INSTALLATION_FIRMWARE": plan["firmware"],
        "DISTRIBUTION_ID": distribution["id"],
        "DISTRIBUTION_NAME": distribution["name"],
        "DISTRIBUTION_OS_RELEASE_ID": distribution["osReleaseId"],
        "DISTRIBUTION_GRUB_DISPLAY_NAME": distribution["grubDisplayName"],
        "DISTRIBUTION_GRUB_ICON": distribution["grubIcon"],
        "DISTRIBUTION_SECURE_BOOT_MICROSOFT_AUTHORITIES": ";".join(
            distribution["secureBootMicrosoftAuthorities"]
        ),
        "LANGUAGE_CODE": locale["languageCode"],
        "SYSTEM_LANG": locale["systemLanguage"],
        "KEYBOARD_LAYOUT": locale["keyboardLayout"],
        "KEYBOARD_VARIANT": locale.get("keyboardVariant", ""),
        "KEYBOARD_MODEL": locale["keyboardModel"],
        "TIMEZONE": locale["timezone"],
        "USERNAME": account["username"],
        "PASSWORD_HASH_WINDOWS_PATH": account["passwordHashWindowsPath"],
        "COMPUTER_NAME": account["computerName"],
        "ISO_FILENAME": distribution["installerIsoFileName"],
        "ISO_URL": distribution["installerIsoUrl"],
        "ISO_WINDOWS_PATH": distribution["installerIsoWindowsPath"],
        "ISO_SHA256": distribution["installerIsoSha256"],
        "LINUX_SIZE_GB": str(final_size // GIB),
        "TARGET_DISK_NUMBER": str(disk["number"]),
        "TARGET_DISK_UNIQUE_ID": disk["uniqueId"],
        "TARGET_DISK_PARTITION_TABLE_ID": disk["partitionTableId"],
        "TARGET_DISK_SIZE_BYTES": str(disk["sizeBytes"]),
        "TARGET_LOGICAL_SECTOR_SIZE_BYTES": str(disk["logicalSectorSizeBytes"]),
        "WINDOWS_PARTITION_NUMBER": str(disk["windows"]["number"]),
        "WINDOWS_PARTITION_OFFSET_BYTES": str(disk["windows"]["offsetBytes"]),
        "WINDOWS_PARTITION_SIZE_BYTES": str(disk["windows"]["sizeBytes"]),
        "WINDOWS_BOOT_PARTITION_NUMBER": str(disk["boot"]["number"]),
        "WINDOWS_BOOT_PARTITION_OFFSET_BYTES": str(disk["boot"]["offsetBytes"]),
        "INSTALLER_PARTITION_NUMBER": str(installer["number"]),
        "INSTALLER_PARTITION_OFFSET_BYTES": str(installer["offsetBytes"]),
        "INSTALLER_FINAL_OFFSET_BYTES": str(installer["finalOffsetBytes"]),
        "INSTALLER_RESIZE_MODE": installer["resizeMode"],
        "INSTALLER_FINAL_SIZE_BYTES": str(installer["finalSizeBytes"]),
        "INSTALLER_STAGING_SIZE_BYTES": str(installer["stagingSizeBytes"]),
        "EXPECTED_PARTITION_STYLE": disk["partitionStyle"],
        "RECOVERY_PARTITION_NUMBER": str(disk["recovery"]["number"]),
        "RECOVERY_PARTITION_OFFSET_BYTES": str(disk["recovery"]["offsetBytes"]),
        "RECOVERY_PARTITION_SIZE_BYTES": str(disk["recovery"]["sizeBytes"]),
        "RECOVERY_ROOT_WINDOWS": runtime["recoveryRootWindows"] or "",
        "RECOVERY_RUN_ID": runtime["recoveryRunId"] or "",
        "WINDOWS_BITLOCKER_STATE": runtime["windowsBitLockerState"],
        "LOW_MEMORY_MODE": str(runtime["lowMemoryMode"]).lower(),
        "SECURE_BOOT_ENABLED": str(runtime["secureBootEnabled"]).lower(),
        "TRUSTED_MICROSOFT_UEFI_AUTHORITIES": ";".join(runtime["trustedMicrosoftUefiAuthorities"]),
        "LIVE_MINIMUM_MEMORY_MIB": str(INSTALLATION_POLICY.memory.live_minimum_mib),
        "INSTALLER_ALIGNMENT_BYTES": str(INSTALLATION_POLICY.storage.partition_alignment_bytes),
        "SHARE_WINDOWS_FILES_IN_LINUX": str(features["shareWindowsFilesInLinux"]).lower(),
        "SHARE_LINUX_FILES_IN_WINDOWS": str(features["shareLinuxFilesInWindows"]).lower(),
        "WINDOWS_PROFILES_JSON_BASE64": project_windows_profiles(
            features["windowsProfilesJsonBase64"]
        ),
        "WINDOWS_PREFERENCE_MIGRATION_ENABLED": str(migration["enabled"]).lower(),
        "WINDOWS_PREFERENCE_BUNDLE_FILE_NAME": migration["bundleFileName"] or "",
        "WINDOWS_PREFERENCE_BUNDLE_SHA256": migration["bundleSha256"] or "",
        "WINDOWS_PREFERENCE_BUNDLE_SIZE_BYTES": str(migration["bundleSizeBytes"]),
        "WINDOWS_PREFERENCE_WIFI_PROFILE_COUNT": str(migration["wifiProfileCount"]),
        "DEVELOPMENT_SSH_ENABLED": str(development is not None).lower(),
        "DEVELOPMENT_STATIC_IPV4_ADDRESS": (
            development["staticIpv4Address"] if development else ""
        ),
        "DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH": (
            str(development["staticIpv4PrefixLength"]) if development else ""
        ),
        "DEVELOPMENT_STATIC_IPV4_GATEWAY": (
            development["staticIpv4Gateway"] if development else ""
        ),
        "DEVELOPMENT_DNS_SERVERS": (";".join(development["dnsServers"]) if development else ""),
    }
    return values


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "export-shell", "plan-id"))
    parser.add_argument("path", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    plan = load_plan(args.path, require_installer=args.command in {"export-shell", "plan-id"})
    if args.command == "export-shell":
        for name, value in shell_values(plan).items():
            print(f"{name}\t{value}")
    elif args.command == "plan-id":
        print(plan["planId"])
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PlanValidationError as error:
        print(f"LIVE_E_INSTALLATION_PLAN: {error}", file=sys.stderr)
        raise SystemExit(2) from error
