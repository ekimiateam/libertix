#!/usr/bin/env python3
"""Publish durable evidence from the first boot of the installed system."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import uuid
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path, PureWindowsPath

PLAN_PATH = Path("/etc/libertix/installation-plan.json")
POLICY_PATH = Path("/etc/libertix/Libertix.InstallationPolicy.json")
GRUB_CONFIG_PATH = Path("/boot/grub/grub.cfg")
WINDOWS_MOUNT_PATH = Path("/run/libertix-first-boot-windows")
EVIDENCE_FILE_NAME = "installed-linux-boot.json"
LOCAL_STATUS_PATH = Path("/var/lib/libertix/first-boot-verification.json")
SERVICE_STATE_PATH = Path("/var/lib/libertix/first-boot-service-state.json")
VERIFICATION_LOG_PATH = Path("/var/log/libertix/first-boot-resize.log")
WINDOWS_LOG_ROOT = Path("LibertixInstallLogs/Linux")
DEFAULT_LOCALE_PATH = Path("/etc/default/locale")
DEFAULT_KEYBOARD_PATH = Path("/etc/default/keyboard")
HEX_ID = re.compile(r"^[0-9a-f]{32}$")
EFI_GLOBAL_VARIABLE_GUID = "8be4df61-93ca-11d2-aa0d-00e098032b8c"


class VerificationError(RuntimeError):
    """Raised when first-boot evidence cannot be proven safely."""


def run(*arguments: str) -> str:
    result = subprocess.run(
        arguments,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    if result.returncode != 0:
        diagnostic = (result.stderr or result.stdout).strip()
        raise VerificationError(
            f"command failed with rc={result.returncode}: {' '.join(arguments)}: {diagnostic}"
        )
    return result.stdout.strip()


def read_json(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise VerificationError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise VerificationError(f"{path} does not contain a JSON object")
    return value


def require_mapping(parent: dict[str, object], name: str) -> dict[str, object]:
    value = parent.get(name)
    if not isinstance(value, dict):
        raise VerificationError(f"installation plan field {name} is missing")
    return value


def require_text(parent: dict[str, object], name: str) -> str:
    value = parent.get(name)
    if not isinstance(value, str) or not value.strip():
        raise VerificationError(f"installation plan field {name} is invalid")
    return value


def require_integer(parent: dict[str, object], name: str) -> int:
    value = parent.get(name)
    if not isinstance(value, int) or isinstance(value, bool):
        raise VerificationError(f"installation plan field {name} is invalid")
    return value


def read_os_release(path: Path = Path("/etc/os-release")) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise VerificationError(f"cannot read {path}: {error}") from error
    for line in lines:
        if not line or line.startswith("#") or "=" not in line:
            continue
        name, value = line.split("=", 1)
        try:
            parsed = shlex.split(value, posix=True)
        except ValueError as error:
            raise VerificationError(f"invalid os-release field {name}: {error}") from error
        result[name] = parsed[0] if parsed else ""
    return result


def read_shell_assignments(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise VerificationError(f"cannot read {path}: {error}") from error
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        name, raw_value = stripped.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", name):
            raise VerificationError(f"invalid assignment name in {path}: {name}")
        try:
            values = shlex.split(raw_value, posix=True)
        except ValueError as error:
            raise VerificationError(f"invalid assignment {name} in {path}: {error}") from error
        if len(values) > 1:
            raise VerificationError(f"assignment {name} in {path} has multiple values")
        result[name] = values[0] if values else ""
    return result


def normalize_locale_name(value: str) -> str:
    return value.strip().casefold().replace("utf-8", "utf8")


def verify_localization(
    plan: dict[str, object],
    *,
    locale_path: Path = DEFAULT_LOCALE_PATH,
    keyboard_path: Path = DEFAULT_KEYBOARD_PATH,
    available_locales: str | None = None,
) -> dict[str, object]:
    expected = require_mapping(plan, "locale")
    expected_language = require_text(expected, "languageCode")
    expected_system_locale = require_text(expected, "systemLanguage")
    expected_layout = require_text(expected, "keyboardLayout")
    expected_model = require_text(expected, "keyboardModel")
    expected_variant_value = expected.get("keyboardVariant", "")
    if not isinstance(expected_variant_value, str):
        raise VerificationError("installation plan field keyboardVariant is invalid")

    configured_locale = read_shell_assignments(locale_path)
    required_locale_values = {
        "LANG": expected_system_locale,
        "LC_ALL": expected_system_locale,
        "LANGUAGE": expected_language,
    }
    for name, expected_value in required_locale_values.items():
        if configured_locale.get(name) != expected_value:
            raise VerificationError(f"configured {name} differs from the installation plan")

    compiled_output = available_locales if available_locales is not None else run("locale", "-a")
    compiled_utf8 = {
        normalized
        for value in compiled_output.splitlines()
        if (normalized := normalize_locale_name(value)).endswith(".utf8") and normalized != "c.utf8"
    }
    expected_compiled = {normalize_locale_name(expected_system_locale), "en_us.utf8"}
    if compiled_utf8 != expected_compiled:
        raise VerificationError(
            "compiled UTF-8 locales differ from the requested locale plus en_US.UTF-8"
        )

    configured_keyboard = read_shell_assignments(keyboard_path)
    required_keyboard_values = {
        "XKBMODEL": expected_model,
        "XKBLAYOUT": expected_layout,
        "XKBVARIANT": expected_variant_value,
        "XKBOPTIONS": "",
    }
    for name, expected_value in required_keyboard_values.items():
        if configured_keyboard.get(name) != expected_value:
            raise VerificationError(f"configured {name} differs from the installation plan")

    desktop_source = expected_layout
    if expected_variant_value:
        desktop_source += "+" + expected_variant_value
    return {
        "languageCode": expected_language,
        "systemLocale": expected_system_locale,
        "compiledUtf8Locales": sorted(compiled_utf8),
        "keyboardLayout": expected_layout,
        "keyboardVariant": expected_variant_value,
        "keyboardModel": expected_model,
        "desktopSource": desktop_source,
        "verified": True,
    }


def sysfs_partition_geometry(device: Path) -> tuple[str, int, int, int]:
    device_name = device.resolve().name
    sysfs_path = Path("/sys/class/block") / device_name
    if not (sysfs_path / "partition").is_file():
        raise VerificationError(f"root source is not a partition: {device}")
    resolved = sysfs_path.resolve()
    parent_name = resolved.parent.name
    try:
        partition_number = int((sysfs_path / "partition").read_text().strip())
        offset_bytes = int((sysfs_path / "start").read_text().strip()) * 512
        size_bytes = int((sysfs_path / "size").read_text().strip()) * 512
    except (OSError, ValueError) as error:
        raise VerificationError(f"cannot read geometry for {device}: {error}") from error
    return parent_name, partition_number, offset_bytes, size_bytes


def planned_linux_offset(installer: dict[str, object]) -> int:
    resize_mode = require_text(installer, "resizeMode")
    if resize_mode == "live-offline":
        return require_integer(installer, "finalOffsetBytes")
    if resize_mode == "windows-online":
        return require_integer(installer, "offsetBytes")
    raise VerificationError("installation plan resize mode is invalid")


def find_partition_at_offset(parent_name: str, offset_bytes: int) -> tuple[Path, int]:
    matches: list[tuple[Path, int]] = []
    for candidate in Path("/sys/class/block").glob(f"{parent_name}*"):
        if not (candidate / "partition").is_file():
            continue
        try:
            candidate_offset = int((candidate / "start").read_text().strip()) * 512
            candidate_size = int((candidate / "size").read_text().strip()) * 512
        except (OSError, ValueError):
            continue
        if candidate_offset == offset_bytes:
            matches.append((Path("/dev") / candidate.name, candidate_size))
    if len(matches) != 1:
        raise VerificationError(
            "Windows partition geometry does not resolve to exactly one block device"
        )
    return matches[0]


def mounted_target(device: Path) -> Path | None:
    result = subprocess.run(
        ("findmnt", "-rn", "-S", str(device), "-o", "TARGET"),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    targets = [Path(line) for line in result.stdout.splitlines() if line.strip()]
    if len(targets) > 1:
        raise VerificationError("Windows partition is mounted at multiple locations")
    return targets[0] if targets else None


def windows_relative_path(path: str) -> Path:
    windows_path = PureWindowsPath(path)
    if not windows_path.drive or not windows_path.is_absolute() or ".." in windows_path.parts:
        raise VerificationError("runtime.recoveryRootWindows is not a safe absolute path")
    parts = [part for part in windows_path.parts[1:] if part not in ("\\", "/")]
    if not parts:
        raise VerificationError("runtime.recoveryRootWindows has no relative path")
    return Path(*parts)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def verify_installed_system(
    plan: dict[str, object],
    root_uuid: str,
    fstab_path: Path = Path("/etc/fstab"),
    machine_id_path: Path = Path("/etc/machine-id"),
) -> dict[str, object]:
    root_options = run("findmnt", "-n", "-o", "OPTIONS", "/").split(",")
    if "rw" not in root_options:
        raise VerificationError("the installed root filesystem is not read-write")
    try:
        fstab = fstab_path.read_text(encoding="utf-8")
        machine_id = machine_id_path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeError) as error:
        raise VerificationError(f"cannot read installed-system identity: {error}") from error
    if f"UUID={root_uuid}" not in fstab:
        raise VerificationError("the root filesystem UUID is absent from /etc/fstab")
    if not re.fullmatch(r"[0-9a-f]{32}", machine_id):
        raise VerificationError("the installed system machine-id is invalid")

    account = require_mapping(plan, "account")
    username = require_text(account, "username")
    run("getent", "passwd", username)
    groups = run("id", "-nG", username).split()
    if "sudo" not in groups:
        raise VerificationError("the installed user is not a member of sudo")
    password_status = run("passwd", "-S", username).split()
    if len(password_status) < 2 or password_status[1] != "P":
        raise VerificationError("the installed user does not have an active password")
    run("visudo", "-cf", "/etc/sudoers")

    dpkg_audit = run("dpkg", "--audit")
    if dpkg_audit:
        raise VerificationError(f"dpkg reports an incomplete package state: {dpkg_audit}")
    failed_units = run("systemctl", "--failed", "--no-legend", "--plain")
    if failed_units:
        raise VerificationError(f"systemd reports failed units: {failed_units}")
    return {
        "rootReadWrite": True,
        "fstabRootUuid": root_uuid,
        "machineIdSha256": hashlib.sha256(machine_id.encode("ascii")).hexdigest(),
        "username": username,
        "sudoMember": True,
        "passwordActive": True,
        "dpkgAuditClean": True,
        "failedSystemdUnits": 0,
    }


def write_json_atomic(
    path: Path,
    value: dict[str, object],
    *,
    mode: int = 0o600,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{os.getpid()}.tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, mode)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        os.chmod(path, mode)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        with suppress(FileNotFoundError):
            temporary.unlink()


def parse_efi_load_option(value: bytes) -> dict[str, object]:
    if len(value) < 14:
        raise VerificationError("UEFI boot entry is incomplete")
    payload = value[4:]
    file_path_length = int.from_bytes(payload[4:6], "little")
    description_end = -1
    for offset in range(6, len(payload) - 1, 2):
        if payload[offset : offset + 2] == b"\0\0":
            description_end = offset
            break
    if description_end < 0:
        raise VerificationError("UEFI boot entry description is unterminated")
    try:
        description = payload[6:description_end].decode("utf-16le")
    except UnicodeDecodeError as error:
        raise VerificationError("UEFI boot entry description is invalid") from error
    device_start = description_end + 2
    device_end = device_start + file_path_length
    if device_end > len(payload):
        raise VerificationError("UEFI boot entry device path is truncated")

    partition_number: int | None = None
    partition_guid: str | None = None
    loader_path: str | None = None
    offset = device_start
    while offset < device_end:
        if offset + 4 > device_end:
            raise VerificationError("UEFI boot entry device path node is truncated")
        node_type = payload[offset]
        node_subtype = payload[offset + 1]
        node_length = int.from_bytes(payload[offset + 2 : offset + 4], "little")
        if node_length < 4 or offset + node_length > device_end:
            raise VerificationError("UEFI boot entry device path node length is invalid")
        node = payload[offset : offset + node_length]
        if node_type == 4 and node_subtype == 1 and node_length >= 42:
            if node[40] != 2 or node[41] != 2:
                raise VerificationError("UEFI boot entry does not identify a GPT partition")
            partition_number = int.from_bytes(node[4:8], "little")
            partition_guid = str(uuid.UUID(bytes_le=bytes(node[24:40]))).casefold()
        elif node_type == 4 and node_subtype == 4:
            try:
                loader_path = node[4:].decode("utf-16le").rstrip("\0")
            except UnicodeDecodeError as error:
                raise VerificationError("UEFI boot entry loader path is invalid") from error
        offset += node_length
    if partition_number is None or partition_guid is None or loader_path is None:
        raise VerificationError("UEFI boot entry lacks its GPT partition or loader path")
    return {
        "description": description,
        "partitionNumber": partition_number,
        "partitionGuid": partition_guid,
        "loaderPath": loader_path,
    }


def verify_uefi_boot_current(
    efivars: Path = Path("/sys/firmware/efi/efivars"),
    *,
    expected_boot_number: str | None = None,
    expected_partition_number: int | None = None,
    expected_partition_guid: str | None = None,
    expected_loader_path: str = r"\EFI\Libertix\shimx64.efi",
    preferred_path: dict[str, object] | None = None,
) -> dict[str, object]:
    current_path = efivars / f"BootCurrent-{EFI_GLOBAL_VARIABLE_GUID}"
    try:
        current_value = current_path.read_bytes()
    except OSError as error:
        raise VerificationError(f"cannot read UEFI BootCurrent: {error}") from error
    if len(current_value) < 6:
        raise VerificationError("UEFI BootCurrent is incomplete")
    boot_number_value = int.from_bytes(current_value[4:6], "little")
    boot_number = f"{boot_number_value:04x}"
    entry_path = efivars / f"Boot{boot_number.upper()}-{EFI_GLOBAL_VARIABLE_GUID}"
    try:
        entry_value = entry_path.read_bytes()
    except OSError as error:
        raise VerificationError(f"cannot read UEFI Boot{boot_number}: {error}") from error
    entry = parse_efi_load_option(entry_value)
    normal_libertix_path = (
        entry["description"] == "Libertix"
        and str(entry["loaderPath"]).casefold() == expected_loader_path.casefold()
    )
    preferred_windows_path = (
        preferred_path is not None
        and entry["description"] == "Windows Boot Manager"
        and str(entry["loaderPath"]).casefold() == r"\EFI\Microsoft\Boot\bootmgfw.efi".casefold()
    )
    if not normal_libertix_path and not preferred_windows_path:
        raise VerificationError("UEFI BootCurrent does not identify the installed Libertix shim")
    if (
        normal_libertix_path
        and expected_boot_number is not None
        and boot_number != expected_boot_number.casefold()
    ):
        raise VerificationError("UEFI BootCurrent differs from the installed boot ownership marker")
    if (
        expected_partition_number is not None
        and entry["partitionNumber"] != expected_partition_number
    ):
        raise VerificationError("UEFI BootCurrent identifies a different ESP partition number")
    if (
        expected_partition_guid is not None
        and entry["partitionGuid"] != expected_partition_guid.casefold()
    ):
        raise VerificationError("UEFI BootCurrent identifies a different ESP partition GUID")
    return {
        "type": "uefi-preferred-windows-path" if preferred_windows_path else "uefi-boot-current",
        "bootNumber": boot_number,
        "entry": entry,
        "preferredPath": preferred_path or {},
        "verified": True,
    }


def verify_preferred_uefi_boot_path(
    efi_root: Path,
    plan_id: str,
    uefi_owner: dict[str, object],
) -> dict[str, object] | None:
    manifest_path = efi_root / "preferred-boot-path.json"
    if not manifest_path.is_file():
        return None
    manifest = read_json(manifest_path)
    if (
        manifest.get("version") != 1
        or manifest.get("runId") != plan_id
        or manifest.get("status") != "installed"
    ):
        raise VerificationError("preferred UEFI boot manifest identity or status is invalid")
    esp = require_mapping(manifest, "esp")
    windows_loader = require_mapping(manifest, "windowsLoader")
    preferred = require_mapping(manifest, "preferred")
    if (
        esp.get("partitionNumber") != uefi_owner["partitionNumber"]
        or str(esp.get("partitionGuid", "")).casefold() != uefi_owner["partitionGuid"]
        or windows_loader.get("activePath") != r"\EFI\Microsoft\Boot\bootmgfw.efi"
        or windows_loader.get("backupPath") != r"\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi"
    ):
        raise VerificationError("preferred UEFI boot manifest targets a different ESP or path")

    secure_boot_enabled = manifest.get("secureBootEnabled")
    if not isinstance(secure_boot_enabled, bool):
        raise VerificationError("preferred UEFI boot manifest Secure Boot state is invalid")
    secure_boot = read_json(efi_root / "secure-boot-chain.json")
    expected_secure_status = "verified" if secure_boot_enabled else "not-required"
    if (
        secure_boot.get("version") != 1
        or secure_boot.get("status") != expected_secure_status
        or secure_boot.get("secureBootEnabled") is not secure_boot_enabled
    ):
        raise VerificationError("preferred UEFI boot Secure Boot evidence is invalid")
    secure_images = require_mapping(secure_boot, "images")
    microsoft_root = efi_root.parent / "Microsoft" / "Boot"
    expected_files = (
        (
            microsoft_root / "bootmgfw.efi",
            preferred.get("shimSha256"),
            require_mapping(secure_images, "shim").get("sha256"),
        ),
        (
            microsoft_root / "grubx64.efi",
            preferred.get("grubSha256"),
            require_mapping(secure_images, "grub").get("sha256"),
        ),
        (
            microsoft_root / "mmx64.efi",
            preferred.get("mokManagerSha256"),
            require_mapping(secure_images, "mokManager").get("sha256"),
        ),
        (
            microsoft_root / "grub.cfg",
            preferred.get("grubConfigSha256"),
            preferred.get("grubConfigSha256"),
        ),
        (
            microsoft_root / "bootmgfw.libertix-windows.efi",
            windows_loader.get("sha256"),
            windows_loader.get("sha256"),
        ),
    )
    verified_hashes: dict[str, str] = {}
    for path, manifest_hash, trusted_hash in expected_files:
        if (
            not isinstance(manifest_hash, str)
            or not re.fullmatch(r"[0-9a-f]{64}", manifest_hash)
            or manifest_hash != trusted_hash
            or not path.is_file()
            or sha256(path) != manifest_hash
        ):
            raise VerificationError(
                f"preferred UEFI boot file differs from its verified manifest: {path.name}"
            )
        verified_hashes[path.name] = manifest_hash
    return {
        "manifestPath": str(manifest_path),
        "manifestSha256": sha256(manifest_path),
        "secureBootEvidencePath": str(efi_root / "secure-boot-chain.json"),
        "verifiedHashes": verified_hashes,
    }


def read_uefi_owner_marker(path: Path, plan_id: str) -> dict[str, object]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        raise VerificationError(
            f"cannot read installed UEFI boot ownership marker: {error}"
        ) from error
    if len(lines) != 5 or lines[0].strip() != plan_id:
        raise VerificationError("installed UEFI boot ownership marker is invalid")
    boot_number = lines[1].strip().lower()
    if not re.fullmatch(r"[0-9a-f]{4}", boot_number):
        raise VerificationError("installed UEFI boot ownership number is invalid")
    try:
        partition_number = int(lines[2].strip())
        partition_guid = str(uuid.UUID(lines[3].strip())).casefold()
    except (ValueError, AttributeError) as error:
        raise VerificationError("installed UEFI boot ownership partition is invalid") from error
    loader_path = lines[4].strip()
    if partition_number <= 0 or loader_path.casefold() != r"\EFI\Libertix\shimx64.efi".casefold():
        raise VerificationError("installed UEFI boot ownership target is invalid")
    return {
        "bootNumber": boot_number,
        "partitionNumber": partition_number,
        "partitionGuid": partition_guid,
        "loaderPath": loader_path,
    }


def verify_boot_chain(
    firmware: str,
    disk_device: Path,
    uefi_owner: dict[str, object] | None = None,
    preferred_path: dict[str, object] | None = None,
) -> dict[str, object]:
    if firmware == "uefi":
        if uefi_owner is None:
            return verify_uefi_boot_current()
        return verify_uefi_boot_current(
            expected_boot_number=str(uefi_owner["bootNumber"]),
            expected_partition_number=int(uefi_owner["partitionNumber"]),
            expected_partition_guid=str(uefi_owner["partitionGuid"]),
            expected_loader_path=str(uefi_owner["loaderPath"]),
            preferred_path=preferred_path,
        )

    try:
        with disk_device.open("rb") as stream:
            current_mbr = stream.read(512)
    except OSError as error:
        raise VerificationError(f"cannot read BIOS MBR from {disk_device}: {error}") from error
    if len(current_mbr) != 512 or current_mbr[510:512] != b"\x55\xaa":
        raise VerificationError("the BIOS disk does not contain a valid MBR signature")
    return {
        "type": "bios-mbr",
        "disk": str(disk_device),
        "currentMbrSha256": hashlib.sha256(current_mbr).hexdigest(),
        "bootCodeChangedFromBackup": False,
        "verified": False,
    }


def verify_grub(plan: dict[str, object], firmware: str, disk_device: Path) -> dict[str, object]:
    distribution = require_mapping(plan, "distribution")
    display_name = require_text(distribution, "grubDisplayName")
    run("grub-script-check", str(GRUB_CONFIG_PATH))
    try:
        grub_config = GRUB_CONFIG_PATH.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise VerificationError(f"cannot read {GRUB_CONFIG_PATH}: {error}") from error
    required_fragments = (
        f"menuentry '{display_name}'",
        "--id libertix-windows",
        "--id libertix-shutdown",
        "--id libertix-advanced",
    )
    missing = [fragment for fragment in required_fragments if fragment not in grub_config]
    if missing:
        raise VerificationError(f"GRUB configuration is missing: {missing[0]}")

    kernel_release = run("uname", "-r")
    kernel_image = Path("/boot") / f"vmlinuz-{kernel_release}"
    initrd_image = Path("/boot") / f"initrd.img-{kernel_release}"
    if not kernel_image.is_file() or not initrd_image.is_file():
        raise VerificationError("the running kernel or its initramfs is missing from /boot")

    uefi_owner: dict[str, object] | None = None
    preferred_path: dict[str, object] | None = None
    if firmware == "uefi":
        if not Path("/sys/firmware/efi").is_dir():
            raise VerificationError("the installed system did not boot in UEFI mode")
        efi_root = Path("/boot/efi/EFI/Libertix")
        for relative in ("shimx64.efi", "grubx64.efi", "grub.cfg", ".libertix-owner"):
            if not (efi_root / relative).is_file():
                raise VerificationError(f"installed UEFI boot file is missing: {relative}")
        uefi_owner = read_uefi_owner_marker(
            efi_root / ".libertix-owner",
            require_text(plan, "planId"),
        )
        preferred_path = verify_preferred_uefi_boot_path(
            efi_root,
            require_text(plan, "planId"),
            uefi_owner,
        )
    elif Path("/sys/firmware/efi").exists():
        raise VerificationError("the installed system unexpectedly booted in UEFI mode")

    boot_chain = verify_boot_chain(firmware, disk_device, uefi_owner, preferred_path)

    return {
        "configPath": str(GRUB_CONFIG_PATH),
        "configSha256": sha256(GRUB_CONFIG_PATH),
        "syntaxValid": True,
        "requiredEntriesPresent": True,
        "runningKernel": kernel_release,
        "kernelImage": str(kernel_image),
        "initrdImage": str(initrd_image),
        "bootChain": boot_chain,
    }


def build_evidence(plan: dict[str, object], root_device: Path) -> tuple[dict[str, object], Path]:
    plan_id = require_text(plan, "planId")
    if not HEX_ID.fullmatch(plan_id):
        raise VerificationError("installation plan identifier is invalid")
    firmware = require_text(plan, "firmware")
    if firmware not in ("bios", "uefi"):
        raise VerificationError("installation plan firmware is invalid")
    distribution = require_mapping(plan, "distribution")
    disk = require_mapping(plan, "disk")
    installer = require_mapping(disk, "installer")
    windows = require_mapping(disk, "windows")
    runtime = require_mapping(plan, "runtime")
    policy = read_json(POLICY_PATH)
    storage_policy = require_mapping(policy, "storage")
    alignment_bytes = require_integer(storage_policy, "partitionAlignmentBytes")
    if alignment_bytes <= 0:
        raise VerificationError("installation policy partition alignment is invalid")
    recovery_run_id = require_text(runtime, "recoveryRunId")
    if recovery_run_id != plan_id:
        raise VerificationError("recovery identity differs from the installation plan")

    parent_name, partition_number, offset_bytes, size_bytes = sysfs_partition_geometry(root_device)
    linux_offset = planned_linux_offset(installer)
    if offset_bytes != linux_offset:
        raise VerificationError("root partition offset differs from the installation plan")
    planned_size_bytes = require_integer(installer, "finalSizeBytes")
    if size_bytes > planned_size_bytes or size_bytes < planned_size_bytes - alignment_bytes:
        raise VerificationError("root partition size differs from the installation plan")
    root_uuid = run("blkid", "-s", "UUID", "-o", "value", str(root_device))
    if not root_uuid:
        raise VerificationError("root filesystem UUID is missing")

    os_release = read_os_release()
    expected_os_id = require_text(distribution, "osReleaseId")
    if os_release.get("ID") != expected_os_id:
        raise VerificationError(
            "installed distribution mismatch: "
            f"expected {expected_os_id}, found {os_release.get('ID')}"
        )

    windows_device, windows_size_bytes = find_partition_at_offset(
        parent_name,
        require_integer(windows, "offsetBytes"),
    )
    windows_end = require_integer(windows, "offsetBytes") + windows_size_bytes
    gap_before_linux = linux_offset - windows_end
    if gap_before_linux < 0 or gap_before_linux > 1024 * 1024:
        raise VerificationError("Windows and Linux partition geometry has an unexpected gap")
    original_windows_size = require_integer(windows, "sizeBytes")
    actual_shrink = original_windows_size - windows_size_bytes
    expected_linux_size = require_integer(installer, "finalSizeBytes")
    if actual_shrink < expected_linux_size or actual_shrink > expected_linux_size + 2 * 1024 * 1024:
        raise VerificationError("Windows partition shrink differs from the installation plan")
    boot_id = Path("/proc/sys/kernel/random/boot_id").read_text(encoding="ascii").strip()
    if not re.fullmatch(r"[0-9a-f-]{36}", boot_id):
        raise VerificationError("Linux boot identifier is invalid")

    evidence = {
        "schemaVersion": 1,
        "planId": plan_id,
        "recoveryRunId": recovery_run_id,
        "observedAtUtc": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "bootId": boot_id,
        "firmware": firmware,
        "distribution": {
            "id": require_text(distribution, "id"),
            "osReleaseId": os_release.get("ID", ""),
            "versionId": os_release.get("VERSION_ID", ""),
            "prettyName": os_release.get("PRETTY_NAME", ""),
        },
        "root": {
            "device": str(root_device),
            "partitionNumber": partition_number,
            "offsetBytes": offset_bytes,
            "sizeBytes": size_bytes,
            "plannedSizeBytes": planned_size_bytes,
            "alignmentToleranceBytes": alignment_bytes,
            "uuid": root_uuid,
            "filesystem": run("findmnt", "-n", "-o", "FSTYPE", "/"),
        },
        "system": verify_installed_system(plan, root_uuid),
        "localization": verify_localization(plan),
        "grub": verify_grub(plan, firmware, Path("/dev") / parent_name),
    }
    return evidence, windows_device


def publish_evidence(plan: dict[str, object], evidence: dict[str, object], device: Path) -> Path:
    runtime = require_mapping(plan, "runtime")
    relative_root = windows_relative_path(require_text(runtime, "recoveryRootWindows"))
    mount_path = mounted_target(device)
    mounted_here = mount_path is None
    if mounted_here:
        WINDOWS_MOUNT_PATH.mkdir(parents=True, exist_ok=True)
        run("mount", "-t", "ntfs-3g", "-o", "rw", str(device), str(WINDOWS_MOUNT_PATH))
        mount_path = WINDOWS_MOUNT_PATH
    assert mount_path is not None
    try:
        options = run("findmnt", "-rn", "-T", str(mount_path), "-o", "OPTIONS").split(",")
        if "rw" not in options:
            raise VerificationError("Windows partition is not mounted read-write")
        destination = mount_path / relative_root / EVIDENCE_FILE_NAME
        if require_text(plan, "firmware") == "bios":
            backup_path = mount_path / relative_root / "mbr-backup" / "mbr-before-grub.bin"
            try:
                backup_mbr = backup_path.read_bytes()
                current_disk = Path(str(evidence["grub"]["bootChain"]["disk"]))  # type: ignore[index]
                with current_disk.open("rb") as stream:
                    current_mbr = stream.read(512)
            except OSError as error:
                raise VerificationError(
                    f"cannot compare the installed BIOS MBR: {error}"
                ) from error
            if len(backup_mbr) != 512 or len(current_mbr) != 512:
                raise VerificationError("the durable or current BIOS MBR is incomplete")
            if current_mbr[:440] == backup_mbr[:440]:
                raise VerificationError("BIOS boot code did not change from the pre-GRUB backup")
            boot_chain = evidence["grub"]["bootChain"]  # type: ignore[index]
            boot_chain["backupMbrSha256"] = hashlib.sha256(backup_mbr).hexdigest()  # type: ignore[index]
            boot_chain["bootCodeChangedFromBackup"] = True  # type: ignore[index]
            boot_chain["verified"] = True  # type: ignore[index]
        write_json_atomic(destination, evidence)
        return destination
    finally:
        if mounted_here:
            run("sync")
            run("umount", str(WINDOWS_MOUNT_PATH))


def resolve_windows_device(plan: dict[str, object]) -> Path:
    root_source = Path(run("findmnt", "-n", "-o", "SOURCE", "/"))
    if not root_source.exists():
        raise VerificationError(f"root source is not a block device: {root_source}")
    parent_name, _, _, _ = sysfs_partition_geometry(root_source)
    windows = require_mapping(require_mapping(plan, "disk"), "windows")
    device, _ = find_partition_at_offset(parent_name, require_integer(windows, "offsetBytes"))
    return device


def update_log_checksums(directory: Path) -> None:
    checksums = []
    for path in sorted(directory.rglob("*")):
        if path.is_file() and path.name != "SHA256SUMS":
            checksums.append(f"{sha256(path)}  {path.relative_to(directory)}")
    temporary = directory / f".SHA256SUMS.{os.getpid()}.tmp"
    temporary.write_text("\n".join(checksums) + "\n", encoding="ascii")
    os.replace(temporary, directory / "SHA256SUMS")


def archive_linux_diagnostics(plan: dict[str, object], device: Path | None = None) -> Path:
    runtime = require_mapping(plan, "runtime")
    run_id = require_text(runtime, "recoveryRunId")
    if not HEX_ID.fullmatch(run_id):
        raise VerificationError("runtime.recoveryRunId is invalid")
    windows_device = device if device is not None else resolve_windows_device(plan)
    mount_path = mounted_target(windows_device)
    mounted_here = mount_path is None
    if mounted_here:
        WINDOWS_MOUNT_PATH.mkdir(parents=True, exist_ok=True)
        run("mount", "-t", "ntfs-3g", "-o", "rw", str(windows_device), str(WINDOWS_MOUNT_PATH))
        mount_path = WINDOWS_MOUNT_PATH
    assert mount_path is not None
    try:
        options = run("findmnt", "-rn", "-T", str(mount_path), "-o", "OPTIONS").split(",")
        if "rw" not in options:
            raise VerificationError("Windows partition is not mounted read-write")
        archive = mount_path / WINDOWS_LOG_ROOT / run_id
        archive.mkdir(parents=True, exist_ok=True)
        sources = (
            (VERIFICATION_LOG_PATH, "first-boot-verification.log"),
            (LOCAL_STATUS_PATH, "first-boot-verification.json"),
            (SERVICE_STATE_PATH, "first-boot-service-state.json"),
        )
        for source, name in sources:
            if source.is_file():
                shutil.copy2(source, archive / name)
        update_log_checksums(archive)

        latest = mount_path / WINDOWS_LOG_ROOT / "latest"
        latest_plan = read_json(latest / "installation-plan.json") if latest.is_dir() else {}
        if latest_plan.get("planId") == plan.get("planId"):
            for source, name in sources:
                if source.is_file():
                    shutil.copy2(source, latest / name)
            update_log_checksums(latest)
        run("sync")
        return archive
    finally:
        if mounted_here:
            run("umount", str(WINDOWS_MOUNT_PATH))


def write_local_status(
    status: str,
    *,
    plan: dict[str, object] | None,
    error: str | None = None,
    evidence: dict[str, object] | None = None,
    windows_evidence_path: Path | None = None,
    service_stage: str | None = None,
) -> dict[str, object]:
    plan_id = plan.get("planId") if isinstance(plan, dict) else None
    value: dict[str, object] = {
        "schemaVersion": 1,
        "status": status,
        "planId": plan_id if isinstance(plan_id, str) else "",
        "updatedAtUtc": datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "logPath": str(VERIFICATION_LOG_PATH),
        "error": error,
    }
    if service_stage:
        value["serviceStage"] = service_stage
    if evidence is not None:
        value["distribution"] = evidence.get("distribution", {})
        value["root"] = evidence.get("root", {})
        value["system"] = evidence.get("system", {})
        value["localization"] = evidence.get("localization", {})
        value["grub"] = evidence.get("grub", {})
    if windows_evidence_path is not None:
        value["windowsEvidencePath"] = str(windows_evidence_path)
    write_json_atomic(LOCAL_STATUS_PATH, value, mode=0o644)
    return value


def read_optional_json(path: Path) -> dict[str, object] | None:
    try:
        return read_json(path)
    except VerificationError:
        return None


def record_service_start(stage: str) -> str:
    now = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    state = read_optional_json(SERVICE_STATE_PATH) or {
        "schemaVersion": 1,
        "attempts": [],
        "interruptionCount": 0,
    }
    attempts = state.get("attempts")
    if not isinstance(attempts, list):
        attempts = []
    interrupted = 0
    for attempt in attempts:
        if isinstance(attempt, dict) and attempt.get("outcome") in (
            "running",
            "shutdown-requested",
        ):
            attempt["outcome"] = "interrupted"
            attempt["interruptionDetectedAtUtc"] = now
            interrupted += 1
    count = state.get("interruptionCount", 0)
    if not isinstance(count, int) or isinstance(count, bool):
        count = 0
    attempt_id = uuid.uuid4().hex
    attempts.append(
        {
            "attemptId": attempt_id,
            "processId": os.getpid(),
            "startedAtUtc": now,
            "completedAtUtc": None,
            "stage": stage,
            "outcome": "running",
        }
    )
    state.update(
        {
            "schemaVersion": 1,
            "status": "running",
            "activeAttemptId": attempt_id,
            "attempts": attempts,
            "interruptionCount": count + interrupted,
            "updatedAtUtc": now,
        }
    )
    write_json_atomic(SERVICE_STATE_PATH, state, mode=0o644)
    return attempt_id


def update_service_attempt(attempt_id: str, stage: str, outcome: str) -> None:
    if not HEX_ID.fullmatch(attempt_id):
        raise VerificationError("first-boot service attempt identifier is invalid")
    if outcome not in ("shutdown-requested", "succeeded", "failed"):
        raise VerificationError("first-boot service attempt outcome is invalid")
    state = read_json(SERVICE_STATE_PATH)
    attempts = state.get("attempts")
    if not isinstance(attempts, list):
        raise VerificationError("first-boot service attempt history is invalid")
    matches = [
        attempt
        for attempt in attempts
        if isinstance(attempt, dict) and attempt.get("attemptId") == attempt_id
    ]
    if len(matches) != 1:
        raise VerificationError("first-boot service attempt is missing or ambiguous")
    attempt = matches[0]
    current_outcome = attempt.get("outcome")
    if current_outcome not in ("running", "shutdown-requested") and not (
        current_outcome == "succeeded" and outcome == "failed"
    ):
        raise VerificationError("first-boot service attempt is not active")
    now = datetime.now(UTC).isoformat().replace("+00:00", "Z")
    attempt["stage"] = stage
    attempt["outcome"] = outcome
    if outcome == "shutdown-requested":
        attempt["shutdownRequestedAtUtc"] = now
    else:
        attempt["completedAtUtc"] = now
        state["activeAttemptId"] = None
    state["status"] = outcome
    state["updatedAtUtc"] = now
    write_json_atomic(SERVICE_STATE_PATH, state, mode=0o644)


def archive_service_diagnostics() -> Path:
    plan = read_json(PLAN_PATH)
    return archive_linux_diagnostics(plan)


def record_service_failure(
    message: str,
    attempt_id: str | None = None,
    stage: str = "first-boot-resize",
) -> int:
    plan: dict[str, object] | None
    try:
        plan = read_json(PLAN_PATH)
    except VerificationError:
        plan = None
    write_local_status(
        "failed",
        plan=plan,
        error=message,
        service_stage=stage,
    )
    if attempt_id:
        update_service_attempt(attempt_id, stage, "failed")
    if plan is not None:
        try:
            archive_linux_diagnostics(plan)
        except Exception as archive_error:
            print(f"FIRST_BOOT_LOG_ARCHIVE_ERROR={archive_error}", file=sys.stderr)
    return 0


def main() -> int:
    plan = read_json(PLAN_PATH)
    root_source = Path(run("findmnt", "-n", "-o", "SOURCE", "/"))
    if not root_source.exists():
        raise VerificationError(f"root source is not a block device: {root_source}")
    if run("findmnt", "-n", "-o", "FSTYPE", "/") != "ext4":
        raise VerificationError("root filesystem is not ext4")
    evidence, windows_device = build_evidence(plan, root_source)
    destination = publish_evidence(plan, evidence, windows_device)
    write_local_status(
        "succeeded",
        plan=plan,
        evidence=evidence,
        windows_evidence_path=destination,
    )
    archive = archive_linux_diagnostics(plan, windows_device)
    print(f"FIRST_BOOT_EVIDENCE={destination}")
    print(f"FIRST_BOOT_LOG_ARCHIVE={archive}")
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--record-service-start":
        print(record_service_start(sys.argv[2]))
        raise SystemExit(0)
    if len(sys.argv) == 5 and sys.argv[1] == "--update-service-attempt":
        update_service_attempt(sys.argv[2], sys.argv[3], sys.argv[4])
        raise SystemExit(0)
    if len(sys.argv) == 2 and sys.argv[1] == "--archive-service-diagnostics":
        print(f"FIRST_BOOT_LOG_ARCHIVE={archive_service_diagnostics()}")
        raise SystemExit(0)
    if len(sys.argv) in (3, 4, 5) and sys.argv[1] == "--record-service-failure":
        attempt_id = sys.argv[2] if len(sys.argv) >= 4 else None
        stage = sys.argv[3] if len(sys.argv) == 5 else "first-boot-resize"
        message = sys.argv[4] if len(sys.argv) == 5 else sys.argv[-1]
        raise SystemExit(record_service_failure(message, attempt_id, stage))
    try:
        raise SystemExit(main())
    except VerificationError as error:
        try:
            failed_plan = read_json(PLAN_PATH)
        except VerificationError:
            failed_plan = None
        write_local_status("failed", plan=failed_plan, error=str(error))
        if failed_plan is not None:
            try:
                archive_linux_diagnostics(failed_plan)
            except Exception as archive_error:
                print(f"FIRST_BOOT_LOG_ARCHIVE_ERROR={archive_error}", file=sys.stderr)
        print(f"FIRST_BOOT_VERIFICATION_ERROR={error}", file=sys.stderr)
        raise SystemExit(1) from error
    except Exception as error:
        try:
            failed_plan = read_json(PLAN_PATH)
        except VerificationError:
            failed_plan = None
        write_local_status(
            "failed",
            plan=failed_plan,
            error=f"unexpected verification error: {error}",
        )
        if failed_plan is not None:
            try:
                archive_linux_diagnostics(failed_plan)
            except Exception as archive_error:
                print(f"FIRST_BOOT_LOG_ARCHIVE_ERROR={archive_error}", file=sys.stderr)
        print(f"FIRST_BOOT_VERIFICATION_ERROR={error}", file=sys.stderr)
        raise SystemExit(1) from error
