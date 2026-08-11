from __future__ import annotations

import importlib.util
import sys
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture
def bootentries_module() -> ModuleType:
    name = "libertix_uefi_bootentries_contract"
    spec = importlib.util.spec_from_file_location(
        name,
        ROOT / "assets/live/libertix-uefi-bootentries.py",
    )
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def test_fog_clone_entries_match_only_the_current_esp(bootentries_module: ModuleType) -> None:
    current_guid = "11111111-2222-3333-4444-555555555555"
    stale_guid = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    entries = "\n".join(
        (
            f"Boot0000* Partition 1 HD(1,GPT,{current_guid},0x800,0x32000)"
            r"/File(\EFI\BOOT\BOOTX64.EFI)",
            f"Boot0001* Windows Boot Manager HD(1,GPT,{stale_guid},0x800,0x32000)"
            r"/File(\EFI\Microsoft\Boot\bootmgfw.efi)",
            f"Boot0002* Libertix HD(1,GPT,{stale_guid},0x800,0x32000)"
            r"/File(\EFI\Libertix\shimx64.efi)",
            f"Boot0003* Windows Boot Manager HD(1,GPT,{current_guid},0x800,0x32000)"
            r"/File(\EFI\Microsoft\Boot\bootmgfw.efi)",
            f"Boot0004* Libertix HD(1,GPT,{current_guid},0x800,0x32000)"
            r"/File(\EFI\Libertix\shimx64.efi)",
        )
    )

    windows = bootentries_module.find_matching_boot_numbers(
        entries,
        description="Windows Boot Manager",
        loader_path=r"\EFI\Microsoft\Boot\bootmgfw.efi",
        partition_number=1,
        partition_guid=current_guid,
    )
    libertix = bootentries_module.find_matching_boot_numbers(
        entries,
        description="Libertix",
        loader_path=r"\EFI\Libertix\shimx64.efi",
        partition_number=1,
        partition_guid=current_guid,
    )

    assert windows == ["0003"]
    assert libertix == ["0004"]


def test_generic_partition_entry_is_not_a_windows_or_libertix_match(
    bootentries_module: ModuleType,
) -> None:
    current_guid = "11111111-2222-3333-4444-555555555555"
    entry = (
        f"Boot0000* Partition 1 HD(1,GPT,{current_guid},0x800,0x32000)"
        r"/File(\EFI\BOOT\BOOTX64.EFI)"
    )

    assert (
        bootentries_module.find_matching_boot_numbers(
            entry,
            description="Windows Boot Manager",
            loader_path=r"\EFI\Microsoft\Boot\bootmgfw.efi",
            partition_number=1,
            partition_guid=current_guid,
        )
        == []
    )
