from __future__ import annotations

import base64
import hashlib
import json
import subprocess
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "assets/live/libertix-preferred-boot-path.py"
ESP_GUID = "11111111-2222-3333-4444-555555555555"


def digest(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def write(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(value)


def efi_load_option(description: str, loader_path: str) -> bytes:
    hard_drive_node = (
        bytes((0x04, 0x01, 0x2A, 0x00))
        + (1).to_bytes(4, "little")
        + (0x800).to_bytes(8, "little")
        + (0x32000).to_bytes(8, "little")
        + uuid.UUID(ESP_GUID).bytes_le
        + bytes((0x02, 0x02))
    )
    loader_bytes = (loader_path + "\0").encode("utf-16le")
    file_path_node = (
        bytes((0x04, 0x04)) + (4 + len(loader_bytes)).to_bytes(2, "little") + loader_bytes
    )
    device_path = hard_drive_node + file_path_node + bytes((0x7F, 0xFF, 0x04, 0x00))
    return (
        (1).to_bytes(4, "little")
        + len(device_path).to_bytes(2, "little")
        + (description + "\0").encode("utf-16le")
        + device_path
    )


def fixture(tmp_path: Path) -> tuple[Path, Path]:
    esp = tmp_path / "esp"
    libertix = esp / "EFI" / "Libertix"
    microsoft = esp / "EFI" / "Microsoft" / "Boot"
    old_shim = b"old-shim"
    windows = b"windows-loader"
    write(libertix / "shimx64.efi", b"new-shim")
    write(libertix / "grubx64.efi", b"new-grub")
    write(libertix / "mmx64.efi", b"new-mm")
    write(libertix / "grub.cfg", b"configfile /boot/grub/grub.cfg\n")
    write(microsoft / "bootmgfw.efi", old_shim)
    write(microsoft / "bootmgfw.libertix-windows.efi", windows)
    preferred_entry = efi_load_option("Windows Boot Manager", r"\EFI\Microsoft\Boot\bootmgfw.efi")
    manifest = {
        "version": 1,
        "runId": "a" * 32,
        "status": "installed",
        "windowsLoader": {
            "activePath": r"\EFI\Microsoft\Boot\bootmgfw.efi",
            "backupPath": r"\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi",
            "sha256": digest(windows),
        },
        "windowsBootEntry": {
            "name": "Boot0001",
            "preferredBytesBase64": base64.b64encode(preferred_entry).decode("ascii"),
            "preferredSha256": digest(preferred_entry),
        },
        "preferred": {
            "shimSha256": digest(old_shim),
            "grubSha256": digest(b"old-grub"),
            "mokManagerSha256": digest(b"old-mm"),
            "grubConfigSha256": digest(b"old-config"),
        },
    }
    (libertix / "preferred-boot-path.json").write_text(json.dumps(manifest), encoding="utf-8")
    verifier = tmp_path / "verifier"
    verifier.write_text(
        "#!/bin/sh\n"
        "while [ $# -gt 0 ]; do\n"
        '  if [ "$1" = --output ]; then shift; output=$1; fi\n'
        "  shift\n"
        "done\n"
        'printf \'{"status":"verified-windows-loader"}\\n\' > "$output"\n',
        encoding="utf-8",
    )
    verifier.chmod(0o755)
    return esp, verifier


def synchronize(esp: Path, verifier: Path) -> None:
    subprocess.run(
        [
            "python3",
            str(HELPER),
            "--esp",
            str(esp),
            "--secure-boot-verifier",
            str(verifier),
        ],
        check=True,
    )


def test_sync_publishes_a_complete_preferred_chain_with_shim_last(tmp_path: Path) -> None:
    esp, verifier = fixture(tmp_path)

    synchronize(esp, verifier)

    microsoft = esp / "EFI" / "Microsoft" / "Boot"
    assert (microsoft / "bootmgfw.efi").read_bytes() == b"new-shim"
    assert (microsoft / "grubx64.efi").read_bytes() == b"new-grub"
    assert (microsoft / "mmx64.efi").read_bytes() == b"new-mm"
    assert (microsoft / "bootmgfw.libertix-windows.efi").read_bytes() == b"windows-loader"
    preferred_config = (microsoft / "grub.cfg").read_text(encoding="utf-8")
    assert "bootmgfw.libertix-windows.efi" in preferred_config
    assert "export libertix_windows_loader" in preferred_config


def test_sync_refreshes_existing_boot_guardian_repair_references(tmp_path: Path) -> None:
    esp, verifier = fixture(tmp_path)
    reference = esp / "EFI" / "Libertix" / "BootGuardianReference"
    reference.mkdir()
    (reference / ".libertix-owner").write_text("a" * 32 + "\n", encoding="utf-8")
    for name in ("shimx64.efi", "grubx64.efi", "mmx64.efi", "grub.cfg"):
        write(reference / name, b"stale")

    synchronize(esp, verifier)

    assert (reference / "shimx64.efi").read_bytes() == b"new-shim"
    assert (reference / "grubx64.efi").read_bytes() == b"new-grub"
    assert (reference / "mmx64.efi").read_bytes() == b"new-mm"
    config = (reference / "grub.cfg").read_text(encoding="utf-8")
    assert "bootmgfw.libertix-windows.efi" in config


def test_sync_preserves_a_verified_windows_update_before_reinstalling_shim(
    tmp_path: Path,
) -> None:
    esp, verifier = fixture(tmp_path)
    synchronize(esp, verifier)
    microsoft = esp / "EFI" / "Microsoft" / "Boot"
    write(microsoft / "bootmgfw.efi", b"updated-windows-loader")

    synchronize(esp, verifier)

    assert (microsoft / "bootmgfw.efi").read_bytes() == b"new-shim"
    assert (microsoft / "bootmgfw.libertix-windows.efi").read_bytes() == b"updated-windows-loader"
    history = list((esp / "EFI" / "Libertix" / "WindowsBootManagerHistory").glob("*/bootmgfw.efi"))
    assert len(history) == 1
    assert history[0].read_bytes() == b"windows-loader"
    manifest = json.loads(
        (esp / "EFI" / "Libertix" / "preferred-boot-path.json").read_text(encoding="utf-8")
    )
    assert manifest["windowsLoader"]["sha256"] == digest(b"updated-windows-loader")
