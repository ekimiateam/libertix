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


def test_checksum_sync_generates_metadata_without_mutating_template(tmp_path: Path) -> None:
    module = load_checksum_module()
    template = tmp_path / "template.json"
    metadata = tmp_path / "runtime" / "distros.json"
    uefi_iso = tmp_path / "libertix-installer-uefi.iso"
    uefi_iso.write_bytes(b"verified UEFI image")
    original = json.dumps(
        [
            {
                "isoUrl": "libertix-installer-bios.iso",
                "isoSha256": "0" * 64,
                "uefiIsoUrl": uefi_iso.name,
                "uefiIsoSha256": "1" * 64,
            }
        ]
    )
    template.write_text(original, encoding="utf-8")

    module.update_metadata(metadata, None, uefi_iso, template_path=template)

    assert template.read_text(encoding="utf-8") == original
    distribution = json.loads(metadata.read_text(encoding="utf-8"))[0]
    assert distribution["isoSha256"] == "0" * 64
    assert distribution["uefiIsoSha256"] == module.sha256(uefi_iso)


def test_signed_catalog_fixture_matches_the_served_catalog() -> None:
    fixture = REPO_ROOT / "Libertix.Tests" / "TestData"
    served = REPO_ROOT / "auto_tests" / "app" / "filepool"

    assert (fixture / "distros.json").read_bytes() == (served / "distros.json").read_bytes()
    assert (fixture / "distros.json.sig").read_bytes() == (served / "distros.json.sig").read_bytes()
