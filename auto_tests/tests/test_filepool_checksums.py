from __future__ import annotations

import importlib.util
import json
from pathlib import Path


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
