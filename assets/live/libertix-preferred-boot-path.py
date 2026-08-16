#!/usr/bin/env python3
"""Synchronize the exceptional Windows-path EFI fallback after package updates."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import tempfile
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
    preferred = value.get("preferred")
    if not isinstance(windows, dict) or not isinstance(preferred, dict):
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
    return value


def write_json_atomic(path: Path, value: object) -> None:
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=True, sort_keys=True, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


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


def synchronize(args: argparse.Namespace) -> None:
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

    if active_hash not in {original_hash, previous_shim_hash}:
        verify_windows_loader(Path(args.secure_boot_verifier), active_loader)
        archive_windows_loader(libertix / "WindowsBootManagerHistory", backup_loader, original_hash)
        replace_atomic(active_loader, backup_loader, active_hash)
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
        replace_atomic(
            sources["grubSha256"],
            microsoft / "grubx64.efi",
            source_hashes["grubSha256"],
        )
        replace_atomic(
            sources["mokManagerSha256"],
            microsoft / "mmx64.efi",
            source_hashes["mokManagerSha256"],
        )
        replace_atomic(config, microsoft / "grub.cfg", config_hash)
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
            replace_atomic(
                sources["grubSha256"],
                reference / "grubx64.efi",
                source_hashes["grubSha256"],
            )
            replace_atomic(
                sources["mokManagerSha256"],
                reference / "mmx64.efi",
                source_hashes["mokManagerSha256"],
            )
            replace_atomic(config, reference / "grub.cfg", config_hash)
            replace_atomic(
                sources["shimSha256"],
                reference / "shimx64.efi",
                source_hashes["shimSha256"],
            )
        # The first-stage loader is published last so a failed synchronization
        # always leaves either the previous complete chain or the new one.
        replace_atomic(sources["shimSha256"], active_loader, source_hashes["shimSha256"])

    preferred.update(source_hashes)
    preferred["grubConfigSha256"] = config_hash
    windows["sha256"] = original_hash
    manifest["status"] = "installed"
    manifest["synchronizedUtc"] = datetime.now(UTC).isoformat()
    write_json_atomic(manifest_path, manifest)


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
