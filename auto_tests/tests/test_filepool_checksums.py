from __future__ import annotations

import importlib.util
import json
from pathlib import Path

REPO_ROOT = Path(__file__).parents[2]


def load_checksum_module():
    script = Path(__file__).parents[2] / "iso-tools" / "sync_filepool_checksums.py"
    spec = importlib.util.spec_from_file_location("sync_filepool_checksums", script)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def catalog(*, bios_hash: str = "0" * 64, uefi_hash: str = "1" * 64) -> dict:
    return {
        "schemaVersion": 1,
        "artifacts": {
            "miniIso": {
                "bios": {
                    "fileName": "libertix-installer-bios.iso",
                    "url": "libertix-installer-bios.iso",
                    "sha256": bios_hash,
                    "sizeBytes": 1,
                },
                "uefi": {
                    "fileName": "libertix-installer-uefi.iso",
                    "url": "libertix-installer-uefi.iso",
                    "sha256": uefi_hash,
                    "sizeBytes": 1,
                },
            }
        },
        "distributions": [{"id": "mint"}, {"id": "zorin"}],
    }


def test_checksum_sync_updates_only_supplied_artifact(tmp_path: Path) -> None:
    module = load_checksum_module()
    metadata = tmp_path / "catalog.json"
    bios_iso = tmp_path / "libertix-installer-bios.iso"
    bios_iso.write_bytes(b"verified BIOS image")
    metadata.write_text(json.dumps(catalog()), encoding="utf-8")

    module.update_metadata(metadata, bios_iso, None)

    updated = json.loads(metadata.read_text(encoding="utf-8"))["artifacts"]["miniIso"]
    assert updated["bios"]["sha256"] == module.sha256(bios_iso)
    assert updated["bios"]["sizeBytes"] == bios_iso.stat().st_size
    assert updated["uefi"]["sha256"] == "1" * 64


def test_checksum_sync_generates_metadata_without_mutating_template(tmp_path: Path) -> None:
    module = load_checksum_module()
    template = tmp_path / "template.json"
    metadata = tmp_path / "runtime" / "catalog.json"
    uefi_iso = tmp_path / "libertix-installer-uefi.iso"
    uefi_iso.write_bytes(b"verified UEFI image")
    original = json.dumps(catalog())
    template.write_text(original, encoding="utf-8")

    module.update_metadata(metadata, None, uefi_iso, template_path=template)

    assert template.read_text(encoding="utf-8") == original
    mini_iso = json.loads(metadata.read_text(encoding="utf-8"))["artifacts"]["miniIso"]
    assert mini_iso["bios"]["sha256"] == "0" * 64
    assert mini_iso["uefi"]["sha256"] == module.sha256(uefi_iso)


def test_partial_checksum_sync_preserves_other_runtime_firmware_hash(tmp_path: Path) -> None:
    module = load_checksum_module()
    template = tmp_path / "template.json"
    metadata = tmp_path / "runtime" / "catalog.json"
    bios_iso = tmp_path / "libertix-installer-bios.iso"
    bios_iso.write_bytes(b"new BIOS image")
    template.write_text(json.dumps(catalog()), encoding="utf-8")
    metadata.parent.mkdir(parents=True)
    metadata.write_text(
        json.dumps(catalog(bios_hash="2" * 64, uefi_hash="f" * 64)), encoding="utf-8"
    )

    module.update_metadata(metadata, bios_iso, None, template_path=template)

    mini_iso = json.loads(metadata.read_text(encoding="utf-8"))["artifacts"]["miniIso"]
    assert mini_iso["bios"]["sha256"] == module.sha256(bios_iso)
    assert mini_iso["uefi"]["sha256"] == "f" * 64


def test_signed_catalog_fixture_matches_the_served_catalog() -> None:
    fixture = REPO_ROOT / "Libertix.Tests" / "TestData"
    served = REPO_ROOT / "auto_tests" / "app" / "filepool"

    assert (fixture / "catalog.json").read_bytes() == (served / "catalog.json").read_bytes()
    assert (fixture / "catalog.json.sig").read_bytes() == (served / "catalog.json.sig").read_bytes()


def test_every_catalog_grub_icon_is_packaged_in_the_shared_theme() -> None:
    catalog = json.loads((REPO_ROOT / "release-config.json").read_text(encoding="utf-8"))[
        "distributions"
    ]

    assert {entry["id"] for entry in catalog} == {"mint", "zorin"}
    for entry in catalog:
        assert (REPO_ROOT / "assets/grub-theme/icons" / f"{entry['grubIcon']}.png").is_file()
