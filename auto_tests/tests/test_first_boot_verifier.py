from __future__ import annotations

import base64
import hashlib
import importlib.util
import json
import uuid
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
ESP_GUID = "11111111-2222-3333-4444-555555555555"


def efi_boot_variable(
    description: str,
    loader_path: str,
    partition_number: int = 1,
    optional_data: bytes = b"",
) -> bytes:
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
        + optional_data
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


def test_log_checksums_cover_all_archived_diagnostics(verifier: ModuleType, tmp_path: Path) -> None:
    (tmp_path / "first-boot-verification.log").write_text("log\n", encoding="utf-8")
    (tmp_path / "first-boot-verification.json").write_text("{}\n", encoding="utf-8")

    verifier.update_log_checksums(tmp_path)

    lines = (tmp_path / "SHA256SUMS").read_text(encoding="ascii").splitlines()
    assert len(lines) == 2
    assert any(line.endswith("  first-boot-verification.log") for line in lines)
    assert any(line.endswith("  first-boot-verification.json") for line in lines)


def test_planned_linux_offset_uses_final_geometry_after_offline_resize(
    verifier: ModuleType,
) -> None:
    installer = {
        "resizeMode": "live-offline",
        "offsetBytes": 90 * 1024**3,
        "finalOffsetBytes": 70 * 1024**3,
    }

    assert verifier.planned_linux_offset(installer) == 70 * 1024**3


def test_planned_linux_offset_keeps_observed_geometry_after_windows_resize(
    verifier: ModuleType,
) -> None:
    installer = {
        "resizeMode": "windows-online",
        "offsetBytes": 70 * 1024**3,
        "finalOffsetBytes": 70 * 1024**3,
    }

    assert verifier.planned_linux_offset(installer) == 70 * 1024**3


def test_planned_linux_offset_rejects_unknown_resize_mode(verifier: ModuleType) -> None:
    installer = {
        "resizeMode": "unknown",
        "offsetBytes": 70 * 1024**3,
        "finalOffsetBytes": 70 * 1024**3,
    }

    with pytest.raises(verifier.VerificationError, match="resize mode is invalid"):
        verifier.planned_linux_offset(installer)


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


def test_uefi_boot_chain_accepts_verified_preferred_windows_path(
    verifier: ModuleType, tmp_path: Path
) -> None:
    guid = verifier.EFI_GLOBAL_VARIABLE_GUID
    (tmp_path / f"BootCurrent-{guid}").write_bytes(b"\x07\x00\x00\x00" + (1).to_bytes(2, "little"))
    (tmp_path / f"Boot0001-{guid}").write_bytes(
        efi_boot_variable("Windows Boot Manager", r"\EFI\Microsoft\Boot\bootmgfw.efi")
    )

    proof = verifier.verify_uefi_boot_current(
        tmp_path,
        expected_boot_number="0007",
        expected_partition_number=1,
        expected_partition_guid=ESP_GUID,
        preferred_path={"manifestSha256": "a" * 64, "bootNumber": "0001"},
    )

    assert proof["verified"] is True
    assert proof["type"] == "uefi-preferred-windows-path"
    assert proof["bootNumber"] == "0001"


def test_uefi_boot_chain_rejects_windows_optional_data_on_preferred_path(
    verifier: ModuleType, tmp_path: Path
) -> None:
    guid = verifier.EFI_GLOBAL_VARIABLE_GUID
    (tmp_path / f"BootCurrent-{guid}").write_bytes(b"\x07\x00\x00\x00" + (1).to_bytes(2, "little"))
    (tmp_path / f"Boot0001-{guid}").write_bytes(
        efi_boot_variable(
            "Windows Boot Manager",
            r"\EFI\Microsoft\Boot\bootmgfw.efi",
            optional_data="WINDOWS".encode("utf-16le"),
        )
    )

    with pytest.raises(verifier.VerificationError, match="does not identify"):
        verifier.verify_uefi_boot_current(
            tmp_path,
            preferred_path={"manifestSha256": "a" * 64, "bootNumber": "0001"},
        )


def test_preferred_uefi_boot_path_requires_manifest_and_file_hashes(
    verifier: ModuleType, tmp_path: Path
) -> None:
    efi_root = tmp_path / "EFI" / "Libertix"
    microsoft = tmp_path / "EFI" / "Microsoft" / "Boot"
    efi_root.mkdir(parents=True)
    microsoft.mkdir(parents=True)
    payloads = {
        "bootmgfw.efi": b"shim",
        "grubx64.efi": b"grub",
        "mmx64.efi": b"mok-manager",
        "grub.cfg": b"configfile /boot/grub/grub.cfg\n",
        "bootmgfw.libertix-windows.efi": b"windows",
    }
    hashes = {name: verifier.hashlib.sha256(value).hexdigest() for name, value in payloads.items()}
    for name, value in payloads.items():
        (microsoft / name).write_bytes(value)
    (efi_root / "secure-boot-chain.json").write_text(
        json.dumps(
            {
                "version": 1,
                "status": "not-required",
                "secureBootEnabled": False,
                "images": {
                    "shim": {"sha256": hashes["bootmgfw.efi"]},
                    "grub": {"sha256": hashes["grubx64.efi"]},
                    "mokManager": {"sha256": hashes["mmx64.efi"]},
                },
            }
        ),
        encoding="utf-8",
    )
    plan_id = "0123456789abcdef0123456789abcdef"
    preferred_entry = efi_boot_variable(
        "Windows Boot Manager", r"\EFI\Microsoft\Boot\bootmgfw.efi"
    )[4:]
    (efi_root / "preferred-boot-path.json").write_text(
        json.dumps(
            {
                "version": 1,
                "runId": plan_id,
                "status": "installed",
                "secureBootEnabled": False,
                "esp": {"partitionNumber": 1, "partitionGuid": ESP_GUID},
                "windowsLoader": {
                    "activePath": r"\EFI\Microsoft\Boot\bootmgfw.efi",
                    "backupPath": r"\EFI\Microsoft\Boot\bootmgfw.libertix-windows.efi",
                    "sha256": hashes["bootmgfw.libertix-windows.efi"],
                },
                "windowsBootEntry": {
                    "name": "Boot0001",
                    "preferredBytesBase64": base64.b64encode(preferred_entry).decode("ascii"),
                    "preferredSha256": hashlib.sha256(preferred_entry).hexdigest(),
                },
                "preferred": {
                    "shimSha256": hashes["bootmgfw.efi"],
                    "grubSha256": hashes["grubx64.efi"],
                    "mokManagerSha256": hashes["mmx64.efi"],
                    "grubConfigSha256": hashes["grub.cfg"],
                },
            }
        ),
        encoding="utf-8",
    )
    owner = {
        "bootNumber": "0007",
        "partitionNumber": 1,
        "partitionGuid": ESP_GUID,
        "loaderPath": r"\EFI\Libertix\shimx64.efi",
    }

    proof = verifier.verify_preferred_uefi_boot_path(efi_root, plan_id, owner)

    assert proof is not None
    assert proof["verifiedHashes"]["bootmgfw.efi"] == hashes["bootmgfw.efi"]
    manifest_path = efi_root / "preferred-boot-path.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    manifest["status"] = "prepared"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    with pytest.raises(verifier.VerificationError, match="identity or status"):
        verifier.verify_preferred_uefi_boot_path(efi_root, plan_id, owner)
    manifest["status"] = "installed"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    (microsoft / "grubx64.efi").write_bytes(b"corrupt")
    with pytest.raises(verifier.VerificationError, match="differs from its verified manifest"):
        verifier.verify_preferred_uefi_boot_path(efi_root, plan_id, owner)


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


def test_localization_proof_requires_exact_plan_locale_and_keyboard(
    verifier: ModuleType, tmp_path: Path
) -> None:
    locale_file = tmp_path / "locale"
    keyboard_file = tmp_path / "keyboard"
    locale_file.write_text(
        "LANG=fr_FR.UTF-8\nLC_ALL=fr_FR.UTF-8\nLANGUAGE=fr\n",
        encoding="utf-8",
    )
    keyboard_file.write_text(
        'XKBMODEL="pc105"\nXKBLAYOUT="fr"\nXKBVARIANT=""\nXKBOPTIONS=""\n',
        encoding="utf-8",
    )
    plan = {
        "locale": {
            "languageCode": "fr",
            "systemLanguage": "fr_FR.UTF-8",
            "keyboardLayout": "fr",
            "keyboardVariant": "",
            "keyboardModel": "pc105",
        }
    }

    proof = verifier.verify_localization(
        plan,
        locale_path=locale_file,
        keyboard_path=keyboard_file,
        available_locales="C\nC.utf8\nen_US.utf8\nfr_FR.utf8\nPOSIX\n",
    )

    assert proof["verified"] is True
    assert proof["compiledUtf8Locales"] == ["en_us.utf8", "fr_fr.utf8"]
    assert proof["desktopSource"] == "fr"


def test_localization_proof_rejects_an_unrequested_compiled_locale(
    verifier: ModuleType, tmp_path: Path
) -> None:
    locale_file = tmp_path / "locale"
    keyboard_file = tmp_path / "keyboard"
    locale_file.write_text(
        "LANG=fr_FR.UTF-8\nLC_ALL=fr_FR.UTF-8\nLANGUAGE=fr\n",
        encoding="utf-8",
    )
    keyboard_file.write_text(
        'XKBMODEL="pc105"\nXKBLAYOUT="fr"\nXKBVARIANT=""\nXKBOPTIONS=""\n',
        encoding="utf-8",
    )
    plan = {
        "locale": {
            "languageCode": "fr",
            "systemLanguage": "fr_FR.UTF-8",
            "keyboardLayout": "fr",
            "keyboardVariant": "",
            "keyboardModel": "pc105",
        }
    }

    with pytest.raises(verifier.VerificationError, match="compiled UTF-8 locales"):
        verifier.verify_localization(
            plan,
            locale_path=locale_file,
            keyboard_path=keyboard_file,
            available_locales="C\nen_US.utf8\nfr_FR.utf8\nes_ES.utf8\n",
        )


def test_local_success_status_retains_detailed_proofs(
    verifier: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_path = tmp_path / "first-boot-verification.json"
    monkeypatch.setattr(verifier, "LOCAL_STATUS_PATH", status_path)
    evidence = {
        "distribution": {"id": "zorin"},
        "root": {"filesystem": "ext4"},
        "system": {"dpkgAuditClean": True},
        "grub": {"syntaxValid": True},
    }

    verifier.write_local_status(
        "succeeded",
        plan={"planId": "a" * 32},
        evidence=evidence,
        windows_evidence_path=Path("/windows/installed-linux-boot.json"),
    )

    status = verifier.read_json(status_path)
    assert status["status"] == "succeeded"
    assert status["root"]["filesystem"] == "ext4"
    assert status["system"]["dpkgAuditClean"] is True
    assert status["grub"]["syntaxValid"] is True
    assert status_path.stat().st_mode & 0o777 == 0o644


def test_service_failure_is_durable_for_the_desktop_session(
    verifier: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    status_path = tmp_path / "first-boot-verification.json"
    monkeypatch.setattr(verifier, "LOCAL_STATUS_PATH", status_path)
    monkeypatch.setattr(verifier, "read_json", lambda _path: {"planId": "b" * 32})

    assert verifier.record_service_failure("resize failed") == 0
    status = json.loads(status_path.read_text(encoding="utf-8"))
    assert status["status"] == "failed"
    assert status["error"] == "resize failed"
    assert status["serviceStage"] == "first-boot-resize"


def test_service_attempt_history_detects_an_interrupted_previous_boot(
    verifier: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state_path = tmp_path / "first-boot-service-state.json"
    monkeypatch.setattr(verifier, "SERVICE_STATE_PATH", state_path)

    first_id = verifier.record_service_start("initialization")
    second_id = verifier.record_service_start("initialization")

    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert first_id != second_id
    assert state["interruptionCount"] == 1
    assert state["activeAttemptId"] == second_id
    assert state["attempts"][0]["outcome"] == "interrupted"
    assert state["attempts"][1]["outcome"] == "running"


def test_service_attempt_can_finish_after_shutdown_was_requested(
    verifier: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state_path = tmp_path / "first-boot-service-state.json"
    monkeypatch.setattr(verifier, "SERVICE_STATE_PATH", state_path)
    attempt_id = verifier.record_service_start("installed-system-verification")

    verifier.update_service_attempt(
        attempt_id,
        "installed-system-verification",
        "shutdown-requested",
    )
    verifier.update_service_attempt(attempt_id, "one-shot-service-retirement", "succeeded")

    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["status"] == "succeeded"
    assert state["activeAttemptId"] is None
    assert state["attempts"][0]["outcome"] == "succeeded"
    assert state["attempts"][0]["shutdownRequestedAtUtc"]


def test_service_attempt_can_record_a_failure_after_late_retirement_error(
    verifier: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    state_path = tmp_path / "first-boot-service-state.json"
    monkeypatch.setattr(verifier, "SERVICE_STATE_PATH", state_path)
    attempt_id = verifier.record_service_start("one-shot-service-retirement")

    verifier.update_service_attempt(attempt_id, "one-shot-service-retirement", "succeeded")
    verifier.update_service_attempt(attempt_id, "one-shot-service-retirement", "failed")

    state = json.loads(state_path.read_text(encoding="utf-8"))
    assert state["status"] == "failed"
    assert state["attempts"][0]["outcome"] == "failed"
