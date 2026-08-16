from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import struct
import subprocess
import uuid
from pathlib import Path
from types import ModuleType

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "assets/live/libertix-secure-boot-chain.py"
SECURITY_DATABASE_GUID = "d719b2cb-3d3a-4596-a3bc-dad00e67656f"


def load_module() -> ModuleType:
    specification = importlib.util.spec_from_file_location("secure_boot_chain", SCRIPT)
    assert specification and specification.loader
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def synthetic_pe(sbat: str) -> bytes:
    data = bytearray(0x320)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3C, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<H", data, 0x84, 0x8664)
    struct.pack_into("<H", data, 0x86, 1)
    struct.pack_into("<H", data, 0x94, 0xF0)
    optional = 0x98
    struct.pack_into("<H", data, optional, 0x20B)
    struct.pack_into("<I", data, optional + 60, 0x200)
    struct.pack_into("<I", data, optional + 108, 16)
    certificate_directory = optional + 112 + (8 * 4)
    struct.pack_into("<II", data, certificate_directory, 0x300, 0x20)
    section = optional + 0xF0
    data[section : section + 8] = b".sbat\0\0\0"
    struct.pack_into("<I", data, section + 16, 0x100)
    struct.pack_into("<I", data, section + 20, 0x200)
    encoded = sbat.encode("ascii")
    assert len(encoded) < 0x100
    data[0x200 : 0x200 + len(encoded)] = encoded
    data[0x300:0x320] = bytes(range(0x20))
    return bytes(data)


def efi_signature_list(signature_type: uuid.UUID, payloads: list[bytes]) -> bytes:
    assert payloads
    signature_size = 16 + len(payloads[0])
    assert all(len(payload) + 16 == signature_size for payload in payloads)
    entries = b"".join(
        uuid.UUID(int=index + 1).bytes_le + payload for index, payload in enumerate(payloads)
    )
    return (
        signature_type.bytes_le
        + struct.pack("<III", 28 + len(entries), 0, signature_size)
        + entries
    )


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def test_authenticode_digest_excludes_checksum_and_certificate_table() -> None:
    module = load_module()
    original = bytearray(synthetic_pe("shim,4,Vendor,shim,1,url\n"))
    checksum_changed = bytearray(original)
    checksum_changed[0xD8:0xDC] = b"test"
    certificate_changed = bytearray(original)
    certificate_changed[0x300:0x320] = b"x" * 0x20
    section_changed = bytearray(original)
    section_changed[0x220] ^= 0xFF

    expected = module.authenticode_digest(bytes(original), "sha256")
    assert module.authenticode_digest(bytes(checksum_changed), "sha256") == expected
    assert module.authenticode_digest(bytes(certificate_changed), "sha256") == expected
    assert module.authenticode_digest(bytes(section_changed), "sha256") != expected


def test_efi_signature_list_parser_separates_certificates_and_hashes() -> None:
    module = load_module()
    certificate = b"certificate"
    digest = hashlib.sha256(b"image").digest()
    data = efi_signature_list(module.EFI_CERT_X509_GUID, [certificate]) + efi_signature_list(
        uuid.UUID("c1c41626-504c-4092-aca9-41f936934328"), [digest]
    )

    certificates, hashes = module.parse_efi_signature_lists(data)

    assert certificates == [certificate]
    assert hashes["sha256"] == {digest}


def test_sbat_rejects_only_generations_below_the_firmware_minimum() -> None:
    module = load_module()
    module.assert_sbat_allowed("grub", {"grub": 4}, {"grub": 4})

    try:
        module.assert_sbat_allowed("grub", {"grub": 3}, {"grub": 4})
    except module.VerificationError as error:
        assert "below required generation 4" in str(error)
    else:
        raise AssertionError("an obsolete SBAT generation was accepted")


def secure_boot_fixture(tmp_path: Path, *, revoked_shim: bool) -> list[str]:
    efivars = tmp_path / "efivars"
    commands = tmp_path / "commands"
    efivars.mkdir()
    commands.mkdir()
    shim = tmp_path / "shim.efi"
    grub = tmp_path / "grub.efi"
    mok = tmp_path / "mm.efi"
    shim.write_bytes(synthetic_pe("shim,4,Vendor,shim,1,url\n"))
    grub.write_bytes(synthetic_pe("grub,5,Vendor,grub,1,url\n"))
    mok.write_bytes(synthetic_pe("sbat,1,SBAT,sbat,1,url\n"))
    certificate = b"fake-microsoft-2023-certificate"
    db = efi_signature_list(load_module().EFI_CERT_X509_GUID, [certificate])
    dbx = b""
    if revoked_shim:
        digest = load_module().authenticode_digest(shim.read_bytes(), "sha256")
        dbx = efi_signature_list(uuid.UUID("c1c41626-504c-4092-aca9-41f936934328"), [digest])
    (efivars / f"db-{SECURITY_DATABASE_GUID.upper()}").write_bytes(struct.pack("<I", 7) + db)
    if dbx:
        (efivars / f"dbx-{SECURITY_DATABASE_GUID}").write_bytes(struct.pack("<I", 7) + dbx)
    write_executable(commands / "sbverify", "#!/bin/sh\nexit 0\n")
    write_executable(
        commands / "openssl",
        "#!/bin/sh\nprintf 'subject=CN=Microsoft UEFI CA 2023\\n'\n",
    )
    write_executable(
        commands / "mokutil",
        "#!/bin/sh\nprintf 'shim,4\\ngrub,5\\n'\n",
    )
    return [
        "python3",
        str(SCRIPT),
        "--shim",
        str(shim),
        "--grub",
        str(grub),
        "--mok-manager",
        str(mok),
        "--authority",
        "2023",
        "--secure-boot-enabled",
        "--efivarfs",
        str(efivars),
        "--sbverify",
        str(commands / "sbverify"),
        "--openssl",
        str(commands / "openssl"),
        "--mokutil",
        str(commands / "mokutil"),
        "--output",
        str(tmp_path / "evidence.json"),
    ]


def test_secure_boot_evidence_records_verified_firmware_state(tmp_path: Path) -> None:
    command = secure_boot_fixture(tmp_path, revoked_shim=False)

    subprocess.run(command, check=True, env=os.environ.copy())

    evidence = json.loads((tmp_path / "evidence.json").read_text(encoding="utf-8"))
    assert evidence["status"] == "verified"
    assert evidence["secureBootEnabled"] is True
    assert evidence["selectedAuthority"] == "2023"
    assert evidence["images"]["shim"]["sbat"]["shim"] == 4


def test_secure_boot_evidence_refuses_a_dbx_hash(tmp_path: Path) -> None:
    command = secure_boot_fixture(tmp_path, revoked_shim=True)

    result = subprocess.run(command, capture_output=True, text=True, check=False)

    assert result.returncode != 0
    assert "shim is revoked by a firmware dbx hash" in result.stderr
    assert not (tmp_path / "evidence.json").exists()


def test_windows_loader_verification_requires_a_windows_firmware_authority(
    tmp_path: Path,
) -> None:
    efivars = tmp_path / "efivars"
    commands = tmp_path / "commands"
    efivars.mkdir()
    commands.mkdir()
    loader = tmp_path / "bootmgfw.efi"
    loader.write_bytes(synthetic_pe(""))
    certificate = b"fake-windows-2023-certificate"
    db = efi_signature_list(load_module().EFI_CERT_X509_GUID, [certificate])
    (efivars / f"db-{SECURITY_DATABASE_GUID}").write_bytes(struct.pack("<I", 7) + db)
    write_executable(commands / "sbverify", "#!/bin/sh\nexit 0\n")
    write_executable(
        commands / "openssl",
        "#!/bin/sh\nprintf 'subject=CN=Windows UEFI CA 2023\\n'\n",
    )
    evidence_path = tmp_path / "windows-loader.json"

    subprocess.run(
        [
            "python3",
            str(SCRIPT),
            "--windows-loader",
            str(loader),
            "--efivarfs",
            str(efivars),
            "--sbverify",
            str(commands / "sbverify"),
            "--openssl",
            str(commands / "openssl"),
            "--output",
            str(evidence_path),
        ],
        check=True,
    )

    evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    assert evidence["status"] == "verified-windows-loader"
    assert evidence["image"]["sha256"] == hashlib.sha256(loader.read_bytes()).hexdigest()
