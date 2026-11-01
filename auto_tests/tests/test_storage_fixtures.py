from copy import deepcopy

import pytest
from pydantic import ValidationError

from app.errors import WorkflowError
from app.models import AutomationRequest
from app.storage_fixtures import (
    GIB,
    MIB,
    StorageFixtureInventory,
    StorageFixtureRequest,
    plan_storage_fixture,
    verify_storage_fixture_creation,
)


def inventory_data(*, secondary=False):
    data = {
        "system_drive": "C",
        "system_disk_number": 3,
        "system_min_size": 28 * GIB,
        "system_volume_healthy": True,
        "system_volume_decrypted": True,
        "used_drive_letters": ["C", "D"],
        "disks": [
            {
                "number": 3,
                "unique_id": "system-serial",
                "device_path": "system-device",
                "serial_number": "system-serial",
                "partition_table_id": "system-guid",
                "size": 64 * GIB,
                "style": "GPT",
                "bus_type": "SATA",
                "offline": False,
                "read_only": False,
                "boot": True,
                "system": True,
                "partitions": [
                    {
                        "number": 1,
                        "offset": MIB,
                        "size": 100 * MIB,
                        "drive_letter": "",
                        "type": "efi",
                        "filesystem": "FAT32",
                    },
                    {
                        "number": 2,
                        "offset": GIB,
                        "size": 60 * GIB,
                        "drive_letter": "C",
                        "type": "basic",
                        "filesystem": "NTFS",
                    },
                    {
                        "number": 3,
                        "offset": 61 * GIB,
                        "size": GIB,
                        "drive_letter": "",
                        "type": "recovery",
                        "filesystem": "NTFS",
                    },
                ],
            }
        ],
    }
    if secondary:
        data["disks"].insert(
            0,
            {
                "number": 0,
                "unique_id": "secondary-serial",
                "device_path": "secondary-device",
                "serial_number": "secondary-serial",
                "partition_table_id": "",
                "size": 64 * GIB,
                "style": "RAW",
                "bus_type": "SATA",
                "offline": False,
                "read_only": False,
                "boot": False,
                "system": False,
                "partitions": [],
            },
        )
    return data


def plan(data, *, secondary=False, **options):
    return plan_storage_fixture(
        StorageFixtureRequest(**options),
        StorageFixtureInventory.model_validate(data),
        secondary_snapshot=secondary,
    )


@pytest.mark.parametrize("kind", ["fat32", "ntfs", "recovery"])
def test_extra_partition_stays_inside_the_old_windows_extent(kind):
    data = inventory_data()
    original = deepcopy(data)
    result = plan(data, extra_system_partition=kind)
    (action,) = result["actions"]
    assert action["disk_device_path"] == "system-device"
    assert action["partition_number"] == 2
    assert action["new_system_size"] >= data["system_min_size"]
    assert action["offset"] == GIB + action["new_system_size"]
    assert action["offset"] + action["size"] < 61 * GIB
    assert action["format"] == kind
    assert data == original
    assert result["baseline"] == data


def test_secondary_fixture_selects_by_identity_and_skips_cdrom_letter():
    result = plan(inventory_data(secondary=True), secondary=True, secondary_data=True)
    assert result["actions"] == [
        {
            "kind": "secondary-data",
            "disk_device_path": "secondary-device",
            "drive_letter": "E",
        }
    ]


def test_combined_fixture_preserves_separate_system_and_secondary_identities():
    result = plan(
        inventory_data(secondary=True),
        secondary=True,
        secondary_data=True,
        extra_system_partition="recovery",
    )
    assert [a["disk_device_path"] for a in result["actions"]] == [
        "system-device",
        "secondary-device",
    ]


@pytest.mark.parametrize(
    "field,value",
    [
        ("offline", True),
        ("read_only", True),
        ("bus_type", "USB"),
        ("bus_type", "iSCSI"),
        ("bus_type", "Spaces"),
        ("boot", True),
        ("system", True),
        ("style", "GPT"),
        ("size", GIB),
    ],
)
def test_secondary_fixture_refuses_unsafe_or_nonempty_disks(field, value):
    data = inventory_data(secondary=True)
    data["disks"][0][field] = value
    with pytest.raises(WorkflowError):
        plan(data, secondary=True, secondary_data=True)


@pytest.mark.parametrize("field", ["system_volume_healthy", "system_volume_decrypted"])
def test_extra_partition_refuses_unsafe_ntfs(field):
    data = inventory_data()
    data[field] = False
    with pytest.raises(WorkflowError):
        plan(data, extra_system_partition="ntfs")


def test_encrypted_system_fixture_requires_explicit_decryption_and_reinspection():
    data = inventory_data()
    data["system_volume_decrypted"] = False
    result = plan(data, extra_system_partition="ntfs", decrypt_system_volume=True)
    assert result["requires_decryption"] is True
    data["system_volume_decrypted"] = True
    assert (
        plan(data, extra_system_partition="ntfs", decrypt_system_volume=True)["requires_decryption"]
        is False
    )


def test_decryption_permission_does_not_override_an_unhealthy_volume():
    data = inventory_data()
    data["system_volume_healthy"] = False
    with pytest.raises(WorkflowError):
        plan(data, extra_system_partition="ntfs", decrypt_system_volume=True)


def test_decryption_cannot_be_requested_for_an_unrelated_data_fixture():
    with pytest.raises(ValidationError):
        StorageFixtureRequest(secondary_data=True, decrypt_system_volume=True)


def test_secondary_decryption_requires_secondary_fixture_and_snapshot():
    with pytest.raises(ValidationError):
        StorageFixtureRequest(decrypt_secondary_volume=True)
    with pytest.raises(ValidationError):
        AutomationRequest(
            apply=True,
            linux_password="test-password",
            storage_fixture={
                "secondary_data": True,
                "decrypt_secondary_volume": True,
            },
        )
    request = AutomationRequest(
        apply=True,
        linux_password="test-password",
        snapshot_mode="secondary-disk",
        storage_fixture={"secondary_data": True, "decrypt_secondary_volume": True},
    )
    assert request.storage_fixture.decrypt_secondary_volume
    assert not StorageFixtureRequest().decrypt_secondary_volume


def test_documents_redirection_requires_an_explicit_secondary_data_fixture():
    with pytest.raises(ValidationError):
        StorageFixtureRequest(redirect_documents=True)
    with pytest.raises(ValidationError):
        AutomationRequest(
            apply=True,
            linux_password="test-password",
            storage_fixture={"secondary_data": True, "redirect_documents": True},
        )
    request = AutomationRequest(
        apply=True,
        linux_password="test-password",
        snapshot_mode="secondary-disk",
        storage_fixture={"secondary_data": True, "redirect_documents": True},
    )
    assert request.storage_fixture.redirect_documents


def test_extra_partition_refuses_insufficient_shrink_space():
    data = inventory_data()
    data["system_min_size"] = 60 * GIB
    with pytest.raises(WorkflowError):
        plan(data, extra_system_partition="ntfs")


def test_secondary_fixture_requires_explicit_alternate_snapshot():
    with pytest.raises(WorkflowError):
        plan(inventory_data(secondary=True), secondary_data=True)
    with pytest.raises(ValidationError):
        AutomationRequest(
            apply=True, linux_password="test-password", storage_fixture={"secondary_data": True}
        )


def test_fixtures_are_disabled_by_default():
    assert not AutomationRequest(apply=True, linux_password="test-password").storage_fixture.enabled


def test_inventory_refuses_duplicate_device_path_even_when_numbers_differ():
    data = inventory_data(secondary=True)
    data["disks"][0]["device_path"] = " SYSTEM-DEVICE "
    with pytest.raises(ValidationError):
        StorageFixtureInventory.model_validate(data)


@pytest.mark.parametrize("reported_id", ["ATAQEMU HARDDISK", " ataqemu harddisk "])
def test_fixture_accepts_duplicate_vendor_ids_with_distinct_device_paths(reported_id):
    data = inventory_data(secondary=True)
    for disk in data["disks"]:
        disk["unique_id"] = "ATAQEMU HARDDISK"
    data["disks"][0]["unique_id"] = reported_id
    assert plan(data, secondary=True, secondary_data=True)["actions"][0]["disk_device_path"] == (
        "secondary-device"
    )


def test_fixture_refuses_blank_partition_table_identity_before_any_actions():
    data = inventory_data()
    data["disks"][0]["partition_table_id"] = " "
    with pytest.raises(WorkflowError, match="duplicate or missing partition-table identifiers"):
        plan(data, extra_system_partition="fat32")


def test_fixture_refuses_cloned_partition_table_ids_despite_distinct_device_paths():
    data = inventory_data(secondary=True)
    data["disks"][0].update(style="GPT", partition_table_id="{SYSTEM-GUID}")
    with pytest.raises(WorkflowError, match="duplicate or missing partition-table identifiers"):
        plan(data, secondary=True, extra_system_partition="fat32")


def created_fixture():
    before = inventory_data()
    planned = plan(before, extra_system_partition="fat32")
    action = planned["actions"][0]
    after = deepcopy(before)
    parts = after["disks"][0]["partitions"]
    parts[1]["size"] = action["new_system_size"]
    parts[2]["number"] = 4
    parts.insert(
        2,
        {
            "number": 3,
            "offset": action["offset"],
            "size": action["size"],
            "drive_letter": "",
            "type": "basic",
            "filesystem": "FAT32",
        },
    )
    return before, after, planned


def test_fixture_creation_preserves_recovery_when_windows_renumbers_partitions():
    before, after, planned = created_fixture()
    verify_storage_fixture_creation(
        StorageFixtureInventory.model_validate(before),
        StorageFixtureInventory.model_validate(after),
        planned["actions"],
    )


@pytest.mark.parametrize(
    "field,value",
    [
        ("size", 512 * MIB),
        ("offset", 62 * GIB),
        ("type", "basic"),
        ("filesystem", "FAT32"),
        ("drive_letter", "R"),
    ],
)
def test_fixture_creation_rejects_unplanned_recovery_changes(field, value):
    before, after, planned = created_fixture()
    after["disks"][0]["partitions"][-1][field] = value
    with pytest.raises(WorkflowError):
        verify_storage_fixture_creation(
            StorageFixtureInventory.model_validate(before),
            StorageFixtureInventory.model_validate(after),
            planned["actions"],
        )


def test_fixture_creation_rejects_a_wrong_new_partition_filesystem():
    before, after, planned = created_fixture()
    after["disks"][0]["partitions"][2]["filesystem"] = "NTFS"
    with pytest.raises(WorkflowError, match="newly created"):
        verify_storage_fixture_creation(
            StorageFixtureInventory.model_validate(before),
            StorageFixtureInventory.model_validate(after),
            planned["actions"],
        )


def test_existing_secondary_data_volume_is_not_formatted_or_relettered():
    data = inventory_data(secondary=True)
    other = data["disks"][0]
    other["style"] = "GPT"
    other["partition_table_id"] = "secondary-guid"
    other["partitions"] = [
        {
            "number": 2,
            "offset": GIB,
            "size": 60 * GIB,
            "drive_letter": "J",
            "filesystem": "NTFS",
            "type": "basic",
        }
    ]
    result = plan(data, secondary=True, secondary_data=True)
    assert result["actions"] == [
        {
            "kind": "existing-secondary-data",
            "disk_device_path": "secondary-device",
            "partition_offset": GIB,
            "partition_size": 60 * GIB,
        }
    ]


def test_inventory_refuses_overlapping_partitions():
    data = inventory_data()
    data["disks"][0]["partitions"][2]["offset"] = 60 * GIB
    with pytest.raises(ValidationError):
        StorageFixtureInventory.model_validate(data)


def test_fixture_refuses_unexpected_disk_count():
    with pytest.raises(WorkflowError):
        plan(inventory_data(secondary=True), extra_system_partition="ntfs")
    with pytest.raises(WorkflowError):
        plan(inventory_data(), secondary=True, secondary_data=True)


def test_fixture_refuses_extended_mbr_layout():
    data = inventory_data()
    data["disks"][0]["style"] = "MBR"
    data["disks"][0]["partitions"][2]["type"] = "15"
    with pytest.raises(WorkflowError):
        plan(data, extra_system_partition="ntfs")


def test_fixture_options_reject_unknown_fields_and_invalid_sizes():
    with pytest.raises(ValidationError):
        StorageFixtureRequest(format_disk_number=0)
    for size in (0, 128, 4097, True, "1024"):
        with pytest.raises(ValidationError):
            StorageFixtureRequest(extra_partition_size_mib=size)
