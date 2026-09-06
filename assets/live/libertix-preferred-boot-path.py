#!/usr/bin/env python3
"""Synchronize the exceptional Windows-path EFI fallback after package updates."""

from __future__ import annotations

import argparse
import base64
import binascii
import fcntl
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
import uuid
from datetime import UTC, datetime
from pathlib import Path


class PreferredBootPathError(RuntimeError):
    pass


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def efi_optional_data_length(value: bytes) -> int:
    if len(value) < 8:
        raise PreferredBootPathError("preferred Windows boot entry is too short")
    file_path_length = int.from_bytes(value[4:6], "little")
    description_end = -1
    for offset in range(6, len(value) - 1, 2):
        if value[offset : offset + 2] == b"\0\0":
            description_end = offset + 2
            break
    optional_start = description_end + file_path_length
    if description_end < 0 or optional_start > len(value):
        raise PreferredBootPathError("preferred Windows boot entry layout is invalid")
    return len(value) - optional_start


def read_manifest(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PreferredBootPathError(f"cannot read preferred boot manifest: {error}") from error
    if not isinstance(value, dict) or value.get("version") != 1:
        raise PreferredBootPathError("preferred boot manifest version is invalid")
    run_id = value.get("runId")
    if not isinstance(run_id, str) or len(run_id) != 32:
        raise PreferredBootPathError("preferred boot manifest run identifier is invalid")
    windows = value.get("windowsLoader")
    windows_entry = value.get("windowsBootEntry")
    preferred = value.get("preferred")
    if (
        not isinstance(windows, dict)
        or not isinstance(windows_entry, dict)
        or not isinstance(preferred, dict)
    ):
        raise PreferredBootPathError("preferred boot manifest payload is invalid")
    if (
        windows.get("activePath") != r"\EFI\Microsoft\Boot\bootmgfw.efi"
        or windows.get("backupPath") != r"\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi"
    ):
        raise PreferredBootPathError("preferred boot manifest contains unexpected EFI paths")
    for parent, name in (
        (windows, "sha256"),
        (preferred, "shimSha256"),
        (preferred, "grubSha256"),
        (preferred, "mokManagerSha256"),
        (preferred, "grubConfigSha256"),
    ):
        digest = parent.get(name)
        if not isinstance(digest, str) or len(digest) != 64:
            raise PreferredBootPathError(f"preferred boot manifest hash is invalid: {name}")
    entry_name = windows_entry.get("name")
    entry_hash = windows_entry.get("preferredSha256")
    entry_base64 = windows_entry.get("preferredBytesBase64")
    try:
        entry_bytes = base64.b64decode(str(entry_base64), validate=True)
    except (ValueError, TypeError, binascii.Error) as error:
        raise PreferredBootPathError("preferred Windows boot entry encoding is invalid") from error
    if (
        not isinstance(entry_name, str)
        or len(entry_name) != 8
        or not entry_name.startswith("Boot")
        or any(character not in "0123456789ABCDEF" for character in entry_name[4:])
        or not isinstance(entry_hash, str)
        or hashlib.sha256(entry_bytes).hexdigest() != entry_hash
        or efi_optional_data_length(entry_bytes) != 0
    ):
        raise PreferredBootPathError("preferred Windows boot entry contract is invalid")
    return value


def sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def write_json_atomic(path: Path, value: object) -> None:
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    with temporary.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=True, sort_keys=True, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    sync_directory(path.parent)


def replace_atomic(source: Path, destination: Path, expected_hash: str) -> None:
    if sha256(source) != expected_hash:
        raise PreferredBootPathError(f"source hash changed before staging: {source}")
    temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
    try:
        shutil.copyfile(source, temporary)
        os.chmod(temporary, 0o644)
        with temporary.open("rb") as stream:
            os.fsync(stream.fileno())
        if sha256(temporary) != expected_hash:
            raise PreferredBootPathError(f"staged hash mismatch: {destination}")
        os.replace(temporary, destination)
        sync_directory(destination.parent)
        if sha256(destination) != expected_hash:
            raise PreferredBootPathError(f"destination hash mismatch: {destination}")
    finally:
        temporary.unlink(missing_ok=True)


def verify_windows_loader(verifier: Path, loader: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="libertix-windows-loader-evidence-") as directory:
        evidence = Path(directory) / "evidence.json"
        result = subprocess.run(
            [
                str(verifier),
                "--windows-loader",
                str(loader),
                "--output",
                str(evidence),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode:
            detail = (result.stderr or result.stdout).strip()
            raise PreferredBootPathError(
                f"replacement Windows Boot Manager failed firmware trust checks: {detail}"
            )
        value = json.loads(evidence.read_text(encoding="utf-8"))
        if value.get("status") != "verified-windows-loader":
            raise PreferredBootPathError("Windows Boot Manager trust evidence is incomplete")


def archive_windows_loader(history_root: Path, loader: Path, digest: str) -> None:
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    destination = history_root / f"{timestamp}-{digest[:16]}"
    destination.mkdir(parents=True, exist_ok=False)
    os.chmod(destination, 0o700)
    archived = destination / "bootmgfw.efi"
    shutil.copyfile(loader, archived)
    os.chmod(archived, 0o600)
    if sha256(archived) != digest:
        raise PreferredBootPathError("archived Windows Boot Manager hash mismatch")
    with archived.open("rb") as stream:
        os.fsync(stream.fileno())
    sync_directory(destination)
    sync_directory(history_root)


def preferred_grub_config(source: Path, destination: Path) -> str:
    content = source.read_text(encoding="utf-8")
    if not content.strip() or "\0" in content:
        raise PreferredBootPathError("installed Libertix GRUB redirect is invalid")
    destination.write_text(
        "set libertix_windows_loader=/EFI/Microsoft/Boot/"
        "bootmgfw.libertix-windows.efi\n"
        "export libertix_windows_loader\n" + content.lstrip(),
        encoding="utf-8",
        newline="\n",
    )
    os.chmod(destination, 0o600)
    return sha256(destination)


def replay_synchronization(esp: Path, manifest_path: Path) -> None:
    journal_path = manifest_path.with_name("preferred-boot-path.sync.json")
    if not journal_path.exists():
        return
    if journal_path.is_symlink():
        raise PreferredBootPathError("pending synchronization journal is a symlink")
    journal = json.loads(journal_path.read_text(encoding="utf-8"))
    if not isinstance(journal, dict):
        raise PreferredBootPathError("pending synchronization journal is invalid")
    stage_name = journal.get("stage", "")
    if (
        journal.get("version") != 1
        or not isinstance(stage_name, str)
        or not stage_name.startswith(".preferred-sync-")
        or len(stage_name) != len(".preferred-sync-") + 32
        or any(c not in "0123456789abcdef" for c in stage_name[-32:])
    ):
        raise PreferredBootPathError("pending synchronization identity is invalid")
    stage = manifest_path.parent / stage_name
    if stage.is_symlink() or not stage.is_dir():
        raise PreferredBootPathError("pending synchronization staging directory is invalid")
    target_path = stage / "manifest.json"
    if target_path.is_symlink():
        raise PreferredBootPathError("pending synchronization manifest is a symlink")
    target = read_manifest(target_path)
    if target["runId"] != journal.get("runId"):
        raise PreferredBootPathError("pending synchronization belongs to another installation")
    if sha256(manifest_path) not in {journal.get("beforeManifest"), journal.get("afterManifest")}:
        raise PreferredBootPathError(
            "preferred manifest changed outside the pending synchronization"
        )
    if sha256(target_path) != journal.get("afterManifest"):
        raise PreferredBootPathError("pending synchronization manifest hash mismatch")
    microsoft = "EFI/Microsoft/Boot/"
    reference = "EFI/Libertix/BootGuardianReference/"
    expected = {
        microsoft + "bootmgfw.libertix-windows.efi": target["windowsLoader"]["sha256"],
        microsoft + "bootmgfw.efi": target["preferred"]["shimSha256"],
        microsoft + "grubx64.efi": target["preferred"]["grubSha256"],
        microsoft + "mmx64.efi": target["preferred"]["mokManagerSha256"],
        microsoft + "grub.cfg": target["preferred"]["grubConfigSha256"],
    }
    entries = journal.get("entries")
    if not isinstance(entries, list) or len(entries) not in (5, 9):
        raise PreferredBootPathError("pending synchronization file list is invalid")
    if len(entries) == 9:
        owner = esp / reference / ".libertix-owner"
        if owner.read_text(encoding="utf-8").strip() != target["runId"]:
            raise PreferredBootPathError("pending boot guardian reference ownership changed")
        for name, field in (
            ("shimx64.efi", "shimSha256"),
            ("grubx64.efi", "grubSha256"),
            ("mmx64.efi", "mokManagerSha256"),
            ("grub.cfg", "grubConfigSha256"),
        ):
            expected[reference + name] = target["preferred"][field]
    paths = [entry.get("target") for entry in entries if isinstance(entry, dict)]
    if (
        len(paths) != len(entries)
        or any(not isinstance(path, str) for path in paths)
        or set(paths) != set(expected)
        or len(set(paths)) != len(paths)
    ):
        raise PreferredBootPathError("pending synchronization contains unexpected destinations")
    if paths[-1] != microsoft + "bootmgfw.efi":
        raise PreferredBootPathError("pending synchronization must publish shim last")
    # Validate the complete write set before resuming any interrupted replacement.
    for index, entry in enumerate(entries):
        source = stage / str(index)
        destination = esp / entry["target"]
        if any(parent.is_symlink() for parent in (destination, *destination.parents)):
            raise PreferredBootPathError("pending synchronization destination is a symlink")
        if source.is_symlink() or sha256(source) != expected[entry["target"]]:
            raise PreferredBootPathError("pending synchronization source hash mismatch")
        current = sha256(destination) if destination.exists() else None
        if current not in (entry.get("before"), expected[entry["target"]]):
            raise PreferredBootPathError("EFI file changed outside the pending synchronization")
    for index, entry in enumerate(entries):
        replace_atomic(stage / str(index), esp / entry["target"], expected[entry["target"]])
    replace_atomic(target_path, manifest_path, journal["afterManifest"])
    journal_path.unlink()
    sync_directory(journal_path.parent)
    shutil.rmtree(stage)


def publish_synchronization(
    esp: Path, manifest_path: Path, manifest: dict, updates: list[tuple[Path, Path, str]]
) -> None:
    stage = manifest_path.parent / (".preferred-sync-" + uuid.uuid4().hex)
    stage.mkdir(mode=0o700)
    entries = []
    for index, (source, destination, expected_hash) in enumerate(updates):
        replace_atomic(source, stage / str(index), expected_hash)
        entries.append(
            {
                "target": destination.relative_to(esp).as_posix(),
                "before": sha256(destination) if destination.exists() else None,
            }
        )
    target = stage / "manifest.json"
    write_json_atomic(target, manifest)
    sync_directory(stage.parent)
    write_json_atomic(
        manifest_path.with_name("preferred-boot-path.sync.json"),
        {
            "version": 1,
            "runId": manifest["runId"],
            "stage": stage.name,
            "beforeManifest": sha256(manifest_path),
            "afterManifest": sha256(target),
            "entries": entries,
        },
    )
    replay_synchronization(esp, manifest_path)


def synchronize(args: argparse.Namespace) -> None:
    manifest = Path(args.esp) / "EFI/Libertix/preferred-boot-path.json"
    if not manifest.is_file():
        return
    lock_path = manifest.with_name("preferred-boot-path.lock")
    descriptor = os.open(lock_path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        replay_synchronization(Path(args.esp), manifest)
        synchronize_locked(args)


def synchronize_locked(args: argparse.Namespace) -> None:
    esp = Path(args.esp)
    libertix = esp / "EFI" / "Libertix"
    microsoft = esp / "EFI" / "Microsoft" / "Boot"
    manifest_path = libertix / "preferred-boot-path.json"
    if not manifest_path.is_file():
        return
    manifest = read_manifest(manifest_path)
    windows = manifest["windowsLoader"]
    preferred = manifest["preferred"]
    assert isinstance(windows, dict) and isinstance(preferred, dict)

    active_loader = microsoft / "bootmgfw.efi"
    backup_loader = microsoft / "bootmgfw.libertix-windows.efi"
    if not active_loader.is_file() or not backup_loader.is_file():
        raise PreferredBootPathError("preferred Windows boot files are incomplete")
    active_hash = sha256(active_loader)
    original_hash = str(windows["sha256"])
    previous_shim_hash = str(preferred["shimSha256"])
    if sha256(backup_loader) != original_hash:
        raise PreferredBootPathError("preferred Windows Boot Manager backup hash mismatch")

    backup_source = backup_loader
    if active_hash not in {original_hash, previous_shim_hash}:
        verify_windows_loader(Path(args.secure_boot_verifier), active_loader)
        archive_windows_loader(libertix / "WindowsBootManagerHistory", backup_loader, original_hash)
        backup_source = active_loader
        original_hash = active_hash
        windows["sha256"] = active_hash

    sources = {
        "shimSha256": libertix / "shimx64.efi",
        "grubSha256": libertix / "grubx64.efi",
        "mokManagerSha256": libertix / "mmx64.efi",
    }
    source_hashes = {name: sha256(path) for name, path in sources.items()}
    microsoft.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".libertix-preferred-", dir=microsoft) as directory:
        config = Path(directory) / "grub.cfg"
        config_hash = preferred_grub_config(libertix / "grub.cfg", config)
        updates = [
            (backup_source, backup_loader, original_hash),
            (sources["grubSha256"], microsoft / "grubx64.efi", source_hashes["grubSha256"]),
            (
                sources["mokManagerSha256"],
                microsoft / "mmx64.efi",
                source_hashes["mokManagerSha256"],
            ),
            (config, microsoft / "grub.cfg", config_hash),
        ]
        reference = libertix / "BootGuardianReference"
        if reference.exists():
            if not reference.is_dir():
                raise PreferredBootPathError("boot guardian reference path is not a directory")
            owner = reference / ".libertix-owner"
            if (
                not owner.is_file()
                or owner.read_text(encoding="utf-8").strip() != manifest["runId"]
            ):
                raise PreferredBootPathError("boot guardian reference ownership is invalid")
            updates.append(
                (
                    sources["grubSha256"],
                    reference / "grubx64.efi",
                    source_hashes["grubSha256"],
                )
            )
            updates.append(
                (
                    sources["mokManagerSha256"],
                    reference / "mmx64.efi",
                    source_hashes["mokManagerSha256"],
                )
            )
            updates.append((config, reference / "grub.cfg", config_hash))
            updates.append(
                (
                    sources["shimSha256"],
                    reference / "shimx64.efi",
                    source_hashes["shimSha256"],
                )
            )
        updates.append((sources["shimSha256"], active_loader, source_hashes["shimSha256"]))
        preferred.update(source_hashes)
        preferred["grubConfigSha256"] = config_hash
        windows["sha256"] = original_hash
        manifest["status"] = "installed"
        manifest["synchronizedUtc"] = datetime.now(UTC).isoformat()
        publish_synchronization(esp, manifest_path, manifest, updates)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--esp", default="/boot/efi")
    parser.add_argument(
        "--secure-boot-verifier",
        default="/usr/local/lib/libertix/libertix-secure-boot-chain.py",
    )
    return parser.parse_args()


def main() -> int:
    try:
        synchronize(parse_args())
    except (OSError, ValueError, json.JSONDecodeError, PreferredBootPathError) as error:
        print(f"Preferred boot path synchronization failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
