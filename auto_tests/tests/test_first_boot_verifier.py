from __future__ import annotations

import importlib.util
import uuid
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
ESP_GUID = "11111111-2222-3333-4444-555555555555"


def efi_boot_variable(description: str, loader_path: str, partition_number: int = 1) -> bytes:
    hard_drive_node = (
        bytes((0x04, 0x01, 0x2A, 0x00))
        + partition_number.to_bytes(4, "little")
        + (0x800).to_bytes(8, "little")
        + (0x32000).to_bytes(8, "little")
        + uuid.UUID(ESP_GUID).bytes_le
        + bytes((0x02, 0x02))
    )
    loader_bytes = (loader_path + "\0").encode("utf-16le")
    file_path_node = (
        bytes((0x04, 0x04)) + (4 + len(loader_bytes)).to_bytes(2, "little") + loader_bytes
    )
    end_node = bytes((0x7F, 0xFF, 0x04, 0x00))
    device_path = hard_drive_node + file_path_node + end_node
    load_option = (
        (1).to_bytes(4, "little")
        + len(device_path).to_bytes(2, "little")
        + (description + "\0").encode("utf-16le")
        + device_path
    )
    return bytes((0x07, 0x00, 0x00, 0x00)) + load_option


@pytest.fixture(scope="module")
def verifier() -> ModuleType:
    path = ROOT / "assets/live/libertix-first-boot-verify.py"
    spec = importlib.util.spec_from_file_location("libertix_first_boot_verify", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_uefi_boot_chain_requires_bootcurrent_to_select_libertix(
    verifier: ModuleType, tmp_path: Path
) -> None:
    guid = verifier.EFI_GLOBAL_VARIABLE_GUID
    (tmp_path / f"BootCurrent-{guid}").write_bytes(b"\x07\x00\x00\x00" + (7).to_bytes(2, "little"))
    (tmp_path / f"Boot0007-{guid}").write_bytes(
        efi_boot_variable("Libertix", r"\EFI\Libertix\shimx64.efi")
    )

    proof = verifier.verify_uefi_boot_current(
        tmp_path,
        expected_boot_number="0007",
        expected_partition_number=1,
        expected_partition_guid=ESP_GUID,
    )

    assert proof["verified"] is True
    assert proof["type"] == "uefi-boot-current"
    assert proof["bootNumber"] == "0007"


def test_uefi_boot_chain_rejects_direct_windows_boot(verifier: ModuleType, tmp_path: Path) -> None:
    guid = verifier.EFI_GLOBAL_VARIABLE_GUID
    (tmp_path / f"BootCurrent-{guid}").write_bytes(b"\x07\x00\x00\x00" + (1).to_bytes(2, "little"))
    (tmp_path / f"Boot0001-{guid}").write_bytes(
        efi_boot_variable("Windows Boot Manager", r"\EFI\Microsoft\Boot\bootmgfw.efi")
    )

    with pytest.raises(verifier.VerificationError, match="does not identify"):
        verifier.verify_uefi_boot_current(tmp_path)


def test_uefi_owner_marker_preserves_plan_and_boot_number(
    verifier: ModuleType, tmp_path: Path
) -> None:
    marker = tmp_path / ".libertix-owner"
    plan_id = "0123456789abcdef0123456789abcdef"
    marker.write_text(
        f"{plan_id}\n0007\n1\n{ESP_GUID}\n\\EFI\\Libertix\\shimx64.efi\n",
        encoding="utf-8",
    )

    assert verifier.read_uefi_owner_marker(marker, plan_id) == {
        "bootNumber": "0007",
        "partitionNumber": 1,
        "partitionGuid": ESP_GUID,
        "loaderPath": r"\EFI\Libertix\shimx64.efi",
    }


@pytest.mark.parametrize(
    "content",
    (
        "0123456789abcdef0123456789abcdef\n",
        f"wrong-plan\n0007\n1\n{ESP_GUID}\n\\EFI\\Libertix\\shimx64.efi\n",
        f"0123456789abcdef0123456789abcdef\nnot-hex\n1\n{ESP_GUID}\n\\EFI\\Libertix\\shimx64.efi\n",
        f"0123456789abcdef0123456789abcdef\n0007\n0\n{ESP_GUID}\n\\EFI\\Libertix\\shimx64.efi\n",
        f"0123456789abcdef0123456789abcdef\n0007\n1\n{ESP_GUID}\n\\EFI\\wrong.efi\n",
    ),
)
def test_uefi_owner_marker_rejects_incomplete_or_foreign_content(
    verifier: ModuleType, tmp_path: Path, content: str
) -> None:
    marker = tmp_path / ".libertix-owner"
    marker.write_text(content, encoding="utf-8")

    with pytest.raises(verifier.VerificationError, match="ownership"):
        verifier.read_uefi_owner_marker(
            marker,
            "0123456789abcdef0123456789abcdef",
        )


def test_uefi_boot_chain_rejects_a_stale_cloned_esp(verifier: ModuleType, tmp_path: Path) -> None:
    guid = verifier.EFI_GLOBAL_VARIABLE_GUID
    (tmp_path / f"BootCurrent-{guid}").write_bytes(b"\x07\x00\x00\x00" + (7).to_bytes(2, "little"))
    (tmp_path / f"Boot0007-{guid}").write_bytes(
        efi_boot_variable("Libertix", r"\EFI\Libertix\shimx64.efi")
    )

    with pytest.raises(verifier.VerificationError, match="different ESP partition GUID"):
        verifier.verify_uefi_boot_current(
            tmp_path,
            expected_boot_number="0007",
            expected_partition_number=1,
            expected_partition_guid="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
        )


def test_bios_boot_chain_records_a_valid_mbr(verifier: ModuleType, tmp_path: Path) -> None:
    disk = tmp_path / "disk.img"
    disk.write_bytes((b"GRUB" + b"\0" * 506) + b"\x55\xaa")

    proof = verifier.verify_boot_chain("bios", disk)

    assert proof["verified"] is False
    assert proof["type"] == "bios-mbr"
    assert len(proof["currentMbrSha256"]) == 64


def test_windows_recovery_path_rejects_parent_traversal(verifier: ModuleType) -> None:
    with pytest.raises(verifier.VerificationError, match="not a safe absolute path"):
        verifier.windows_relative_path(r"C:\ProgramData\Libertix\..\escape")


def test_installed_system_proof_checks_account_packages_and_services(
    verifier: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root_uuid = "11111111-2222-3333-4444-555555555555"
    fstab = tmp_path / "fstab"
    machine_id = tmp_path / "machine-id"
    fstab.write_text(f"UUID={root_uuid} / ext4 defaults 0 1\n", encoding="utf-8")
    machine_id.write_text("a" * 32 + "\n", encoding="ascii")
    outputs = {
        ("findmnt", "-n", "-o", "OPTIONS", "/"): "rw,relatime",
        ("getent", "passwd", "test"): "test:x:1000:1000::/home/test:/bin/bash",
        ("id", "-nG", "test"): "test sudo",
        ("passwd", "-S", "test"): "test P 2026-08-11 0 99999 7 -1",
        ("visudo", "-cf", "/etc/sudoers"): "/etc/sudoers: parsed OK",
        ("dpkg", "--audit"): "",
        ("systemctl", "--failed", "--no-legend", "--plain"): "",
    }

    monkeypatch.setattr(verifier, "run", lambda *args: outputs[args])
    proof = verifier.verify_installed_system(
        {"account": {"username": "test"}},
        root_uuid,
        fstab_path=fstab,
        machine_id_path=machine_id,
    )

    assert proof["rootReadWrite"] is True
    assert proof["username"] == "test"
    assert proof["dpkgAuditClean"] is True
    assert proof["failedSystemdUnits"] == 0


def test_installed_system_proof_rejects_failed_units(
    verifier: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    root_uuid = "11111111-2222-3333-4444-555555555555"
    fstab = tmp_path / "fstab"
    machine_id = tmp_path / "machine-id"
    fstab.write_text(f"UUID={root_uuid} / ext4 defaults 0 1\n", encoding="utf-8")
    machine_id.write_text("a" * 32 + "\n", encoding="ascii")

    def fake_run(*args: str) -> str:
        if args == ("findmnt", "-n", "-o", "OPTIONS", "/"):
            return "rw,relatime"
        if args == ("id", "-nG", "test"):
            return "test sudo"
        if args == ("passwd", "-S", "test"):
            return "test P 2026-08-11 0 99999 7 -1"
        if args == ("systemctl", "--failed", "--no-legend", "--plain"):
            return "broken.service loaded failed failed"
        return ""

    monkeypatch.setattr(verifier, "run", fake_run)
    with pytest.raises(verifier.VerificationError, match="failed units"):
        verifier.verify_installed_system(
            {"account": {"username": "test"}},
            root_uuid,
            fstab_path=fstab,
            machine_id_path=machine_id,
        )
