from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from tests.test_installation_contracts import GIB, load_live_module, make_plan
from tests.test_separate_allocation_plan import make_separate_allocation_plan


@pytest.fixture
def verifier():
    return load_live_module("assets/live/libertix-first-boot-verify.py", "storage_boot_verifier")


@pytest.fixture
def disks(verifier, monkeypatch, tmp_path):
    sysfs = tmp_path / "class"
    sysfs.mkdir()
    for name in ("sda", "sdb", "sdc", "sda1"):
        (sysfs / name).mkdir()
    (sysfs / "sda1/partition").write_text("1")
    monkeypatch.setattr(verifier, "BLOCK_CLASS_PATH", sysfs)
    monkeypatch.setattr(Path, "is_block_device", lambda path: path.name != "sdc")
    record = make_separate_allocation_plan()["allocation"]
    observed = {
        "sda": ["different-id", "gpt", 64 * GIB, 512],
        "sdb": [record["partitionTableId"].split(":")[1], "gpt", 64 * GIB, 512],
    }
    calls = []

    def run(*args, timeout_seconds):
        assert timeout_seconds == 15
        calls.append(args)
        values = observed[Path(args[-1]).name]
        if args[0] == "blkid":
            return values[0 if "PTUUID" in args else 1]
        assert args[0] == "blockdev"
        return str(values[2 if "--getsize64" in args else 3])

    monkeypatch.setattr(verifier, "run", run)
    return record, observed, calls


def test_disk_probe_command_timeout_is_reported(verifier, monkeypatch):
    def timeout(args, **kwargs):
        assert kwargs["timeout"] == 15
        raise subprocess.TimeoutExpired(args, 15)

    monkeypatch.setattr(verifier.subprocess, "run", timeout)
    with pytest.raises(verifier.VerificationError, match="exceeded 15 seconds"):
        verifier.run("blkid", "/dev/mock", timeout_seconds=15)


def test_disk_resolution_uses_table_identity_not_device_order(verifier, disks):
    record, _, calls = disks
    assert verifier.resolve_recorded_disk(record) == Path("/dev/sdb")
    assert all(Path(call[-1]).name in ("sda", "sdb") for call in calls)


@pytest.mark.parametrize("change", ["duplicate", "missing", "size", "sector", "style"])
def test_disk_resolution_rejects_wrong_or_ambiguous_identity(verifier, disks, change):
    record, observed, _ = disks
    if change == "duplicate":
        observed["sda"][0] = observed["sdb"][0]
        observed["sda"][2] = 128 * GIB
    elif change == "missing":
        observed["sdb"][0] = "absent"
    elif change == "style":
        observed["sdb"][1] = "dos"
    elif change == "size":
        observed["sdb"][2] += 512
    else:
        observed["sdb"][3] = 4096
    with pytest.raises(verifier.VerificationError):
        verifier.resolve_recorded_disk(record)


def test_partition_lookup_does_not_confuse_sda_and_sdaa(verifier, monkeypatch, tmp_path):
    sysfs = tmp_path / "class"
    sysfs.mkdir()
    for disk in ("sda", "sdaa"):
        partition = tmp_path / "devices" / disk / f"{disk}1"
        partition.mkdir(parents=True)
        (partition / "partition").write_text("1")
        (partition / "start").write_text("2048")
        (partition / "size").write_text("4096")
        (sysfs / partition.name).symlink_to(partition, target_is_directory=True)
    monkeypatch.setattr(verifier, "BLOCK_CLASS_PATH", sysfs)
    assert verifier.find_partition_at_offset("sda", 1048576) == (Path("/dev/sda1"), 2097152)


@pytest.mark.parametrize("separate", [False, True])
def test_installed_disk_resolution_checks_root_parent(verifier, monkeypatch, separate):
    plan = make_separate_allocation_plan() if separate else make_plan("uefi", 20)
    monkeypatch.setattr(
        verifier,
        "resolve_recorded_disk",
        lambda record: Path("/dev/sda" if record is plan["disk"] else "/dev/sdb"),
    )
    monkeypatch.setattr(verifier, "sysfs_partition_geometry", lambda _: ("sdc", 1, 0, 0))
    with pytest.raises(verifier.VerificationError, match="root is not on"):
        verifier.resolve_installed_disks(plan, Path("/dev/sdc1"))
    parent = "sdb" if separate else "sda"
    monkeypatch.setattr(verifier, "sysfs_partition_geometry", lambda _: (parent, 1, 0, 0))
    assert verifier.resolve_installed_disks(plan, Path(f"/dev/{parent}1")) == (
        Path("/dev/sda"),
        Path(f"/dev/{parent}"),
    )


@pytest.fixture
def evidence_environment(verifier, monkeypatch):
    calls = []
    monkeypatch.setattr(
        verifier, "read_json", lambda _: {"storage": {"partitionAlignmentBytes": 1048576}}
    )
    monkeypatch.setattr(verifier, "verify_installed_system", lambda *_: {})
    monkeypatch.setattr(verifier, "verify_localization", lambda *_: {})
    monkeypatch.setattr(
        verifier, "verify_windows_sharing", lambda _, device: calls.append(("sharing", device))
    )
    monkeypatch.setattr(verifier, "verify_grub", lambda _, __, disk: calls.append(("grub", disk)))

    def configure(separate):
        plan = make_separate_allocation_plan() if separate else make_plan("uefi", 20)
        plan["runtime"]["recoveryRunId"] = plan["planId"]
        windows_disk = Path("/dev/sda")
        allocation_disk = Path("/dev/sdb") if separate else windows_disk
        installer = plan["disk"]["installer"]
        windows = plan["disk"]["windows"]
        source = plan["allocation"]["sourcePartition"] if separate else windows
        offset = installer["finalOffsetBytes"]
        size = installer["finalSizeBytes"]
        geometry = {("sda", windows["offsetBytes"]): [Path("/dev/sda3"), windows["sizeBytes"]]}
        source_device = Path("/dev/sdb2") if separate else Path("/dev/sda3")
        geometry[(allocation_disk.name, source["offsetBytes"])] = [
            source_device,
            offset - source["offsetBytes"],
        ]
        monkeypatch.setattr(
            verifier, "resolve_installed_disks", lambda *_: (windows_disk, allocation_disk)
        )
        monkeypatch.setattr(
            verifier, "sysfs_partition_geometry", lambda _: (allocation_disk.name, 4, offset, size)
        )
        monkeypatch.setattr(
            verifier, "find_partition_at_offset", lambda name, start: geometry[(name, start)]
        )
        monkeypatch.setattr(
            verifier, "read_os_release", lambda: {"ID": plan["distribution"]["osReleaseId"]}
        )

        def run(*args):
            if args[0] == "blkid":
                return "root-uuid" if "UUID" in args else "ntfs"
            assert args == ("findmnt", "-n", "-o", "FSTYPE", "/")
            return "ext4"

        monkeypatch.setattr(verifier, "run", run)
        return plan, geometry, calls

    return configure


@pytest.mark.parametrize("separate", [False, True])
def test_boot_and_windows_sharing_keep_original_disk(verifier, evidence_environment, separate):
    plan, _, calls = evidence_environment(separate)
    evidence, windows_device = verifier.build_evidence(plan, Path("/dev/root"))
    assert windows_device == Path("/dev/sda3")
    assert calls == [("sharing", Path("/dev/sda3")), ("grub", Path("/dev/sda"))]
    assert evidence["root"]["sizeBytes"] == 20 * GIB


def test_separate_installation_rejects_resized_windows(verifier, evidence_environment):
    plan, geometry, _ = evidence_environment(True)
    geometry[("sda", plan["disk"]["windows"]["offsetBytes"])][1] -= GIB
    with pytest.raises(verifier.VerificationError, match="Windows size changed"):
        verifier.build_evidence(plan, Path("/dev/root"))


@pytest.mark.parametrize("separate", [False, True])
@pytest.mark.parametrize("delta", [-2 * 1048576, 1048576])
def test_source_geometry_must_end_before_linux(verifier, evidence_environment, separate, delta):
    plan, geometry, _ = evidence_environment(separate)
    source = plan["allocation"]["sourcePartition"] if separate else plan["disk"]["windows"]
    geometry[("sdb" if separate else "sda", source["offsetBytes"])][1] += delta
    with pytest.raises(verifier.VerificationError, match="unexpected gap"):
        verifier.build_evidence(plan, Path("/dev/root"))
