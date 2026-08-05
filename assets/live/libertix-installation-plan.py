#!/usr/bin/env python3
"""Validate and expose the versioned Libertix installation plan to Bash."""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import ipaddress
import json
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

GIB = 1024**3
MINIMUM_FINAL_SIZE_GIB = 20
MAXIMUM_DIRECT_FAT32_SIZE_GIB = 31
LARGE_INSTALLATION_STAGING_SIZE_GIB = 8
HEX_ID_PATTERN = re.compile(r"^[0-9a-f]{32}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
USERNAME_PATTERN = re.compile(r"^[a-z](?:[a-z0-9-]{0,30}[a-z0-9])?$")
XKB_NAME_PATTERN = re.compile(r"^[a-z0-9_-]+$")


class PlanValidationError(ValueError):
    """Raised when a plan cannot safely drive an installation."""


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


def validate_partition(value: Any, path: str) -> dict[str, Any]:
    partition = require_mapping(value, path)
    require_positive_integer(require_property(partition, "number", path), f"{path}.number")
    require_positive_integer(
        require_property(partition, "offsetBytes", path),
        f"{path}.offsetBytes",
    )
    require_positive_integer(
        require_property(partition, "sizeBytes", path),
        f"{path}.sizeBytes",
    )
    return partition


def validate_plan(plan: Any, *, require_installer: bool = False) -> dict[str, Any]:
    root = require_mapping(plan, "plan")
    if root.get("schemaVersion") != 1:
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
        "name",
        "installerIsoFileName",
        "installerIsoUrl",
        "installerIsoWindowsPath",
    ):
        require_text(require_property(distribution, name, "distribution"), f"distribution.{name}")
    if "/" in distribution["installerIsoFileName"] or "\\" in distribution["installerIsoFileName"]:
        raise PlanValidationError("distribution.installerIsoFileName must not contain a path")
    if not re.match(r"^[A-Za-z]:[\\/]", distribution["installerIsoWindowsPath"]):
        raise PlanValidationError(
            "distribution.installerIsoWindowsPath must be an absolute Windows drive path"
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
    if language_code not in {"en", "fr", "es", "ja"}:
        raise PlanValidationError("locale.languageCode must be one of: en, fr, es, ja")
    for name in ("systemLanguage", "keyboardLayout", "keyboardModel", "timezone"):
        require_text(require_property(locale, name, "locale"), f"locale.{name}")
    for name in ("keyboardLayout", "keyboardModel"):
        if not XKB_NAME_PATTERN.fullmatch(locale[name]):
            raise PlanValidationError(f"locale.{name} is not a valid XKB name")
    keyboard_variant = locale.get("keyboardVariant", "")
    if not isinstance(keyboard_variant, str) or (
        keyboard_variant and not XKB_NAME_PATTERN.fullmatch(keyboard_variant)
    ):
        raise PlanValidationError("locale.keyboardVariant is not a valid XKB variant name")

    account = require_mapping(root.get("account"), "account")
    if not USERNAME_PATTERN.fullmatch(str(account.get("username", ""))):
        raise PlanValidationError("account.username is invalid")
    password_hash = str(account.get("passwordHash", ""))
    if not re.fullmatch(r"\$6\$[^\r\n\t]+", password_hash):
        raise PlanValidationError("account.passwordHash must use SHA-512 crypt")
    computer_name = require_text(account.get("computerName"), "account.computerName")
    if len(computer_name) > 63:
        raise PlanValidationError("account.computerName cannot exceed 63 characters")

    disk = require_mapping(root.get("disk"), "disk")
    disk_number = disk.get("number")
    if isinstance(disk_number, bool) or not isinstance(disk_number, int) or disk_number < 0:
        raise PlanValidationError("disk.number cannot be negative")
    require_text(disk.get("uniqueId"), "disk.uniqueId")
    require_positive_integer(disk.get("sizeBytes"), "disk.sizeBytes")
    require_positive_integer(disk.get("logicalSectorSizeBytes"), "disk.logicalSectorSizeBytes")
    system_drive = require_text(disk.get("systemDrive"), "disk.systemDrive")
    if not re.fullmatch(r"[A-Z]:", system_drive):
        raise PlanValidationError("disk.systemDrive must be an uppercase Windows drive")
    expected_style = "MBR" if firmware == "bios" else "GPT"
    if disk.get("partitionStyle") != expected_style:
        raise PlanValidationError(
            f"firmware {firmware!r} requires partitionStyle {expected_style!r}"
        )
    for name in ("windows", "boot", "recovery"):
        validate_partition(disk.get(name), f"disk.{name}")

    installer = require_mapping(disk.get("installer"), "disk.installer")
    number = require_property(installer, "number", "disk.installer")
    offset = require_property(installer, "offsetBytes", "disk.installer")
    if (number is None) != (offset is None):
        raise PlanValidationError(
            "installer number and offsetBytes must both be set or both be null"
        )
    if number is not None:
        require_positive_integer(number, "disk.installer.number")
        require_positive_integer(offset, "disk.installer.offsetBytes")
    if require_installer and number is None:
        raise PlanValidationError("the live installer requires an identified installer partition")
    final_size = require_positive_integer(
        installer.get("finalSizeBytes"), "disk.installer.finalSizeBytes"
    )
    staging_size = require_positive_integer(
        installer.get("stagingSizeBytes"),
        "disk.installer.stagingSizeBytes",
    )
    if final_size % GIB != 0 or staging_size % GIB != 0:
        raise PlanValidationError("installer sizes must be whole numbers of GiB")
    final_size_gib = final_size // GIB
    if final_size_gib < MINIMUM_FINAL_SIZE_GIB:
        raise PlanValidationError(f"finalSizeBytes must be at least {MINIMUM_FINAL_SIZE_GIB} GiB")
    expected_staging_gib = (
        LARGE_INSTALLATION_STAGING_SIZE_GIB
        if final_size_gib > MAXIMUM_DIRECT_FAT32_SIZE_GIB
        else final_size_gib
    )
    if staging_size != expected_staging_gib * GIB:
        raise PlanValidationError("stagingSizeBytes does not match the shared FAT32 staging policy")

    features = require_mapping(root.get("features"), "features")
    for name in ("shareWindowsFilesInLinux", "shareLinuxFilesInWindows"):
        if not isinstance(features.get(name), bool):
            raise PlanValidationError(f"features.{name} must be a boolean")
    profiles = require_text(
        features.get("windowsProfilesJsonBase64"),
        "features.windowsProfilesJsonBase64",
    )
    try:
        decoded_profiles = base64.b64decode(profiles, validate=True)
    except ValueError as error:
        raise PlanValidationError("windowsProfilesJsonBase64 must be valid Base64") from error
    if not decoded_profiles:
        raise PlanValidationError("windowsProfilesJsonBase64 must not decode to an empty value")

    runtime = require_mapping(root.get("runtime"), "runtime")
    if not isinstance(runtime.get("lowMemoryMode"), bool):
        raise PlanValidationError("runtime.lowMemoryMode must be a boolean")
    supported_strategies = {
        "bios": {"bios-grub4dos"},
        "uefi": {"uefi-boot-next", "uefi-firmware-boot-order"},
    }
    if runtime.get("bootStrategy") not in supported_strategies[firmware]:
        raise PlanValidationError("runtime.bootStrategy is incompatible with firmware")
    recovery_root = require_property(runtime, "recoveryRootWindows", "runtime")
    recovery_id = require_property(runtime, "recoveryRunId", "runtime")
    if (recovery_root is None) != (recovery_id is None):
        raise PlanValidationError(
            "recoveryRootWindows and recoveryRunId must both be set or both be null"
        )
    if recovery_root is not None:
        require_text(recovery_root, "runtime.recoveryRootWindows")
        if not HEX_ID_PATTERN.fullmatch(str(recovery_id)):
            raise PlanValidationError("runtime.recoveryRunId is invalid")

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
            raise PlanValidationError(
                "development.staticIpv4Address must be IPv4"
            ) from error
        if address not in ipaddress.IPv4Network("192.168.1.0/24") or int(address) & 0xFF in {
            0,
            1,
            255,
        }:
            raise PlanValidationError(
                "development.staticIpv4Address must be usable in 192.168.1.0/24"
            )
        if development.get("staticIpv4PrefixLength") != 24:
            raise PlanValidationError("development.staticIpv4PrefixLength must be 24")
        if development.get("staticIpv4Gateway") != "192.168.1.1":
            raise PlanValidationError(
                "development.staticIpv4Gateway must be 192.168.1.1"
            )
        if development.get("dnsServers") != ["8.8.8.8", "1.1.1.1"]:
            raise PlanValidationError(
                "development.dnsServers must contain 8.8.8.8 then 1.1.1.1"
            )

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
    development = plan.get("development")

    final_size = int(installer["finalSizeBytes"])

    values = {
        "INSTALLATION_PLAN_ID": plan["planId"],
        "INSTALLATION_FIRMWARE": plan["firmware"],
        "LANGUAGE_CODE": locale["languageCode"],
        "SYSTEM_LANG": locale["systemLanguage"],
        "KEYBOARD_LAYOUT": locale["keyboardLayout"],
        "KEYBOARD_VARIANT": locale.get("keyboardVariant", ""),
        "KEYBOARD_MODEL": locale["keyboardModel"],
        "TIMEZONE": locale["timezone"],
        "USERNAME": account["username"],
        "PASSWORD_HASH": account["passwordHash"],
        "COMPUTER_NAME": account["computerName"],
        "ISO_FILENAME": distribution["installerIsoFileName"],
        "ISO_URL": distribution["installerIsoUrl"],
        "ISO_WINDOWS_PATH": distribution["installerIsoWindowsPath"],
        "ISO_SHA256": distribution["installerIsoSha256"],
        "LINUX_SIZE_GB": str(final_size // GIB),
        "TARGET_DISK_NUMBER": str(disk["number"]),
        "TARGET_DISK_UNIQUE_ID": disk["uniqueId"],
        "TARGET_DISK_SIZE_BYTES": str(disk["sizeBytes"]),
        "TARGET_LOGICAL_SECTOR_SIZE_BYTES": str(disk["logicalSectorSizeBytes"]),
        "WINDOWS_PARTITION_NUMBER": str(disk["windows"]["number"]),
        "WINDOWS_PARTITION_OFFSET_BYTES": str(disk["windows"]["offsetBytes"]),
        "WINDOWS_BOOT_PARTITION_NUMBER": str(disk["boot"]["number"]),
        "WINDOWS_BOOT_PARTITION_OFFSET_BYTES": str(disk["boot"]["offsetBytes"]),
        "INSTALLER_PARTITION_NUMBER": str(installer["number"]),
        "INSTALLER_PARTITION_OFFSET_BYTES": str(installer["offsetBytes"]),
        "INSTALLER_FINAL_SIZE_BYTES": str(installer["finalSizeBytes"]),
        "INSTALLER_STAGING_SIZE_BYTES": str(installer["stagingSizeBytes"]),
        "EXPECTED_PARTITION_STYLE": disk["partitionStyle"],
        "RECOVERY_PARTITION_NUMBER": str(disk["recovery"]["number"]),
        "RECOVERY_PARTITION_OFFSET_BYTES": str(disk["recovery"]["offsetBytes"]),
        "RECOVERY_PARTITION_SIZE_BYTES": str(disk["recovery"]["sizeBytes"]),
        "RECOVERY_ROOT_WINDOWS": runtime["recoveryRootWindows"] or "",
        "RECOVERY_RUN_ID": runtime["recoveryRunId"] or "",
        "LOW_MEMORY_MODE": str(runtime["lowMemoryMode"]).lower(),
        "SHARE_WINDOWS_FILES_IN_LINUX": str(features["shareWindowsFilesInLinux"]).lower(),
        "SHARE_LINUX_FILES_IN_WINDOWS": str(features["shareLinuxFilesInWindows"]).lower(),
        "WINDOWS_PROFILES_JSON_BASE64": features["windowsProfilesJsonBase64"],
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
        "DEVELOPMENT_DNS_PRIMARY": development["dnsServers"][0] if development else "",
        "DEVELOPMENT_DNS_SECONDARY": development["dnsServers"][1] if development else "",
    }
    return values


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("validate", "export-shell"))
    parser.add_argument("path", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    plan = load_plan(args.path, require_installer=args.command == "export-shell")
    if args.command == "export-shell":
        for name, value in shell_values(plan).items():
            print(f"{name}\t{value}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PlanValidationError as error:
        print(f"LIVE_E_INSTALLATION_PLAN: {error}", file=sys.stderr)
        raise SystemExit(2) from error
