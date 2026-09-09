import json
import os
import re
import shutil
import subprocess
import sys
from copy import deepcopy
from pathlib import Path
from types import SimpleNamespace

import pytest
from jsonschema import Draft202012Validator

from tests.test_installation_contracts import GIB, ROOT, load_live_module, make_plan


@pytest.fixture
def sharing():
    return load_live_module("assets/live/libertix_windows_sharing.py", "windows_sharing_test")


@pytest.fixture
def plan():
    value = make_plan("uefi", 20)
    disk = value["disk"]
    value["features"]["windowsSharing"] = {
        "version": 1,
        "volumes": [
            {
                "ntfsUuid": "0123456789ABCDEF",
                "disk": {
                    key: disk[key]
                    for key in (
                        "partitionTableId",
                        "partitionStyle",
                        "sizeBytes",
                        "logicalSectorSizeBytes",
                    )
                },
                "offsetBytes": disk["windows"]["offsetBytes"],
                "sizeBytes": disk["windows"]["sizeBytes"],
                "windowsVolumeId": "\\\\?\\Volume{11111111-1111-1111-1111-111111111111}\\",
                "windowsDrive": "C:",
            }
        ],
        "folders": [
            {
                "shortcut": "User_Alice_Documents",
                "profileSid": "S-1-5-21-1-2-3-1001",
                "ntfsUuid": "0123456789ABCDEF",
                "relativePath": "Data/Alice/Documents",
            }
        ],
    }
    return value


def test_manifest_matches_the_common_json_schema_and_live_validator(plan, sharing):
    schema = json.loads((ROOT / "schemas/installation-plan.schema.json").read_text())
    Draft202012Validator(schema).validate(plan)
    sharing.validate_sharing(plan["features"]["windowsSharing"])
    live = load_live_module("assets/live/libertix-installation-plan.py", "sharing_plan_validator")
    live.validate_plan(plan)


@pytest.mark.parametrize(
    "path",
    [
        "../Documents",
        "/Documents",
        "Data//Documents",
        "Data/./Documents",
        "D:\\Data",
        "Data\nDocuments",
        "Data/../Windows",
    ],
)
def test_rejects_paths_that_escape_the_recorded_volume(plan, sharing, path):
    plan["features"]["windowsSharing"]["folders"][0]["relativePath"] = path
    with pytest.raises(ValueError):
        sharing.validate_sharing(plan["features"]["windowsSharing"])


@pytest.mark.parametrize(
    "change",
    [
        "duplicate_volume",
        "duplicate_shortcut",
        "unknown_volume",
        "unreferenced_volume",
        "wrong_table",
        "bad_extent",
        "bad_version",
        "extra_field",
        "zero_serial",
    ],
)
def test_rejects_ambiguous_or_incomplete_manifests(plan, sharing, change):
    inventory = plan["features"]["windowsSharing"]
    if change == "duplicate_volume":
        inventory["volumes"].append(deepcopy(inventory["volumes"][0]))
    elif change == "duplicate_shortcut":
        inventory["folders"].append(deepcopy(inventory["folders"][0]))
    elif change == "unknown_volume":
        inventory["folders"][0]["ntfsUuid"] = "FFFFFFFFFFFFFFFF"
    elif change == "unreferenced_volume":
        inventory["folders"] = []
    elif change == "wrong_table":
        inventory["volumes"][0]["disk"]["partitionTableId"] = "mbr:12345678"
    elif change == "bad_extent":
        inventory["volumes"][0]["sizeBytes"] = 2**63
    elif change == "bad_version":
        inventory["version"] = True
    elif change == "extra_field":
        inventory["folders"][0]["arbitraryTarget"] = "/etc"
    elif change == "zero_serial":
        inventory["volumes"][0]["ntfsUuid"] = "0" * 16
    with pytest.raises(ValueError):
        sharing.validate_sharing(inventory)


def test_only_the_selected_donor_may_shrink(plan, sharing):
    volume = plan["features"]["windowsSharing"]["volumes"][0]
    final = plan["disk"]["installer"]["finalOffsetBytes"] - volume["offsetBytes"]
    assert sharing.expected_volume_size(plan, volume, final)
    assert not sharing.expected_volume_size(plan, volume, final - 2 * 1024**2)
    assert not sharing.expected_volume_size(plan, volume, volume["sizeBytes"])
    plan["disk"]["installer"]["offsetBytes"] = (
        plan["disk"]["installer"]["finalOffsetBytes"] + 10 * GIB
    )
    assert sharing.expected_volume_size(plan, volume, final + 10 * GIB, before_resize=True)
    assert not sharing.expected_volume_size(plan, volume, final + 10 * GIB)
    volume["disk"]["partitionTableId"] = "gpt:22222222-2222-2222-2222-222222222222"
    assert sharing.expected_volume_size(plan, volume, volume["sizeBytes"])
    assert not sharing.expected_volume_size(plan, volume, final)


@pytest.fixture
def devices(plan, sharing, monkeypatch, tmp_path):
    disk = plan["disk"]
    partition = {
        "name": "sdb3",
        "path": "/dev/sdb3",
        "type": "part",
        "fstype": "ntfs",
        "uuid": "0123456789ABCDEF",
        "size": disk["installer"]["finalOffsetBytes"] - disk["windows"]["offsetBytes"],
    }
    physical = {
        "name": "sdb",
        "path": "/dev/sdb",
        "type": "disk",
        "pttype": "gpt",
        "ptuuid": disk["partitionTableId"].split(":", 1)[1],
        "size": disk["sizeBytes"],
        "log-sec": disk["logicalSectorSizeBytes"],
        "children": [partition],
    }
    entries = [physical]
    monkeypatch.setattr(sharing, "run", lambda *args: json.dumps({"blockdevices": entries}))
    monkeypatch.setattr(Path, "is_block_device", lambda self: self.name == "sdb3")
    (tmp_path / "sdb3").mkdir()
    (tmp_path / "sdb3/start").write_text(str(disk["windows"]["offsetBytes"] // 512))
    monkeypatch.setattr(sharing, "SYS_CLASS_BLOCK", tmp_path)
    return entries, physical, partition


def test_resolves_by_filesystem_and_disk_identity_not_drive_or_device_order(plan, sharing, devices):
    assert sharing.resolve_volumes(plan) == {"0123456789ABCDEF": Path("/dev/sdb3")}


@pytest.mark.parametrize("clone", [False, True])
def test_resolves_in_target_chroot_without_udev(plan, sharing, devices, monkeypatch, clone):
    entries, disk, partition = devices
    table_id = disk["ptuuid"]
    disk.update(pttype=None, ptuuid=None)
    partition.update(uuid=None, fstype=None)
    if clone:
        entries.append(deepcopy(disk))
    probes = []

    def probe(device):
        probes.append(device)
        return (
            {"UUID": "0123456789ABCDEF", "TYPE": "ntfs"}
            if device == "/dev/sdb3"
            else {
                "PTTYPE": "gpt",
                "PTUUID": table_id,
            }
        )

    monkeypatch.setattr(sharing, "probe_block_identity", probe)
    if clone:
        with pytest.raises(RuntimeError, match="missing or duplicated"):
            sharing.resolve_volumes(plan)
    else:
        assert sharing.resolve_volumes(plan) == {"0123456789ABCDEF": Path("/dev/sdb3")}
        assert probes == ["/dev/sdb3", "/dev/sdb"]


@pytest.mark.parametrize("status", [0, 2, 4, 8])
def test_direct_probe_is_uncached_bounded_and_refuses_ambiguous_signatures(
    sharing, monkeypatch, status
):
    monkeypatch.setattr(Path, "is_block_device", lambda self: True)

    def invoke(arguments, **kwargs):
        assert arguments == ["blkid", "-p", "-o", "export", "/dev/sdb3"]
        assert kwargs == dict(text=True, capture_output=True, timeout=30, check=False)
        return SimpleNamespace(returncode=status, stdout="UUID=0123456789ABCDEF\nTYPE=ntfs\n")

    monkeypatch.setattr(sharing.subprocess, "run", invoke)
    if status in (4, 8):
        with pytest.raises(RuntimeError, match=f"failed \\({status}\\)"):
            sharing.probe_block_identity("/dev/sdb3")
    else:
        assert sharing.probe_block_identity("/dev/sdb3") == (
            {"UUID": "0123456789ABCDEF", "TYPE": "ntfs"} if status == 0 else {}
        )


@pytest.mark.parametrize("table", ["unrelated", "matching", "unknown"])
@pytest.mark.parametrize("reported_uuid", [None, "0123456789ABCDEF"])
def test_unrelated_unreadable_partition_does_not_veto_sharing(
    plan, sharing, devices, monkeypatch, table, reported_uuid
):
    entries, disk, _ = devices
    other = deepcopy(disk)
    other.update(name="sdc", path="/dev/sdc")
    other["ptuuid"] = {
        "unrelated": "22222222-2222-2222-2222-222222222222",
        "matching": disk["ptuuid"],
        "unknown": None,
    }[table]
    other["children"] = [
        {
            "name": "sdc1",
            "path": "/dev/sdc1",
            "type": "part",
            "uuid": reported_uuid,
            "fstype": None,
        }
    ]
    entries.insert(0, other)
    probes = []

    def probe(device):
        probes.append(device)
        raise RuntimeError("Shared volume identity probe failed (8)")

    monkeypatch.setattr(sharing, "probe_block_identity", probe)
    if table == "unrelated" and reported_uuid is None:
        assert sharing.resolve_volumes(plan) == {"0123456789ABCDEF": Path("/dev/sdb3")}
        assert probes == []
    else:
        with pytest.raises(RuntimeError):
            sharing.resolve_volumes(plan)
        if table != "unrelated":
            assert probes == ["/dev/sdc1"]


@pytest.mark.parametrize(
    "change",
    [
        "clone",
        "wrong_disk",
        "wrong_size",
        "wrong_sector",
        "wrong_filesystem",
        "missing",
        "unexpected_resize",
    ],
)
def test_live_resolution_refuses_changed_storage(plan, sharing, devices, change):
    entries, disk, partition = devices
    if change == "clone":
        entries.append(deepcopy(disk))
    elif change == "wrong_disk":
        disk["ptuuid"] = "22222222-2222-2222-2222-222222222222"
    elif change == "wrong_size":
        disk["size"] += 512
    elif change == "wrong_sector":
        disk["log-sec"] = 4096
    elif change == "wrong_filesystem":
        partition["fstype"] = "BitLocker"
    elif change == "missing":
        disk["children"] = []
    elif change == "unexpected_resize":
        partition["size"] -= GIB
    with pytest.raises(RuntimeError):
        sharing.resolve_volumes(plan)


def test_a_directory_symlink_cannot_escape_the_shared_volume(sharing, tmp_path):
    root = tmp_path / "volume"
    root.mkdir()
    outside = tmp_path / "unrelated"
    outside.mkdir()
    (root / "Documents").symlink_to(outside)
    with pytest.raises(RuntimeError, match="escapes"):
        sharing.require_directory(root, "Documents")


def test_configuration_preserves_unrelated_bookmarks_and_is_repeatable(
    plan, sharing, monkeypatch, tmp_path
):
    home = tmp_path / "home"
    home.mkdir()
    mount = tmp_path / "data-volume"
    (mount / "Data/Alice/Documents").mkdir(parents=True)
    bookmark = home / ".config/gtk-3.0/bookmarks"
    bookmark.parent.mkdir(parents=True)
    bookmark.write_text("file:///existing Existing\n")
    fstab = tmp_path / "fstab"
    fstab.write_text("# Existing mount table\n")
    monkeypatch.setattr(sharing, "FSTAB_PATH", fstab)
    monkeypatch.setattr(
        sharing, "resolve_volumes", lambda p: {"0123456789ABCDEF": Path("/dev/mock")}
    )
    monkeypatch.setattr(sharing, "mount_paths", lambda *args: {"0123456789ABCDEF": mount})
    monkeypatch.setattr(
        sharing.pwd,
        "getpwnam",
        lambda name: SimpleNamespace(pw_dir=str(home), pw_uid=os.getuid(), pw_gid=os.getgid()),
    )
    sharing.configure(plan, Path("/dev/windows"))
    before = fstab.read_text(), bookmark.read_text()
    sharing.configure(plan, Path("/dev/windows"))
    assert before == (fstab.read_text(), bookmark.read_text())
    assert before[1].startswith("file:///existing Existing\n")
    shortcut = home / "User_Alice_Documents"
    assert shortcut.readlink() == mount / "Data/Alice/Documents"
    assert shortcut.lstat().st_uid == os.getuid()


def test_atomic_text_write_preserves_the_original_on_publish_failure(
    sharing, monkeypatch, tmp_path
):
    target = tmp_path / "fstab"
    target.write_text("original\n")

    def fail_publish(_source, _destination):
        raise OSError("simulated publish failure")

    monkeypatch.setattr(sharing.os, "replace", fail_publish)
    with pytest.raises(OSError, match="simulated publish failure"):
        sharing.atomic_write_text(
            target,
            "replacement\n",
            default_mode=0o644,
            default_uid=os.getuid(),
            default_gid=os.getgid(),
        )

    assert target.read_text() == "original\n"
    assert list(tmp_path.glob(".fstab.*")) == []


def test_cli_keeps_the_legacy_plan_without_inventory_unchanged(sharing, tmp_path, monkeypatch):
    plan_path = tmp_path / "plan.json"
    plan_path.write_text(json.dumps(make_plan("uefi", 20)))
    monkeypatch.setattr("sys.argv", ["sharing", "preflight", str(plan_path)])
    monkeypatch.setattr(
        sharing, "run", lambda *args, **kwargs: pytest.fail("Legacy plan ran sharing commands")
    )
    sharing.main()


def test_installed_sharing_module_imports_with_only_its_packaged_dependencies(tmp_path):
    script = (ROOT / "assets/live/libertix-target-common.sh").read_text()
    script = script.replace("\\\n", " ")
    paths = re.findall(
        r"install -m \d+ /usr/local/lib/libertix/(\S+)\s+"
        r"/mnt/target/usr/local/lib/libertix/(\S+)",
        script,
    )
    for source, destination in paths:
        candidate = ROOT / "assets/live" / source
        if source == "Libertix.InstallationPolicy.json":
            candidate = ROOT / "Scripts/config" / source
        if candidate.is_file():
            shutil.copyfile(candidate, tmp_path / destination)
    result = subprocess.run(
        [
            sys.executable,
            "-I",
            "-c",
            f"import sys; sys.path.insert(0, {str(tmp_path)!r}); import libertix_windows_sharing",
        ],
        cwd=tmp_path,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stderr
