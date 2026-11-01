import hashlib
import importlib.util
import json
from pathlib import Path
from types import SimpleNamespace

import pytest


@pytest.fixture
def evidence(tmp_path, monkeypatch):
    source = Path(__file__).parents[1] / "app/scripts/check_linux_redirected_documents.py"
    spec = importlib.util.spec_from_file_location("redirected_documents_check", source)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    home = tmp_path / "home"
    home.mkdir()
    data = tmp_path / "data" / "Documents"
    data.mkdir(parents=True)
    shortcut = home / "User_test_Documents"
    shortcut.symlink_to(data)
    name = "libertix-user-data-" + "a" * 32 + ".txt"
    content = b"Only on the secondary volume"
    (data / name).write_bytes(content)
    receipt = {
        "destination": "D:\\Data\\Documents",
        "volume_id": "windows-volume",
        "user_sid": "sid",
        "witness": {"relative": name, "sha256": hashlib.sha256(content).hexdigest()},
    }
    plan = {
        "account": {"username": "test"},
        "features": {
            "windowsSharing": {
                "volumes": [{"windowsVolumeId": "windows-volume", "ntfsUuid": "0123456789ABCDEF"}],
                "folders": [
                    {
                        "profileSid": "sid",
                        "ntfsUuid": "0123456789ABCDEF",
                        "relativePath": "Data/Documents",
                        "shortcut": shortcut.name,
                    }
                ],
            }
        },
    }
    metadata = {"uuid": "0123456789ABCDEF", "fstype": "fuseblk", "options": "rw,nosuid"}
    monkeypatch.setattr(module.pwd, "getpwnam", lambda name: SimpleNamespace(pw_dir=str(home)))
    monkeypatch.setattr(
        module.subprocess,
        "run",
        lambda *a, **kw: SimpleNamespace(stdout=json.dumps({"filesystems": [metadata]})),
    )
    return module, plan, receipt, data, metadata


def test_reads_the_windows_only_witness_through_the_actual_linux_shortcut(evidence):
    module, plan, receipt, _, _ = evidence
    module.verify(plan, receipt)


@pytest.mark.parametrize(
    "change",
    [
        "wrong-volume",
        "wrong-filesystem",
        "readonly",
        "changed-data",
        "missing-data",
        "wrong-path",
        "missing-manifest-folder",
    ],
)
def test_does_not_accept_a_green_result_without_redirected_data_access(evidence, change):
    module, plan, receipt, data, metadata = evidence
    if change == "wrong-volume":
        metadata["uuid"] = "FFFFFFFFFFFFFFFF"
    elif change == "wrong-filesystem":
        metadata["fstype"] = "ext4"
    elif change == "readonly":
        metadata["options"] = "ro"
    elif change == "changed-data":
        (data / receipt["witness"]["relative"]).write_bytes(b"changed")
    elif change == "missing-data":
        receipt["witness"]["relative"] = "libertix-user-data-" + "b" * 32 + ".txt"
    elif change == "wrong-path":
        plan["features"]["windowsSharing"]["folders"][0]["relativePath"] = "Users/test/Documents"
    elif change == "missing-manifest-folder":
        plan["features"]["windowsSharing"]["folders"] = []
    with pytest.raises((ValueError, FileNotFoundError)):
        module.verify(plan, receipt)
