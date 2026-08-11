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


def test_checksum_sync_updates_only_supplied_artifact(tmp_path: Path) -> None:
    module = load_checksum_module()
    metadata = tmp_path / "distros.json"
    bios_iso = tmp_path / "libertix-installer-bios.iso"
    bios_iso.write_bytes(b"verified BIOS image")
    metadata.write_text(
        json.dumps(
            [
                {
                    "isoUrl": bios_iso.name,
                    "isoSha256": "0" * 64,
                    "uefiIsoUrl": "libertix-installer-uefi.iso",
                    "uefiIsoSha256": "1" * 64,
                }
            ]
        ),
        encoding="utf-8",
    )

    module.update_metadata(metadata, bios_iso, None)

    distribution = json.loads(metadata.read_text(encoding="utf-8"))[0]
    assert distribution["isoSha256"] == module.sha256(bios_iso)
    assert distribution["uefiIsoSha256"] == "1" * 64


def test_checksum_sync_updates_every_distribution_sharing_a_generic_iso(
    tmp_path: Path,
) -> None:
    module = load_checksum_module()
    metadata = tmp_path / "distros.json"
    bios_iso = tmp_path / "libertix-installer-bios.iso"
    bios_iso.write_bytes(b"one generic BIOS image")
    metadata.write_text(
        json.dumps(
            [
                {"id": "mint", "isoUrl": bios_iso.name, "isoSha256": "0" * 64},
                {"id": "zorin", "isoUrl": bios_iso.name, "isoSha256": "1" * 64},
            ]
        ),
        encoding="utf-8",
    )

    module.update_metadata(metadata, bios_iso, None)

    distributions = json.loads(metadata.read_text(encoding="utf-8"))
    assert {entry["isoSha256"] for entry in distributions} == {module.sha256(bios_iso)}


def test_checksum_sync_generates_metadata_without_mutating_template(tmp_path: Path) -> None:
    module = load_checksum_module()
    template = tmp_path / "template.json"
    metadata = tmp_path / "runtime" / "distros.json"
    uefi_iso = tmp_path / "libertix-installer-uefi.iso"
    uefi_iso.write_bytes(b"verified UEFI image")
    original = json.dumps(
        {
            "schemaVersion": 1,
            "mainRelease": {"version": "0.1", "title": "Test", "notes": "Test"},
            "distributions": [{"id": "mint"}],
        }
    )
    template.write_text(original, encoding="utf-8")

    module.update_metadata(metadata, None, uefi_iso, template_path=template)

    assert template.read_text(encoding="utf-8") == original
    distribution = json.loads(metadata.read_text(encoding="utf-8"))[0]
    assert distribution["isoSha256"] == "0" * 64
    assert distribution["uefiIsoSha256"] == module.sha256(uefi_iso)


def test_partial_checksum_sync_preserves_other_runtime_firmware_hash(tmp_path: Path) -> None:
    module = load_checksum_module()
    template = tmp_path / "template.json"
    metadata = tmp_path / "runtime" / "distros.json"
    bios_iso = tmp_path / "libertix-installer-bios.iso"
    bios_iso.write_bytes(b"new BIOS image")
    template.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "mainRelease": {"version": "0.1", "title": "Test", "notes": "Test"},
                "distributions": [{"id": "mint"}],
            }
        ),
        encoding="utf-8",
    )
    metadata.parent.mkdir(parents=True)
    metadata.write_text(
        json.dumps(
            [
                {
                    "isoUrl": bios_iso.name,
                    "isoSha256": "2" * 64,
                    "uefiIsoUrl": "libertix-installer-uefi.iso",
                    "uefiIsoSha256": "f" * 64,
                }
            ]
        ),
        encoding="utf-8",
    )

    module.update_metadata(metadata, bios_iso, None, template_path=template)

    distribution = json.loads(metadata.read_text(encoding="utf-8"))[0]
    assert distribution["isoSha256"] == module.sha256(bios_iso)
    assert distribution["uefiIsoSha256"] == "f" * 64


def test_signed_catalog_fixture_matches_the_served_catalog() -> None:
    fixture = REPO_ROOT / "Libertix.Tests" / "TestData"
    served = REPO_ROOT / "auto_tests" / "app" / "filepool"

    assert (fixture / "distros.json").read_bytes() == (served / "distros.json").read_bytes()
    assert (fixture / "distros.json.sig").read_bytes() == (served / "distros.json.sig").read_bytes()


def test_every_catalog_grub_icon_is_packaged_in_the_shared_theme() -> None:
    catalog = json.loads((REPO_ROOT / "release-config.json").read_text(encoding="utf-8"))[
        "distributions"
    ]

    assert {entry["id"] for entry in catalog} == {"mint", "zorin"}
    for entry in catalog:
        assert (REPO_ROOT / "assets/grub-theme/icons" / f"{entry['grubIcon']}.png").is_file()
