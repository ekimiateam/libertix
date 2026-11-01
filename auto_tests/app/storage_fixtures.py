from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

from app.errors import WorkflowError

GIB = 1024**3
MIB = 1024**2


class StorageFixtureRequest(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    extra_system_partition: Literal["none", "fat32", "ntfs", "recovery"] = "none"
    extra_partition_size_mib: int = Field(default=1024, ge=256, le=4096, strict=True)
    secondary_data: bool = False
    decrypt_system_volume: bool = False
    decrypt_secondary_volume: bool = False
    redirect_documents: bool = False

    @model_validator(mode="after")
    def validate_decryption_scope(self) -> StorageFixtureRequest:
        if self.decrypt_system_volume and self.extra_system_partition == "none":
            raise ValueError("Fixture decryption requires an extra system partition scenario")
        if self.decrypt_secondary_volume and not self.secondary_data:
            raise ValueError("Secondary decryption requires the secondary data fixture")
        if self.redirect_documents and not self.secondary_data:
            raise ValueError("Document redirection requires the secondary data fixture")
        return self

    @property
    def enabled(self) -> bool:
        return self.extra_system_partition != "none" or self.secondary_data


class FixturePartition(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    number: int = Field(ge=1, strict=True)
    offset: int = Field(ge=0, strict=True)
    size: int = Field(gt=0, strict=True)
    drive_letter: str
    type: str
    filesystem: str


class FixtureDisk(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    number: int = Field(ge=0, strict=True)
    unique_id: str = Field(min_length=1)
    device_path: str = Field(min_length=1)
    serial_number: str
    partition_table_id: str
    size: int = Field(gt=0, strict=True)
    style: Literal["GPT", "MBR", "RAW"]
    bus_type: str
    offline: bool
    read_only: bool
    boot: bool
    system: bool
    partitions: tuple[FixturePartition, ...]

    @model_validator(mode="after")
    def validate_partitions(self) -> FixtureDisk:
        parts = sorted(self.partitions, key=lambda part: part.offset)
        if len({part.number for part in parts}) != len(parts):
            raise ValueError("Duplicate partition number")
        end = 0
        for part in parts:
            if part.offset < end or part.offset + part.size > self.size:
                raise ValueError("Overlapping or out-of-range partition")
            end = part.offset + part.size
        if self.style == "RAW" and parts:
            raise ValueError("RAW disk contains partitions")
        return self


class StorageFixtureInventory(BaseModel):
    model_config = ConfigDict(extra="forbid", frozen=True)

    system_drive: str = Field(pattern=r"^[A-Z]$")
    system_disk_number: int = Field(ge=0, strict=True)
    disks: tuple[FixtureDisk, ...] = Field(min_length=1)
    system_min_size: int = Field(gt=0, strict=True)
    system_volume_healthy: bool
    system_volume_decrypted: bool
    used_drive_letters: tuple[str, ...]

    @model_validator(mode="after")
    def validate_identities(self) -> StorageFixtureInventory:
        if len({disk.number for disk in self.disks}) != len(self.disks):
            raise ValueError("Duplicate disk number")
        identities = {disk.device_path.strip().casefold() for disk in self.disks}
        if "" in identities or len(identities) != len(self.disks):
            raise ValueError("Missing or duplicate disk device path")
        system = [disk for disk in self.disks if disk.number == self.system_disk_number]
        if len(system) != 1:
            raise ValueError("System disk is absent")
        volumes = [
            (disk, part)
            for disk in self.disks
            for part in disk.partitions
            if part.drive_letter.upper() == self.system_drive
        ]
        if len(volumes) != 1 or volumes[0][0].number != self.system_disk_number:
            raise ValueError("Ambiguous system volume")
        return self


def plan_storage_fixture(
    request: StorageFixtureRequest,
    inventory: StorageFixtureInventory,
    *,
    secondary_snapshot: bool,
) -> dict[str, object]:
    """Plan only mutations to a freshly restored, explicitly selected test baseline."""

    def reject(message: str) -> None:
        raise WorkflowError("automation.storage_fixture.plan", message)

    if not request.enabled:
        reject("No storage fixture was requested")
    if request.secondary_data and not secondary_snapshot:
        reject("A secondary-data fixture requires the secondary-disk snapshot mode")
    if len(inventory.disks) != (2 if secondary_snapshot else 1):
        reject("The restored test baseline has an unexpected disk count")
    table_ids = [
        (disk.style, disk.partition_table_id.strip().strip("{}").casefold())
        for disk in inventory.disks
        if disk.style != "RAW"
    ]
    if any(not identity for _, identity in table_ids) or len(set(table_ids)) != len(table_ids):
        reject("The test baseline reports duplicate or missing partition-table identifiers")
    for disk in inventory.disks:
        if disk.offline or disk.read_only or disk.bus_type not in {"SATA", "SCSI", "ATA", "NVMe"}:
            reject("The test fixture requires online writable local basic disks")

    system = next(d for d in inventory.disks if d.number == inventory.system_disk_number)
    windows = next(p for p in system.partitions if p.drive_letter == inventory.system_drive)
    plan: dict[str, object] = {
        "baseline": inventory.model_dump(mode="json"),
        "actions": [],
        "requires_decryption": False,
    }
    actions: list[dict[str, object]] = []
    if request.extra_system_partition != "none":
        if system.style not in {"GPT", "MBR"} or windows.filesystem != "NTFS":
            reject("An extra system-disk partition requires a basic NTFS system volume")
        if not inventory.system_volume_healthy or (
            not inventory.system_volume_decrypted and not request.decrypt_system_volume
        ):
            reject("The fixture must not resize an unhealthy or encrypted system volume")
        plan["requires_decryption"] = not inventory.system_volume_decrypted
        if system.style == "MBR" and (
            len(system.partitions) >= 4
            or any(p.type in {"5", "15", "133"} for p in system.partitions)
        ):
            reject("The MBR baseline has no free primary partition slot")
        size = request.extra_partition_size_mib * MIB
        # Keep a spare alignment unit between the new fixture and the following partition.
        new_size = (windows.size - size - MIB) // MIB * MIB
        if new_size < max(inventory.system_min_size, 24 * GIB):
            reject("Insufficient safely shrinkable Windows space for the fixture")
        actions.append(
            {
                "kind": "extra-system-partition",
                "disk_device_path": system.device_path,
                "partition_number": windows.number,
                "new_system_size": new_size,
                "offset": windows.offset + new_size,
                "size": size,
                "format": request.extra_system_partition,
            }
        )
    if request.secondary_data:
        other = next(d for d in inventory.disks if d.number != system.number)
        if other.boot or other.system:
            reject("The secondary-data fixture must not use a boot disk")
        if other.size < 8 * GIB:
            reject("The secondary test disk is too small")
        if other.partitions:
            data_parts = [p for p in other.partitions if p.filesystem == "NTFS"]
            if len(data_parts) != 1 or not data_parts[0].drive_letter:
                reject("The secondary fixture requires one unambiguous existing NTFS data volume")
            actions.append(
                {
                    "kind": "existing-secondary-data",
                    "disk_device_path": other.device_path,
                    "partition_offset": data_parts[0].offset,
                    "partition_size": data_parts[0].size,
                }
            )
            plan["actions"] = actions
            return plan
        if other.style != "RAW":
            reject("The secondary fixture requires a RAW disk or an existing NTFS data volume")
        occupied = {letter.upper() for letter in inventory.used_drive_letters}
        occupied.update(p.drive_letter.upper() for d in inventory.disks for p in d.partitions)
        letter = next(
            (letter for letter in "DEFGHIJKLMNOPQRSTUVWXYZ" if letter not in occupied), None
        )
        if letter is None:
            reject("No unused drive letter is available for the secondary-data fixture")
        actions.append(
            {
                "kind": "secondary-data",
                "disk_device_path": other.device_path,
                "drive_letter": letter,
            }
        )
    plan["actions"] = actions
    return plan


def verify_storage_fixture_creation(
    baseline: StorageFixtureInventory,
    observed: StorageFixtureInventory,
    actions: list[dict[str, object]],
) -> None:
    """Reject a fixture that changed anything outside its planned disk extents."""

    def reject(message: str) -> None:
        raise WorkflowError("automation.storage_fixture.verify_creation", message)

    if observed.system_drive != baseline.system_drive or len(observed.disks) != len(baseline.disks):
        reject("The fixture changed the system volume or disk count")
    for before in baseline.disks:
        matches = [disk for disk in observed.disks if disk.device_path == before.device_path]
        if len(matches) != 1:
            reject("A fixture disk disappeared or changed its device path")
        after = matches[0]
        planned = [action for action in actions if action["disk_device_path"] == before.device_path]
        initialize = any(action["kind"] == "secondary-data" for action in planned)
        if (
            after.size != before.size
            or after.serial_number != before.serial_number
            or after.unique_id != before.unique_id
            or after.offline
            or after.read_only
            or (
                not initialize
                and (
                    after.style != before.style
                    or after.partition_table_id != before.partition_table_id
                )
            )
        ):
            reject("A fixture disk no longer matches its original identity")
        if initialize and (before.style != "RAW" or before.partitions or after.style != "GPT"):
            reject("The fixture initialized a disk that was not empty RAW storage")
        extra = [action for action in planned if action["kind"] == "extra-system-partition"]
        if not initialize and len(after.partitions) != len(before.partitions) + len(extra):
            reject("The fixture added or removed an unexpected partition")
        for part in before.partitions:
            found = [item for item in after.partitions if item.offset == part.offset]
            if len(found) != 1:
                reject("The fixture moved or removed a pre-existing partition")
            current = found[0]
            size = part.size
            if (
                part.drive_letter == baseline.system_drive
                and before.number == baseline.system_disk_number
            ):
                if after.number != observed.system_disk_number:
                    reject("The fixture changed the system disk association")
                if extra:
                    size = extra[0]["new_system_size"]
            if (
                current.size != size
                or current.type != part.type
                or current.filesystem != part.filesystem
                or current.drive_letter != part.drive_letter
            ):
                reject("The fixture changed a pre-existing partition outside the planned shrink")
        for action in extra:
            found = [item for item in after.partitions if item.offset == action["offset"]]
            filesystem = "FAT32" if action["format"] == "fat32" else "NTFS"
            if (
                len(found) != 1
                or found[0].size != action["size"]
                or found[0].filesystem != filesystem
            ):
                reject("The newly created fixture partition does not match its plan")
            if action["format"] == "recovery":
                expected_type = (
                    "{de94bba4-06d1-4d40-a16a-bfd50179d6ac}" if after.style == "GPT" else "39"
                )
                if found[0].type != expected_type:
                    reject("The fixture recovery partition has the wrong type")
