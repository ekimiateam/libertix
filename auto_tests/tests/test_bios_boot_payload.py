from __future__ import annotations

import hashlib
import importlib.util
import json
from pathlib import Path

import pytest

HELPER = Path(__file__).resolve().parents[2] / "assets/live/libertix-bios-boot-payload.py"


@pytest.fixture
def payload(tmp_path: Path):
    spec = importlib.util.spec_from_file_location("bios_boot_payload", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    files = {name: hashlib.sha256(name.encode()).hexdigest() for name in module.NAMES}
    for name in files:
        (tmp_path / name).write_text(name)
    manifest_path = tmp_path / "LibertixInstallRecovery/bios-boot-payload.json"
    manifest_path.parent.mkdir()
    manifest = {"version": 1, "planId": "a" * 32, "files": files}
    manifest_path.write_text(json.dumps(manifest))
    return module, tmp_path, manifest_path, manifest


def test_owned_cleanup_is_replayable_and_preserves_other_files(payload):
    module, root, _, _ = payload
    other = root / "foreign-boot.efi"
    other.write_text("foreign")
    (root / "grldr").unlink()
    module.remove_payload(root, "a" * 32)
    module.remove_payload(root, "a" * 32)
    assert other.read_text() == "foreign"
    assert all(not (root / name).exists() for name in module.NAMES)


@pytest.mark.parametrize(
    "fault", ["foreign-run", "extra-file", "bad-hash", "modified-file", "symlink"]
)
def test_unproven_cleanup_never_partially_removes_files(payload, fault):
    module, root, manifest_path, manifest = payload
    if fault == "foreign-run":
        manifest["planId"] = "b" * 32
    elif fault == "extra-file":
        manifest["files"]["../foreign"] = "a" * 64
    elif fault == "bad-hash":
        manifest["files"]["menu.lst"] = "wrong"
    elif fault == "modified-file":
        (root / "menu.lst").write_text("foreign")
    else:
        (root / "menu.lst").unlink()
        (root / "menu.lst").symlink_to(root / "grldr")
    manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(ValueError):
        module.remove_payload(root, "a" * 32)
    assert all((root / name).exists() for name in module.NAMES)


def test_missing_manifest_preserves_preexisting_boot_files(payload):
    module, root, manifest_path, _ = payload
    manifest_path.unlink()
    with pytest.raises(FileNotFoundError):
        module.remove_payload(root, "a" * 32)
    assert all((root / name).exists() for name in module.NAMES)
