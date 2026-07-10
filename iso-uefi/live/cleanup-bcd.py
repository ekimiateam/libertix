#!/usr/bin/env python3
from __future__ import annotations

import shutil
import sys
from pathlib import Path

import hivex

# Well-known Windows Boot Manager object and BCD element ids.
BOOTMGR = "{9dea862c-5cdd-4e70-acc1-f32b344d4795}"
E_PATH = "12000002"
E_DESCRIPTION = "12000004"
E_DISPLAYORDER = "24000001"
E_BOOTSEQUENCE = "24000002"
E_TOOLS_DISPLAYORDER = "24000010"


def decode_utf16z(data: bytes | None) -> str:
    if not data:
        return ""
    return data.decode("utf-16le", errors="replace").rstrip("\0")


def decode_guid_list(data: bytes | None) -> list[str]:
    text = decode_utf16z(data)
    return [item for item in text.split("\0") if item]


def guid_list(guids: list[str]) -> bytes:
    return ("".join(guid + "\0" for guid in guids) + "\0").encode("utf-16le")


def child(hive: hivex.Hivex, node: int, name: str) -> int:
    found = hive.node_get_child(node, name)
    if not found:
        raise RuntimeError(f"missing BCD key: {name}")
    return found


def value_bytes(
    hive: hivex.Hivex, node: int | None, value_name: str = "Element"
) -> bytes | None:
    if not node:
        return None
    value = hive.node_get_value(node, value_name)
    if not value:
        return None
    _typ, data = hive.value_value(value)
    return data


def set_guid_list(
    hive: hivex.Hivex, elements: int, element_name: str, guids: list[str]
) -> None:
    node = hive.node_get_child(elements, element_name)
    if guids:
        if not node:
            node = hive.node_add_child(elements, element_name)
        hive.node_set_value(node, {"key": "Element", "t": 7, "value": guid_list(guids)})
    elif node:
        hive.node_delete_child(node)


def main() -> int:
    bcd = Path(sys.argv[1])
    if not bcd.is_file():
        raise RuntimeError(f"BCD file not found: {bcd}")

    backup = bcd.with_name("BCD.bak-libertix-cleanup")
    if not backup.exists():
        shutil.copy2(bcd, backup)

    hive = hivex.Hivex(str(bcd), write=True)
    root = hive.root()
    objects = child(hive, root, "Objects")
    bootmgr = child(hive, objects, BOOTMGR)
    bootmgr_elements = child(hive, bootmgr, "Elements")

    targets: list[str] = []
    for obj in hive.node_children(objects):
        guid = hive.node_name(obj)
        elements = hive.node_get_child(obj, "Elements")
        if not elements:
            continue
        desc_node = hive.node_get_child(elements, E_DESCRIPTION)
        path_node = hive.node_get_child(elements, E_PATH)
        desc = decode_utf16z(value_bytes(hive, desc_node))
        path = decode_utf16z(value_bytes(hive, path_node))
        normalized_path = path.replace("/", "\\").casefold()
        if desc.casefold() in (
            "install linux",
            "libertix uefi installer",
        ) or normalized_path in (
            "\\grldr.mbr",
            "\\\\grldr.mbr",
            "\\efi\\boot\\bootx64.efi",
            "\\\\efi\\boot\\bootx64.efi",
            "\\efi\\libertixinstaller\\shimx64.efi",
            "\\\\efi\\libertixinstaller\\shimx64.efi",
        ):
            targets.append(guid)

    if not targets:
        print("BCD cleanup: no temporary live boot entry found")
        return 0

    target_set = {guid.casefold() for guid in targets}
    for element in (E_DISPLAYORDER, E_BOOTSEQUENCE, E_TOOLS_DISPLAYORDER):
        node = hive.node_get_child(bootmgr_elements, element)
        current = decode_guid_list(value_bytes(hive, node))
        filtered = [guid for guid in current if guid.casefold() not in target_set]
        if filtered != current:
            set_guid_list(hive, bootmgr_elements, element, filtered)

    for guid in targets:
        node = hive.node_get_child(objects, guid)
        if node:
            hive.node_delete_child(node)

    hive.commit(None)
    print("BCD cleanup: deleted " + ", ".join(targets))
    print(f"BCD cleanup: backup={backup}")
    return 0


raise SystemExit(main())
