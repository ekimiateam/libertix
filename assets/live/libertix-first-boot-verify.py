#!/usr/bin/env python3
"""Publish durable evidence from the first boot of the installed system."""

from __future__ import annotations

import hashlib
import json
import os
import re
import shlex
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


def write_json_atomic(path: Path, value: dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.parent / f".{path.name}.{os.getpid()}.tmp"
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            json.dump(value, stream, ensure_ascii=False, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
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
    if (
        entry["description"] != "Libertix"
        or str(entry["loaderPath"]).casefold() != expected_loader_path.casefold()
    ):
        raise VerificationError("UEFI BootCurrent does not identify the installed Libertix shim")
    if expected_boot_number is not None and boot_number != expected_boot_number.casefold():
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
        "type": "uefi-boot-current",
        "bootNumber": boot_number,
        "entry": entry,
        "verified": True,
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
) -> dict[str, object]:
    if firmware == "uefi":
        if uefi_owner is None:
            return verify_uefi_boot_current()
        return verify_uefi_boot_current(
            expected_boot_number=str(uefi_owner["bootNumber"]),
            expected_partition_number=int(uefi_owner["partitionNumber"]),
            expected_partition_guid=str(uefi_owner["partitionGuid"]),
            expected_loader_path=str(uefi_owner["loaderPath"]),
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
    elif Path("/sys/firmware/efi").exists():
        raise VerificationError("the installed system unexpectedly booted in UEFI mode")

    boot_chain = verify_boot_chain(firmware, disk_device, uefi_owner)

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
    if offset_bytes != require_integer(installer, "offsetBytes"):
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
    linux_offset = require_integer(installer, "offsetBytes")
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


def main() -> int:
    plan = read_json(PLAN_PATH)
    root_source = Path(run("findmnt", "-n", "-o", "SOURCE", "/"))
    if not root_source.exists():
        raise VerificationError(f"root source is not a block device: {root_source}")
    if run("findmnt", "-n", "-o", "FSTYPE", "/") != "ext4":
        raise VerificationError("root filesystem is not ext4")
    evidence, windows_device = build_evidence(plan, root_source)
    destination = publish_evidence(plan, evidence, windows_device)
    print(f"FIRST_BOOT_EVIDENCE={destination}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except VerificationError as error:
        print(f"FIRST_BOOT_VERIFICATION_ERROR={error}", file=sys.stderr)
        raise SystemExit(1) from error
