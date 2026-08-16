#!/usr/bin/env python3
"""Verify the firmware trust and revocation state of the installed EFI chain."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import struct
import subprocess
import tempfile
import uuid
from pathlib import Path

EFI_CERT_X509_GUID = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
EFI_HASH_ALGORITHMS = {
    uuid.UUID("826ca512-cf10-4ac9-b187-be01496631bd"): "sha1",
    uuid.UUID("0b6e5233-a65c-44c9-9407-d9ab83bfd236"): "sha224",
    uuid.UUID("c1c41626-504c-4092-aca9-41f936934328"): "sha256",
    uuid.UUID("ff3e5307-9fd0-48c9-85f1-8ad56c701e01"): "sha384",
    uuid.UUID("093e0fae-a6c4-4f50-9f1b-d41e2b89c19a"): "sha512",
}
IMAGE_SECURITY_DATABASE_GUID = "d719b2cb-3d3a-4596-a3bc-dad00e67656f"


class VerificationError(RuntimeError):
    pass


def read_u16(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 2 > len(data):
        raise VerificationError("PE field exceeds the image boundary")
    return struct.unpack_from("<H", data, offset)[0]


def read_u32(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise VerificationError("binary field exceeds the input boundary")
    return struct.unpack_from("<I", data, offset)[0]


def pe_layout(data: bytes) -> dict[str, object]:
    if len(data) < 0x40 or data[:2] != b"MZ":
        raise VerificationError("EFI image does not contain a valid DOS header")
    pe_offset = read_u32(data, 0x3C)
    if pe_offset + 24 > len(data) or data[pe_offset : pe_offset + 4] != b"PE\0\0":
        raise VerificationError("EFI image does not contain a valid PE header")
    section_count = read_u16(data, pe_offset + 6)
    optional_size = read_u16(data, pe_offset + 20)
    optional_offset = pe_offset + 24
    optional_end = optional_offset + optional_size
    if optional_end > len(data):
        raise VerificationError("PE optional header exceeds the image boundary")
    magic = read_u16(data, optional_offset)
    if magic == 0x20B:
        data_directories_offset = optional_offset + 112
    elif magic == 0x10B:
        data_directories_offset = optional_offset + 96
    else:
        raise VerificationError("EFI image uses an unsupported PE optional header")
    checksum_offset = optional_offset + 64
    certificate_directory_offset = data_directories_offset + (8 * 4)
    if certificate_directory_offset + 8 > optional_end:
        raise VerificationError("PE certificate directory is missing")
    certificate_offset = read_u32(data, certificate_directory_offset)
    certificate_size = read_u32(data, certificate_directory_offset + 4)
    header_size = read_u32(data, optional_offset + 60)
    if header_size > len(data) or checksum_offset + 4 > header_size:
        raise VerificationError("PE header size is invalid")
    if certificate_size and (
        certificate_offset < header_size or certificate_offset + certificate_size > len(data)
    ):
        raise VerificationError("PE certificate table exceeds the image boundary")
    sections: list[dict[str, object]] = []
    section_offset = optional_end
    for index in range(section_count):
        current = section_offset + (40 * index)
        if current + 40 > len(data):
            raise VerificationError("PE section table exceeds the image boundary")
        raw_name = data[current : current + 8]
        name = raw_name.split(b"\0", 1)[0].decode("ascii", errors="strict")
        raw_size = read_u32(data, current + 16)
        raw_offset = read_u32(data, current + 20)
        if raw_size and (raw_offset < header_size or raw_offset + raw_size > len(data)):
            raise VerificationError(f"PE section {name!r} exceeds the image boundary")
        sections.append({"name": name, "offset": raw_offset, "size": raw_size})
    return {
        "checksum_offset": checksum_offset,
        "certificate_directory_offset": certificate_directory_offset,
        "certificate_offset": certificate_offset,
        "certificate_size": certificate_size,
        "header_size": header_size,
        "sections": sections,
    }


def authenticode_digest(data: bytes, algorithm: str) -> bytes:
    layout = pe_layout(data)
    checksum_offset = int(layout["checksum_offset"])
    certificate_directory_offset = int(layout["certificate_directory_offset"])
    header_size = int(layout["header_size"])
    certificate_offset = int(layout["certificate_offset"])
    certificate_size = int(layout["certificate_size"])
    digest = hashlib.new(algorithm)
    digest.update(data[:checksum_offset])
    digest.update(data[checksum_offset + 4 : certificate_directory_offset])
    digest.update(data[certificate_directory_offset + 8 : header_size])

    end_of_hashed_sections = header_size
    for section in sorted(layout["sections"], key=lambda item: int(item["offset"])):
        raw_offset = int(section["offset"])
        raw_size = int(section["size"])
        if not raw_size:
            continue
        digest.update(data[raw_offset : raw_offset + raw_size])
        end_of_hashed_sections = max(end_of_hashed_sections, raw_offset + raw_size)

    extra_end = certificate_offset if certificate_size else len(data)
    if extra_end < end_of_hashed_sections:
        raise VerificationError("PE certificate table overlaps hashed image data")
    digest.update(data[end_of_hashed_sections:extra_end])
    return digest.digest()


def extract_pe_section(data: bytes, name: str) -> bytes | None:
    for section in pe_layout(data)["sections"]:
        if section["name"] == name:
            offset = int(section["offset"])
            size = int(section["size"])
            return data[offset : offset + size].rstrip(b"\0")
    return None


def parse_sbat(data: bytes) -> dict[str, int]:
    section = extract_pe_section(data, ".sbat")
    if not section:
        return {}
    try:
        text = section.decode("ascii")
    except UnicodeDecodeError as error:
        raise VerificationError("EFI image contains non-ASCII SBAT metadata") from error
    result: dict[str, int] = {}
    for row in csv.reader(text.splitlines()):
        if not row or all(not value.strip() for value in row):
            continue
        if len(row) < 2 or not row[0].strip() or not row[1].strip().isdigit():
            raise VerificationError("EFI image contains invalid SBAT metadata")
        component = row[0].strip()
        generation = int(row[1].strip())
        result[component] = max(result.get(component, 0), generation)
    return result


def parse_sbat_revocations(text: str) -> dict[str, int]:
    result: dict[str, int] = {}
    for raw_line in text.replace("\x00", "").splitlines():
        line = raw_line.strip()
        if not line or line.lower().startswith("sbatlevel"):
            continue
        row = next(csv.reader([line]))
        if len(row) < 2:
            fields = line.split()
            if len(fields) < 2:
                continue
            row = fields
        component = row[0].strip()
        generation_text = row[1].strip()
        if not component or not generation_text.isdigit():
            continue
        result[component] = max(result.get(component, 0), int(generation_text))
    return result


def assert_sbat_allowed(image_name: str, metadata: dict[str, int], revoked: dict[str, int]) -> None:
    for component, minimum_generation in revoked.items():
        if component not in metadata:
            continue
        if metadata[component] < minimum_generation:
            raise VerificationError(
                f"{image_name} SBAT component {component} generation "
                f"{metadata[component]} is below required generation {minimum_generation}"
            )


def parse_efi_signature_lists(data: bytes) -> tuple[list[bytes], dict[str, set[bytes]]]:
    certificates: list[bytes] = []
    hashes = {name: set() for name in EFI_HASH_ALGORITHMS.values()}
    offset = 0
    while offset < len(data):
        if offset + 28 > len(data):
            raise VerificationError("EFI signature database has a truncated list header")
        signature_type = uuid.UUID(bytes_le=data[offset : offset + 16])
        list_size = read_u32(data, offset + 16)
        header_size = read_u32(data, offset + 20)
        signature_size = read_u32(data, offset + 24)
        if list_size < 28 or signature_size < 16 or offset + list_size > len(data):
            raise VerificationError("EFI signature database has an invalid list size")
        entries_offset = offset + 28 + header_size
        list_end = offset + list_size
        if entries_offset > list_end or (list_end - entries_offset) % signature_size:
            raise VerificationError("EFI signature database has misaligned entries")
        while entries_offset < list_end:
            payload = data[entries_offset + 16 : entries_offset + signature_size]
            if signature_type == EFI_CERT_X509_GUID:
                if not payload:
                    raise VerificationError("EFI signature database contains an empty certificate")
                certificates.append(payload)
            elif signature_type in EFI_HASH_ALGORITHMS:
                algorithm = EFI_HASH_ALGORITHMS[signature_type]
                expected_size = hashlib.new(algorithm).digest_size
                if len(payload) != expected_size:
                    raise VerificationError("EFI signature database contains an invalid hash entry")
                hashes[algorithm].add(payload)
            entries_offset += signature_size
        offset += list_size
    return certificates, hashes


def read_efi_variable(efivarfs: Path, name: str, *, required: bool) -> bytes:
    candidates = [
        path
        for path in efivarfs.glob(f"{name}-*")
        if path.name.lower() == f"{name}-{IMAGE_SECURITY_DATABASE_GUID}".lower()
    ]
    if len(candidates) != 1:
        if not candidates and not required:
            return b""
        raise VerificationError(f"firmware variable {name} is unavailable or ambiguous")
    raw = candidates[0].read_bytes()
    if len(raw) < 4:
        raise VerificationError(f"firmware variable {name} is truncated")
    return raw[4:]


def run_text(command: list[str]) -> str:
    result = subprocess.run(command, capture_output=True, text=True, check=False)
    if result.returncode:
        detail = (result.stderr or result.stdout).strip()
        raise VerificationError(f"command failed ({result.returncode}): {detail}")
    return result.stdout


def certificate_subject(openssl: str, certificate: Path) -> str:
    return run_text(
        [openssl, "x509", "-inform", "DER", "-in", str(certificate), "-noout", "-subject"]
    ).strip()


def sbverify_accepts(sbverify: str, certificate: Path, image: Path) -> bool:
    result = subprocess.run(
        [sbverify, "--cert", str(certificate), str(image)],
        capture_output=True,
        text=True,
        check=False,
    )
    return result.returncode == 0


def authority_matches(subject: str, authority: str) -> bool:
    normalized = " ".join(subject.replace(",", " ").split()).lower()
    if authority == "2011":
        return "microsoft corporation uefi ca 2011" in normalized
    if authority == "2023":
        return (
            "microsoft uefi ca 2023" in normalized
            or "microsoft corporation uefi ca 2023" in normalized
        )
    return False


def windows_authority_matches(subject: str) -> bool:
    normalized = " ".join(subject.replace(",", " ").split()).lower()
    return any(
        name in normalized
        for name in (
            "microsoft windows production pca 2011",
            "windows uefi ca 2023",
            "microsoft windows uefi ca 2023",
        )
    )


def write_json_atomic(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    with temporary.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(value, stream, ensure_ascii=True, sort_keys=True, indent=2)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def verify(args: argparse.Namespace) -> dict[str, object]:
    images = {
        "shim": Path(args.shim),
        "grub": Path(args.grub),
        "mokManager": Path(args.mok_manager),
    }
    image_bytes = {name: path.read_bytes() for name, path in images.items()}
    image_result: dict[str, object] = {}
    for name, data in image_bytes.items():
        image_result[name] = {
            "path": str(images[name]),
            "sha256": hashlib.sha256(data).hexdigest(),
            "authenticode": {
                algorithm: authenticode_digest(data, algorithm).hex()
                for algorithm in EFI_HASH_ALGORITHMS.values()
            },
            "sbat": parse_sbat(data),
        }

    if not args.secure_boot_enabled:
        return {
            "version": 1,
            "status": "not-required",
            "secureBootEnabled": False,
            "selectedAuthority": args.authority,
            "images": image_result,
        }

    efivarfs = Path(args.efivarfs)
    db = read_efi_variable(efivarfs, "db", required=True)
    dbx = read_efi_variable(efivarfs, "dbx", required=False)
    db_certificates, _db_hashes = parse_efi_signature_lists(db)
    dbx_certificates, dbx_hashes = parse_efi_signature_lists(dbx)
    sbat_output = run_text([args.mokutil, "--list-sbat-revocations"])
    sbat_revocations = parse_sbat_revocations(sbat_output)

    for image_name, data in image_bytes.items():
        for algorithm, revoked_hashes in dbx_hashes.items():
            if not revoked_hashes:
                continue
            digest = authenticode_digest(data, algorithm)
            if digest in revoked_hashes:
                raise VerificationError(f"{image_name} is revoked by a firmware dbx hash")
        metadata = image_result[image_name]["sbat"]
        if image_name in {"shim", "grub"} and not metadata:
            raise VerificationError(f"{image_name} does not contain required SBAT metadata")
        assert_sbat_allowed(image_name, metadata, sbat_revocations)

    trusted_certificate_fingerprint = ""
    with tempfile.TemporaryDirectory(prefix="libertix-secure-boot-") as directory:
        temporary_root = Path(directory)
        for index, certificate_bytes in enumerate(db_certificates):
            certificate = temporary_root / f"db-{index}.der"
            certificate.write_bytes(certificate_bytes)
            subject = certificate_subject(args.openssl, certificate)
            if authority_matches(subject, args.authority) and sbverify_accepts(
                args.sbverify, certificate, images["shim"]
            ):
                trusted_certificate_fingerprint = hashlib.sha256(certificate_bytes).hexdigest()
                break
        if not trusted_certificate_fingerprint:
            raise VerificationError(
                "installed shim is not verifiably signed by the selected firmware db authority"
            )

        for index, certificate_bytes in enumerate(dbx_certificates):
            certificate = temporary_root / f"dbx-{index}.der"
            certificate.write_bytes(certificate_bytes)
            for image_name, image in images.items():
                if sbverify_accepts(args.sbverify, certificate, image):
                    raise VerificationError(
                        f"{image_name} is revoked by a firmware dbx certificate"
                    )

    return {
        "version": 1,
        "status": "verified",
        "secureBootEnabled": True,
        "selectedAuthority": args.authority,
        "trustedCertificateSha256": trusted_certificate_fingerprint,
        "firmwareDbSha256": hashlib.sha256(db).hexdigest(),
        "firmwareDbxSha256": hashlib.sha256(dbx).hexdigest(),
        "sbatRevocationsSha256": hashlib.sha256(sbat_output.encode("utf-8")).hexdigest(),
        "sbatRevocations": sbat_revocations,
        "images": image_result,
    }


def verify_windows_loader(args: argparse.Namespace) -> dict[str, object]:
    image = Path(args.windows_loader)
    data = image.read_bytes()
    image_result = {
        "path": str(image),
        "sha256": hashlib.sha256(data).hexdigest(),
        "authenticode": {
            algorithm: authenticode_digest(data, algorithm).hex()
            for algorithm in EFI_HASH_ALGORITHMS.values()
        },
    }
    efivarfs = Path(args.efivarfs)
    db = read_efi_variable(efivarfs, "db", required=True)
    dbx = read_efi_variable(efivarfs, "dbx", required=False)
    db_certificates, _db_hashes = parse_efi_signature_lists(db)
    dbx_certificates, dbx_hashes = parse_efi_signature_lists(dbx)

    for algorithm, revoked_hashes in dbx_hashes.items():
        if authenticode_digest(data, algorithm) in revoked_hashes:
            raise VerificationError("Windows Boot Manager is revoked by a firmware dbx hash")

    trusted_certificate_fingerprint = ""
    with tempfile.TemporaryDirectory(prefix="libertix-windows-loader-") as directory:
        temporary_root = Path(directory)
        for index, certificate_bytes in enumerate(db_certificates):
            certificate = temporary_root / f"db-{index}.der"
            certificate.write_bytes(certificate_bytes)
            subject = certificate_subject(args.openssl, certificate)
            if windows_authority_matches(subject) and sbverify_accepts(
                args.sbverify, certificate, image
            ):
                trusted_certificate_fingerprint = hashlib.sha256(certificate_bytes).hexdigest()
                break
        if not trusted_certificate_fingerprint:
            raise VerificationError(
                "Windows Boot Manager is not verifiably signed by a Windows authority "
                "in firmware db"
            )

        for index, certificate_bytes in enumerate(dbx_certificates):
            certificate = temporary_root / f"dbx-{index}.der"
            certificate.write_bytes(certificate_bytes)
            if sbverify_accepts(args.sbverify, certificate, image):
                raise VerificationError(
                    "Windows Boot Manager is revoked by a firmware dbx certificate"
                )

    return {
        "version": 1,
        "status": "verified-windows-loader",
        "trustedCertificateSha256": trusted_certificate_fingerprint,
        "firmwareDbSha256": hashlib.sha256(db).hexdigest(),
        "firmwareDbxSha256": hashlib.sha256(dbx).hexdigest(),
        "image": image_result,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--shim")
    parser.add_argument("--grub")
    parser.add_argument("--mok-manager")
    parser.add_argument("--authority", choices=("2011", "2023"))
    parser.add_argument("--windows-loader")
    parser.add_argument("--secure-boot-enabled", action="store_true")
    parser.add_argument("--efivarfs", default="/sys/firmware/efi/efivars")
    parser.add_argument("--sbverify", default="sbverify")
    parser.add_argument("--mokutil", default="mokutil")
    parser.add_argument("--openssl", default="openssl")
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        if args.windows_loader:
            if any((args.shim, args.grub, args.mok_manager, args.authority)):
                raise VerificationError(
                    "Windows loader verification cannot be combined with chain verification"
                )
            result = verify_windows_loader(args)
        else:
            if not all((args.shim, args.grub, args.mok_manager, args.authority)):
                raise VerificationError(
                    "shim, grub, mok-manager, and authority are required for chain verification"
                )
            result = verify(args)
        write_json_atomic(Path(args.output), result)
    except (OSError, VerificationError, ValueError) as error:
        print(f"Secure Boot chain verification failed: {error}", file=os.sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
