#!/usr/bin/env python3
"""Validate and mount only the Windows volumes referenced by shared user folders."""

from __future__ import annotations

import argparse
import json
import os
import pwd
import re
import stat
import subprocess
import tempfile
from contextlib import contextmanager
from pathlib import Path
from typing import Any

from libertix_installation_policy import load_installation_policy

SYS_CLASS_BLOCK = Path("/sys/class/block")
FSTAB_PATH = Path("/etc/fstab")
PARTITION_ALIGNMENT_BYTES = load_installation_policy().storage.partition_alignment_bytes


def validate_sharing(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != {"version", "volumes", "folders"}:
        raise ValueError("Windows sharing inventory is incomplete")
    volumes, folders = value["volumes"], value["folders"]
    if (
        type(value["version"]) is not int
        or value["version"] != 1
        or not isinstance(volumes, list)
        or not isinstance(folders, list)
    ):
        raise ValueError("Windows sharing inventory version or arrays are invalid")
    if len(volumes) > 64 or len(folders) > 256:
        raise ValueError("Windows sharing inventory exceeds its bounds")
    ids = set()
    for volume in volumes:
        if not isinstance(volume, dict) or set(volume) != {
            "ntfsUuid",
            "disk",
            "offsetBytes",
            "sizeBytes",
            "windowsVolumeId",
            "windowsDrive",
        }:
            raise ValueError("Windows sharing volume fields are invalid")
        identifier = volume["ntfsUuid"]
        disk = volume["disk"]
        if (
            not isinstance(identifier, str)
            or not re.fullmatch(r"[A-F0-9]{16}", identifier)
            or identifier == "0" * 16
            or identifier in ids
        ):
            raise ValueError("Windows sharing NTFS identity is invalid or duplicated")
        ids.add(identifier)
        if not isinstance(disk, dict) or set(disk) != {
            "partitionTableId",
            "partitionStyle",
            "sizeBytes",
            "logicalSectorSizeBytes",
        }:
            raise ValueError("Windows sharing disk fields are invalid")
        pattern = {
            "GPT": r"gpt:[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}",
            "MBR": r"mbr:[0-9a-f]{8}",
        }.get(disk["partitionStyle"])
        if (
            pattern is None
            or not isinstance(disk["partitionTableId"], str)
            or not re.fullmatch(pattern, disk["partitionTableId"])
        ):
            raise ValueError("Windows sharing disk table identity is invalid")
        for number in (volume["offsetBytes"], volume["sizeBytes"], disk["sizeBytes"]):
            if type(number) is not int or number <= 0:
                raise ValueError("Windows sharing geometry must contain positive integers")
        if (
            disk["logicalSectorSizeBytes"] not in (512, 4096)
            or volume["offsetBytes"] + volume["sizeBytes"] > disk["sizeBytes"]
        ):
            raise ValueError("Windows sharing extent or sector size is invalid")
        if not isinstance(volume["windowsDrive"], str) or not re.fullmatch(
            r"[A-Z]:", volume["windowsDrive"]
        ):
            raise ValueError("Windows sharing drive letter is invalid")
        if not isinstance(volume["windowsVolumeId"], str) or not re.fullmatch(
            r"\\\\\?\\Volume\{[0-9a-fA-F-]{36}\}\\", volume["windowsVolumeId"]
        ):
            raise ValueError("Windows sharing volume identifier is invalid")
    names, referenced = set(), set()
    for folder in folders:
        if not isinstance(folder, dict) or set(folder) != {
            "shortcut",
            "profileSid",
            "ntfsUuid",
            "relativePath",
        }:
            raise ValueError("Windows sharing folder fields are invalid")
        name, relative = folder["shortcut"], folder["relativePath"]
        if (
            not isinstance(name, str)
            or not name.startswith("User_")
            or not 5 < len(name) <= 180
            or re.search(r"[\x00-\x1f/\\]", name)
            or name.casefold() in names
        ):
            raise ValueError("Windows sharing shortcut is invalid or duplicated")
        names.add(name.casefold())
        if (
            not isinstance(relative, str)
            or not 0 < len(relative) <= 32767
            or re.search(r"[\x00-\x1f\\:]", relative)
            or any(part in {"", ".", ".."} for part in relative.split("/"))
        ):
            raise ValueError("Windows sharing relative path is invalid")
        if not isinstance(folder["profileSid"], str) or not re.fullmatch(
            r"S-1-5-21-(?:\d+-){3}\d+", folder["profileSid"]
        ):
            raise ValueError("Windows sharing profile identity is invalid")
        if folder["ntfsUuid"] not in ids:
            raise ValueError("Windows sharing folder references an unknown volume")
        referenced.add(folder["ntfsUuid"])
    if ids != referenced:
        raise ValueError("Windows sharing inventory contains unrelated volumes")
    return value


def run(*arguments: str, timeout: int = 30, allow_no_match: bool = False) -> str:
    result = subprocess.run(arguments, text=True, capture_output=True, timeout=timeout, check=False)
    if result.returncode and not (allow_no_match and result.returncode == 1):
        raise RuntimeError(
            f"Windows sharing command {arguments[0]} failed ({result.returncode}): "
            f"{result.stderr.strip()}"
        )
    return result.stdout.strip()


def expected_volume_size(plan: dict, volume: dict, observed: int, *, before_resize=False) -> bool:
    allocation = plan.get("allocation", plan["disk"])
    source = allocation.get("sourcePartition", plan["disk"]["windows"])
    if (
        allocation["partitionTableId"] == volume["disk"]["partitionTableId"]
        and source["offsetBytes"] == volume["offsetBytes"]
    ):
        # Only the explicitly selected donor can shrink. Its start and NTFS serial cannot change.
        installer = plan["disk"]["installer"]
        offsets = [installer["finalOffsetBytes"]]
        if before_resize and installer.get("offsetBytes") is not None:
            offsets.append(installer["offsetBytes"])
        return any(
            0 <= offset - volume["offsetBytes"] - observed <= PARTITION_ALIGNMENT_BYTES
            for offset in offsets
        )
    return observed == volume["sizeBytes"]


def probe_block_identity(device: str) -> dict[str, str]:
    if not Path(device).is_block_device():
        raise RuntimeError("Shared volume identity probe requires a block device")
    result = subprocess.run(
        ["blkid", "-p", "-o", "export", device],
        text=True,
        capture_output=True,
        timeout=30,
        check=False,
    )
    if result.returncode == 2:
        return {}
    if result.returncode:
        raise RuntimeError(f"Shared volume identity probe failed ({result.returncode})")
    identity = {}
    for line in result.stdout.splitlines():
        key, separator, value = line.partition("=")
        if separator and key in {"UUID", "TYPE", "PTTYPE", "PTUUID"}:
            if key in identity:
                raise RuntimeError("Shared volume identity probe returned duplicate fields")
            identity[key] = value
    return identity


def resolve_volumes(plan: dict, *, before_resize=False) -> dict[str, Path]:
    inventory = validate_sharing(plan["features"]["windowsSharing"])
    devices = json.loads(
        run("lsblk", "-J", "-b", "-o", "NAME,PATH,TYPE,SIZE,LOG-SEC,PTTYPE,PTUUID,UUID,FSTYPE")
    )["blockdevices"]
    partitions = []
    shared_table_ids = {
        volume["disk"]["partitionTableId"].split(":", 1)[1] for volume in inventory["volumes"]
    }

    def visit(node: dict, parent: dict | None = None) -> None:
        if node.get("type") == "part":
            unrelated_disk = (
                parent is not None
                and parent.get("type") == "disk"
                and parent.get("ptuuid")
                and str(parent["ptuuid"]).lower() not in shared_table_ids
            )
            # The target chroot has no udev database. Older lsblk versions return
            # null identifiers there even as root; probe the device without a cache.
            # Do not let an unreadable partition on a proven unrelated disk veto sharing.
            # Retain reported UUIDs so a visible clone still makes resolution fail closed.
            if not unrelated_disk and (not node.get("uuid") or not node.get("fstype")):
                identity = probe_block_identity(node["path"])
                node["uuid"] = identity.get("UUID")
                node["fstype"] = identity.get("TYPE")
            partitions.append((node, parent))
        for child in node.get("children", []):
            visit(child, node)

    for device in devices:
        visit(device)
    resolved = {}
    for volume in inventory["volumes"]:
        matches = [
            (part, disk)
            for part, disk in partitions
            if str(part.get("uuid", "")).upper() == volume["ntfsUuid"]
        ]
        if len(matches) != 1:
            raise RuntimeError("Shared NTFS volume is missing or duplicated")
        part, disk = matches[0]
        if (
            disk is not None
            and disk.get("type") == "disk"
            and (not disk.get("pttype") or not disk.get("ptuuid"))
        ):
            identity = probe_block_identity(disk["path"])
            disk["pttype"] = identity.get("PTTYPE")
            disk["ptuuid"] = identity.get("PTUUID")
        recorded = volume["disk"]
        expected_type = "gpt" if recorded["partitionStyle"] == "GPT" else "dos"
        if (
            disk is None
            or disk.get("type") != "disk"
            or part.get("fstype") != "ntfs"
            or disk.get("pttype") != expected_type
            or str(disk.get("ptuuid", "")).lower() != recorded["partitionTableId"].split(":", 1)[1]
            or disk.get("size") != recorded["sizeBytes"]
            or disk.get("log-sec") != recorded["logicalSectorSizeBytes"]
        ):
            raise RuntimeError("Shared volume disk identity or filesystem changed")
        device = Path(part["path"])
        if not device.is_block_device():
            raise RuntimeError("Shared volume is not a block device")
        offset = int((SYS_CLASS_BLOCK / device.name / "start").read_text()) * 512
        if offset != volume["offsetBytes"] or not expected_volume_size(
            plan, volume, part["size"], before_resize=before_resize
        ):
            raise RuntimeError("Shared volume partition geometry changed")
        resolved[volume["ntfsUuid"]] = device
    return resolved


def require_directory(root: Path, relative: str) -> Path:
    target = (root / relative).resolve(strict=True)
    if not target.is_relative_to(root.resolve()) or not target.is_dir():
        raise RuntimeError("Shared directory escapes its recorded volume or is inaccessible")
    return target


def atomic_write_text(
    path: Path,
    content: str,
    *,
    default_mode: int,
    default_uid: int,
    default_gid: int,
) -> None:
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise RuntimeError("Windows sharing output is not a regular file")
    if path.exists():
        current = path.stat()
        mode = stat.S_IMODE(current.st_mode)
        uid = current.st_uid
        gid = current.st_gid
    else:
        mode = default_mode
        uid = default_uid
        gid = default_gid
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, mode)
        os.chown(temporary, uid, gid)
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


@contextmanager
def readonly_volume(device: Path):
    mounted = run("findmnt", "-J", "-S", str(device), "-o", "TARGET,FSTYPE", allow_no_match=True)
    if mounted:
        filesystems = json.loads(mounted)["filesystems"]
        if len(filesystems) != 1 or filesystems[0]["fstype"] not in {"fuseblk", "ntfs3", "ntfs"}:
            raise RuntimeError("Existing Windows mount is ambiguous or unsupported")
        yield Path(filesystems[0]["target"])
        return
    run("ntfs-3g.probe", "--readwrite", str(device))
    with tempfile.TemporaryDirectory(prefix="libertix-sharing-", dir="/run") as directory:
        run("mount", "-t", "ntfs-3g", "-o", "ro,norecover", str(device), directory)
        try:
            yield Path(directory)
        finally:
            run("umount", directory)


def preflight(plan: dict) -> None:
    for identifier, device in resolve_volumes(plan, before_resize=True).items():
        with readonly_volume(device) as root:
            for folder in plan["features"]["windowsSharing"]["folders"]:
                if folder["ntfsUuid"] == identifier:
                    require_directory(root, folder["relativePath"])


def mount_paths(plan: dict, resolved: dict[str, Path], windows_device: Path) -> dict[str, Path]:
    return {
        identifier: Path("/mnt/windows")
        if device.resolve() == windows_device.resolve()
        else Path("/mnt/libertix-windows") / identifier
        for identifier, device in resolved.items()
    }


def configure(plan: dict, windows_device: Path) -> None:
    resolved = resolve_volumes(plan)
    mounts = mount_paths(plan, resolved, windows_device)
    account = pwd.getpwnam(plan["account"]["username"])
    home = Path(account.pw_dir)
    fstab = FSTAB_PATH
    content = fstab.read_text()
    for identifier, mount in mounts.items():
        if mount == Path("/mnt/windows"):
            continue
        mount.mkdir(parents=True, exist_ok=True)
        entry = (
            f"UUID={identifier} {mount} ntfs-3g defaults,uid={account.pw_uid},gid={account.pw_gid},"
            "dmask=022,fmask=133,windows_names,nofail 0 0"
        )
        if any(
            line.split()[1:2] == [str(mount)] and line != entry
            for line in content.splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ):
            raise RuntimeError("Windows sharing mount already has another fstab owner")
        if entry not in content.splitlines():
            content += entry + "\n"
    current = fstab.stat()
    atomic_write_text(
        fstab,
        content,
        default_mode=stat.S_IMODE(current.st_mode),
        default_uid=current.st_uid,
        default_gid=current.st_gid,
    )
    bookmarks = home / ".config/gtk-3.0/bookmarks"
    bookmarks.parent.mkdir(parents=True, exist_ok=True)
    existing = bookmarks.read_text().splitlines() if bookmarks.exists() else []
    for folder in plan["features"]["windowsSharing"]["folders"]:
        shortcut = home / folder["shortcut"]
        target = mounts[folder["ntfsUuid"]] / folder["relativePath"]
        if shortcut.is_symlink():
            if os.readlink(shortcut) != str(target):
                raise RuntimeError("Windows shortcut already points to another directory")
        elif shortcut.exists():
            raise RuntimeError("Windows shortcut would replace an existing user file")
        else:
            shortcut.symlink_to(target, target_is_directory=True)
        os.chown(shortcut, account.pw_uid, account.pw_gid, follow_symlinks=False)
        entry = f"{shortcut.as_uri()} {folder['shortcut']}"
        if entry not in existing:
            existing.append(entry)
    atomic_write_text(
        bookmarks,
        "\n".join(existing) + "\n",
        default_mode=0o644,
        default_uid=account.pw_uid,
        default_gid=account.pw_gid,
    )
    for path in (home / ".config", bookmarks.parent, bookmarks):
        os.chown(path, account.pw_uid, account.pw_gid)


def verify(plan: dict, windows_device: Path) -> dict:
    resolved = resolve_volumes(plan)
    mounts = mount_paths(plan, resolved, windows_device)
    account = pwd.getpwnam(plan["account"]["username"])
    home = Path(account.pw_dir)
    for identifier, mount in mounts.items():
        filesystems = json.loads(
            run("findmnt", "-J", "-M", str(mount), "-o", "SOURCE,FSTYPE,OPTIONS")
        )["filesystems"]
        if len(filesystems) != 1:
            raise RuntimeError("Shared volume mount is missing or ambiguous")
        filesystem = filesystems[0]
        observed = Path(filesystem["source"]).stat()
        if (
            not stat.S_ISBLK(observed.st_mode)
            or observed.st_rdev != resolved[identifier].stat().st_rdev
            or filesystem["fstype"] not in {"fuseblk", "ntfs", "ntfs3"}
            or "rw" not in filesystem["options"].split(",")
        ):
            raise RuntimeError("Shared volume mount has the wrong identity or is not writable")
    bookmarks = (home / ".config/gtk-3.0/bookmarks").read_text().splitlines()
    for folder in plan["features"]["windowsSharing"]["folders"]:
        shortcut = home / folder["shortcut"]
        mount = mounts[folder["ntfsUuid"]]
        target = mount / folder["relativePath"]
        require_directory(mount, folder["relativePath"])
        if (
            not shortcut.is_symlink()
            or os.readlink(shortcut) != str(target)
            or shortcut.lstat().st_uid != account.pw_uid
            or f"{shortcut.as_uri()} {folder['shortcut']}" not in bookmarks
        ):
            raise RuntimeError("Shared folder shortcut or bookmark is invalid")
    return {
        "enabled": True,
        "volumeCount": len(mounts),
        "profileShortcutCount": len(plan["features"]["windowsSharing"]["folders"]),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("preflight", "configure"))
    parser.add_argument("plan", type=Path)
    parser.add_argument("windows_device", nargs="?", type=Path)
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    if "windowsSharing" not in plan["features"]:
        return
    if plan["features"].get("shareWindowsFilesInLinux") is not True:
        raise ValueError("Disabled Windows sharing must not contain an inventory")
    if args.action == "preflight":
        preflight(plan)
    else:
        if args.windows_device is None:
            raise ValueError("Windows device is required")
        configure(plan, args.windows_device)


if __name__ == "__main__":
    main()
