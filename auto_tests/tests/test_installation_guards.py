from __future__ import annotations

import hashlib
import json
import re
import runpy
import subprocess
import xml.etree.ElementTree as ET
from collections.abc import Callable
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]

# This module checks source packaging, cross-language wiring and operation order
# that cannot be imported on the Linux test runner. Executable C# behavior lives
# in Libertix.Tests; end-to-end behavior is exercised by the VM automation.


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8-sig")


def read_apply_changes() -> str:
    """Read the complete ApplyChanges partial class as one reviewable source."""

    return "\n".join(
        path.read_text(encoding="utf-8-sig")
        for path in sorted((ROOT / "Pages").glob("ApplyChanges*.cs"))
    )


def test_compatibility_preflight_is_before_distro_selection() -> None:
    main = read("MainWindow.xaml.cs")
    page = read("Pages/CompatibilityCheck.xaml.cs")

    assert "new CompatibilityCheck(_installationState)" in main
    assert "_installationState.Compatibility = info" in page
    assert "new ChooseDistro(_installationState)" in page
    assert "App.Current.Properties" not in page


def test_compatibility_preflight_checks_download_access_and_one_disk_before_layout() -> None:
    script = read("Scripts/libertix-compatibility-preflight.ps1")
    runner = read("Helpers/CompatibilityPreflightRunner.cs")
    page = read("Pages/CompatibilityCheck.xaml.cs")

    assert "[string]$ConnectivityUrl" in script
    assert 'Write-Check "COMPAT_015_NETWORK"' in script
    assert "Test-DownloadServiceAccess -Url $ConnectivityUrl" in script
    assert "$request.Timeout = 15000" in script
    assert "$request.ReadWriteTimeout = 15000" in script
    assert "$request.AddRange(0, 0)" in script
    assert script.index('Write-Check "COMPAT_015_NETWORK"') < script.index(
        'Write-Check "COMPAT_020_PLATFORM"'
    )

    storage = script.split('Write-Check "COMPAT_040_STORAGE"', 1)[1]
    usb_check = "$usbDisks = @($visibleDisks | Where-Object"
    disk_count_check = "if ($visibleDisks.Count -ne 1)"
    system_drive_check = "$systemDrive = [Environment]::GetEnvironmentVariable"
    assert "Get-Disk -ErrorAction Stop" in storage
    assert usb_check in storage
    assert 'Stop-Compatibility "COMPAT_E_USB_STORAGE"' in storage
    assert disk_count_check in storage
    assert 'Stop-Compatibility "COMPAT_E_DISK_COUNT"' in storage
    assert storage.index(usb_check) < storage.index(disk_count_check)
    assert storage.index(disk_count_check) < storage.index(system_drive_check)
    assert 'Write-LocalizedWarning "MULTIPLE_DISKS"' not in script

    assert '" -ConnectivityUrl " +' in runner
    assert "WindowsProcessRunner.QuoteArgument(connectivityUrl)" in runner
    assert "Filepool.CatalogUrl" in page


def test_live_boot_mode_function_is_fail_closed(
    run_shell_function: Callable[..., subprocess.CompletedProcess[str]],
) -> None:
    library = ROOT / "assets/live/libertix-install-platform-common.sh"

    accepted_low_memory = run_shell_function(
        library,
        "validate_live_boot_mode",
        "true",
        "boot=live toram=filesystem.squashfs quiet",
    )
    rejected_low_memory = run_shell_function(
        library,
        "validate_live_boot_mode",
        "true",
        "boot=live findiso=/libertix-live.iso quiet",
    )
    accepted_normal = run_shell_function(
        library,
        "validate_live_boot_mode",
        "false",
        "boot=live toram quiet",
    )
    rejected_normal = run_shell_function(
        library,
        "validate_live_boot_mode",
        "false",
        "boot=live quiet",
    )

    assert accepted_low_memory.returncode == 0
    assert accepted_normal.returncode == 0
    assert rejected_low_memory.returncode != 0
    assert "LIVE_E_LOW_MEMORY_BOOT" in rejected_low_memory.stdout
    assert rejected_normal.returncode != 0
    assert "LIVE_E_TORAM_BOOT" in rejected_normal.stdout


@pytest.mark.parametrize(
    ("windows_path", "expected"),
    [
        (
            r"C:\Users\oem\AppData\Local\Temp\Libertix\mint.iso",
            "Users/oem/AppData/Local/Temp/Libertix/mint.iso",
        ),
        (r"D:\mint.iso", "mint.iso"),
    ],
)
def test_shared_storage_converts_windows_paths_without_losing_segments(
    run_shell_function: Callable[..., subprocess.CompletedProcess[str]],
    windows_path: str,
    expected: str,
) -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"

    result = run_shell_function(library, "windows_path_to_relative", windows_path)

    assert result.returncode == 0
    assert result.stdout.strip() == expected


def test_windows_share_uses_the_observed_partition_identity() -> None:
    windows = read("Pages/ApplyChanges.Windows.cs")
    bios = read("Pages/ApplyChanges.Bios.cs")
    uefi = read("Pages/ApplyChanges.Uefi.cs")

    assert "PublishObservedWindowsSharePartitionIdentity" in windows
    assert "GetExpectedFinalLinuxOffset()" in windows
    assert "InstallationResizeMode.LiveOffline" in windows
    assert "return installer.FinalOffsetBytes;" in windows
    assert "return installer.OffsetBytes" in windows
    assert (
        "await UpdateInstallerPartitionIdentityAsync(_biosInstallerDriveLetter[0]);\n"
        "            PublishObservedWindowsSharePartitionIdentity();"
    ) in bios
    assert (
        "_installationPlan = InstallationPlanSerializer.ReadValidated(\n"
        "                    _installationPlanPath);\n"
        "                PublishObservedWindowsSharePartitionIdentity();"
    ) in uefi


def test_temporary_drive_letters_prefer_z_and_fall_back() -> None:
    geometry = read("Scripts/modules/Libertix.StorageGeometry.psm1")
    bios = read("Scripts/libertix-bios-storage.ps1")
    uefi = read("Scripts/libertix-uefi-install.ps1")

    assert '"Z", "Y", "X", "W"' in geometry
    assert "$createdDriveLetter = Get-LibertixFreeDriveLetter" in bios
    assert '-AccessPath "${createdDriveLetter}:\\"' in bios
    assert "$InstallerLetter = Get-LibertixFreeDriveLetter" in uefi
    assert "$EspLetter = Get-LibertixFreeDriveLetter -ExcludedLetters" in uefi


@pytest.mark.parametrize(
    ("kernel_sector", "expected_bytes"),
    [("0", "0"), ("2048", "1048576"), ("524288", "268435456")],
)
def test_shared_storage_converts_kernel_start_sectors_as_fixed_512_byte_units(
    run_shell_function: Callable[..., subprocess.CompletedProcess[str]],
    kernel_sector: str,
    expected_bytes: str,
) -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"

    result = run_shell_function(library, "kernel_sector_to_bytes", kernel_sector)

    assert result.returncode == 0
    assert result.stdout.strip() == expected_bytes


@pytest.mark.parametrize(
    ("offset_bytes", "logical_sector", "expected_sector", "accepted"),
    [
        ("1048576", "512", "2048", True),
        ("1048576", "4096", "256", True),
        ("262144", "4096", "64", True),
        ("262145", "4096", "", False),
    ],
)
def test_shared_storage_converts_byte_offsets_to_device_logical_sectors(
    run_shell_function: Callable[..., subprocess.CompletedProcess[str]],
    offset_bytes: str,
    logical_sector: str,
    expected_sector: str,
    accepted: bool,
) -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"

    result = run_shell_function(
        library,
        "bytes_to_logical_sectors",
        offset_bytes,
        logical_sector,
    )

    assert (result.returncode == 0) is accepted
    assert result.stdout.strip() == expected_sector


@pytest.mark.parametrize(
    ("requested_bytes", "maximum_bytes", "expected_bytes", "accepted"),
    [
        (str(20 * 1024**3), str(20 * 1024**3), str(20 * 1024**3), True),
        (
            str(20 * 1024**3),
            str(20 * 1024**3 - 1024**2),
            str(20 * 1024**3 - 1024**2),
            True,
        ),
        (str(20 * 1024**3), str(20 * 1024**3 - 1024**2 - 512), "", False),
    ],
)
def test_shared_storage_bounds_mbr_alignment_shortfall(
    run_shell_function: Callable[..., subprocess.CompletedProcess[str]],
    requested_bytes: str,
    maximum_bytes: str,
    expected_bytes: str,
    accepted: bool,
) -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"

    result = run_shell_function(
        library,
        "installer_partition_target_bytes",
        requested_bytes,
        maximum_bytes,
        str(
            json.loads(read("Scripts/config/Libertix.InstallationPolicy.json"))["storage"][
                "partitionAlignmentBytes"
            ]
        ),
    )

    assert (result.returncode == 0) is accepted
    assert result.stdout.strip() == expected_bytes


def test_mbr_primary_slot_count_ignores_logical_partitions() -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"
    # This is Parted 3.6 machine output from VM500. Unlike the human table, it
    # omits the primary/extended/logical type column entirely.
    layout = """BYT;
/dev/sda:134217728s:scsi:512:512:msdos:ATA QEMU HARDDISK:;
1:2048s:104447s:102400s:ntfs::boot;
2:104448s:91172628s:91068181s:ntfs::;
3:91172864s:133115903s:41943040s:::lba;
5:91174912s:133115903s:41940992s:ext4::;
4:133115904s:134213631s:1097728s:ntfs::msftres;
"""
    command = 'source "$1"; mbr_primary_slot_count_from_machine_output'

    result = subprocess.run(
        ["bash", "-c", command, "mbr-slot-test", str(library)],
        input=layout,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "4"


def test_mbr_empty_container_requires_the_logical_partition_to_be_gone() -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"
    layout_with_logical = """BYT;
/dev/sda:134217728s:scsi:512:512:msdos:ATA QEMU HARDDISK:;
1:2048s:104447s:102400s:ntfs::boot;
2:104448s:91172628s:91068181s:ntfs::;
3:91172864s:133115903s:41943040s:::lba;
5:91174912s:133115903s:41940992s:ext4::;
4:133115904s:134213631s:1097728s:ntfs::msftres;
"""
    layout_without_logical = layout_with_logical.replace(
        "5:91174912s:133115903s:41940992s:ext4::;\n", ""
    )
    command = 'source "$1"; mbr_empty_container_from_machine_output "$2" "$3"'

    blocked = subprocess.run(
        ["bash", "-c", command, "mbr-container-test", str(library), "91174912", "133115904"],
        input=layout_with_logical,
        check=False,
        capture_output=True,
        text=True,
    )
    resolved = subprocess.run(
        ["bash", "-c", command, "mbr-container-test", str(library), "91174912", "133115904"],
        input=layout_without_logical,
        check=False,
        capture_output=True,
        text=True,
    )

    assert blocked.returncode == 2
    assert blocked.stdout == ""
    assert resolved.returncode == 0
    assert resolved.stdout.strip() == "3:91172864:133115903"


def test_mbr_owned_logical_layout_resolves_vm500_geometry() -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"
    layout = """BYT;
/dev/sda:134217728s:scsi:512:512:msdos:ATA QEMU HARDDISK:;
1:2048s:104447s:102400s:ntfs::boot;
2:104448s:91172628s:91068181s:ntfs::;
3:91172864s:133115903s:41943040s:::lba;
5:91174912s:133115903s:41940992s:ext4::;
4:133115904s:134213631s:1097728s:ntfs::msftres;
"""
    command = 'source "$1"; mbr_owned_logical_layout_from_machine_output "$2" "$3"'

    result = subprocess.run(
        ["bash", "-c", command, "mbr-owned-layout", str(library), "91174912", "133115904"],
        input=layout,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "5:91174912:133115903:3:91172864:133115903"


def test_mbr_owned_logical_layout_preserves_a_gap_before_recovery() -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"
    layout = """BYT;
/dev/sda:134217728s:scsi:512:512:msdos:ATA QEMU HARDDISK:;
1:2048s:104447s:102400s:ntfs::boot;
2:104448s:91172628s:91068181s:ntfs::;
3:91172864s:133115903s:41943040s:::lba;
5:91174912s:133115903s:41940992s:ext4::;
4:133117952s:134213631s:1095680s:ntfs::msftres;
"""
    command = 'source "$1"; mbr_owned_logical_layout_from_machine_output "$2" "$3"'

    result = subprocess.run(
        ["bash", "-c", command, "mbr-owned-gap", str(library), "91174912", "133117952"],
        input=layout,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "5:91174912:133115903:3:91172864:133115903"


def test_mbr_owned_logical_layout_rejects_an_unowned_second_logical_partition() -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"
    layout = """BYT;
/dev/sda:134217728s:scsi:512:512:msdos:ATA QEMU HARDDISK:;
1:2048s:104447s:102400s:ntfs::boot;
2:104448s:91172628s:91068181s:ntfs::;
3:91172864s:133115903s:41943040s:::lba;
5:91174912s:112146431s:20971520s:ext4::;
6:112148480s:133115903s:20967424s:ext4::;
4:133115904s:134213631s:1097728s:ntfs::msftres;
"""
    command = 'source "$1"; mbr_owned_logical_layout_from_machine_output "$2" "$3"'

    result = subprocess.run(
        ["bash", "-c", command, "mbr-owned-layout", str(library), "91174912", "133115904"],
        input=layout,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 2
    assert result.stdout == ""


def test_bios_mbr_normalization_writes_exact_sectors_under_a_disk_lock() -> None:
    bios = read("assets/live/libertix-bios-adapter.sh")
    normalization = bios.split("prepare_installer_partition_for_target_format_or_die()", 1)[
        1
    ].split("wait_for_prereqs()", 1)[0]

    assert "partition_size=$((logical_end - logical_start + 1))" in normalization
    assert 'sfdisk --lock --append --no-reread -N "$extended_number" "$DISK"' in normalization
    assert "mkpart primary ext4" not in normalization
    assert 'partition_at_offset "$DISK" "$INSTALLER_PARTITION_OFFSET_BYTES"' in normalization
    assert '"$new_end" = "$logical_end"' in normalization
    assert '"$new_size" = "$original_size"' in normalization
    assert normalization.count("assert_recovery_unchanged_or_die") >= 2


def test_recovery_identity_check_retries_only_the_exact_manifest_geometry() -> None:
    runtime = read("assets/live/libertix-install-runtime-common.sh")

    assert "for attempt in $(seq 1 20); do" in runtime
    assert "udevadm settle --timeout=10" in runtime
    assert '"$RECOVERY_PARTITION_OFFSET_BYTES"' in runtime
    assert '"$recovery_size" = "$RECOVERY_PARTITION_SIZE_BYTES"' in runtime


def test_installed_windows_grub_entry_has_a_stable_verification_id() -> None:
    target = read("assets/live/configure-target-main.sh")
    validator = read("assets/live/libertix-validate-grub.sh")
    verifier = read("assets/live/libertix-first-boot-verify.py")

    assert target.count("--id libertix-windows") == 2
    assert "--id libertix-windows" in validator
    assert '"--id libertix-windows"' in verifier


def test_installed_linux_persists_and_displays_its_first_boot_verification() -> None:
    target_common = read("assets/live/libertix-target-common.sh")
    resize = read("assets/live/first-boot-resize.sh")
    verifier = read("assets/live/libertix-first-boot-verify.py")
    result_ui = read("assets/live/libertix-first-boot-result.py")
    desktop = read("assets/live/libertix-first-boot-result.desktop")

    assert "--record-service-failure" in resize
    assert "trap record_failure ERR" in resize
    assert '"succeeded"' in verifier
    assert '"failed"' in verifier
    assert "/var/lib/libertix/first-boot-verification.json" in verifier
    assert "Libertix.Translations.json" in result_ui
    assert "load_translations" in result_ui
    assert "status_fingerprint" in result_ui
    assert "libertix-first-boot-result.desktop" in target_common
    assert "Exec=/usr/local/lib/libertix/libertix-first-boot-result.py" in desktop


def test_bios_mbr_removal_verifies_the_table_instead_of_trusting_parted_rc() -> None:
    bios = read("assets/live/libertix-bios-adapter.sh")
    removal = bios.split("remove_mbr_partition_entry_verified()", 1)[1].split(
        "firmware_rollback_partition_is_owned()", 1
    )[0]
    normalization = bios.split("prepare_installer_partition_for_target_format_or_die()", 1)[
        1
    ].split("wait_for_prereqs()", 1)[0]
    rollback_cleanup = bios.split("firmware_cleanup_partition_container_best_effort()", 1)[1].split(
        "firmware_restore_boot_state_best_effort()", 1
    )[0]

    assert 'if parted -s "$DISK" rm "$number"; then' in removal
    assert 'layout="$(parted -sm "$DISK" unit s print' in removal
    assert 'echo "WARNING: parted returned rc=$rc' in removal
    assert 'remove_mbr_partition_entry_verified \\\n        "$logical_number"' in normalization
    assert 'remove_mbr_partition_entry_verified \\\n        "$extended_number"' in normalization
    assert "run_logged parted" not in normalization
    assert "remove_mbr_partition_entry_verified" in rollback_cleanup


@pytest.mark.parametrize(
    ("layout", "expected_returncode"),
    [
        ("BYT;\n/dev/mock:4096s:file:512:512:msdos:;\n", 0),
        ("BYT;\n/dev/mock:4096s:file:512:512:msdos:;\n3:1s:2047s:2047s:::;\n", 1),
    ],
)
def test_bios_mbr_removal_uses_the_observed_postcondition(
    tmp_path: Path, layout: str, expected_returncode: int
) -> None:
    parted = tmp_path / "parted"
    parted.write_text(
        '#!/bin/sh\nif [ "$1" = "-s" ]; then exit 1; fi\nprintf \'%s\\n\' "$MOCK_LAYOUT"\n',
        encoding="utf-8",
    )
    parted.chmod(0o755)
    command = (
        'PATH="$1:$PATH"; MOCK_LAYOUT="$2"; export PATH MOCK_LAYOUT; '
        'source "$3"; DISK=/dev/mock; '
        'remove_mbr_partition_entry_verified 3 "test removal"'
    )

    result = subprocess.run(
        [
            "bash",
            "-c",
            command,
            "mbr-removal-test",
            str(tmp_path),
            layout,
            str(ROOT / "assets/live/libertix-bios-adapter.sh"),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == expected_returncode
    if expected_returncode == 0:
        assert "parted returned rc=1, but removal" in result.stdout
    else:
        assert "partition 3 remains after parted returned rc=1" in result.stdout


@pytest.mark.parametrize(
    ("layout", "expected_returncode"),
    [
        ("BYT;\n/dev/mock:4096s:file:512:512:msdos:;\n1:1s:2047s:2047s:::boot;\n", 0),
        ("BYT;\n/dev/mock:4096s:file:512:512:msdos:;\n2:1s:2047s:2047s:::boot;\n", 1),
    ],
)
def test_bios_boot_flag_update_uses_the_observed_postcondition(
    tmp_path: Path, layout: str, expected_returncode: int
) -> None:
    sfdisk = tmp_path / "sfdisk"
    parted = tmp_path / "parted"
    sfdisk.write_text("#!/bin/sh\nexit 1\n", encoding="utf-8")
    parted.write_text("#!/bin/sh\nprintf '%s\\n' \"$MOCK_LAYOUT\"\n", encoding="utf-8")
    sfdisk.chmod(0o755)
    parted.chmod(0o755)
    command = (
        'PATH="$1:$PATH"; MOCK_LAYOUT="$2"; export PATH MOCK_LAYOUT; '
        'source "$3"; DISK=/dev/mock; '
        'set_mbr_active_partition_verified 1 "test boot flags"'
    )

    result = subprocess.run(
        [
            "bash",
            "-c",
            command,
            "mbr-boot-flag-test",
            str(tmp_path),
            layout,
            str(ROOT / "assets/live/libertix-bios-adapter.sh"),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == expected_returncode
    if expected_returncode == 0:
        assert (
            "sfdisk returned rc=1, but the requested MBR boot flags were verified" in result.stdout
        )
    else:
        assert "MBR boot flags do not match the requested state after rc=1" in result.stdout


def test_run_logged_failure_reports_the_wrapped_command() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    runtime = read("assets/live/libertix-install-runtime-common.sh")

    assert 'RUN_LOGGED_COMMAND="$*"' in runtime
    assert 'RUN_LOGGED_RC="$rc"' in runtime
    assert 'cmd="$RUN_LOGGED_COMMAND"' in installer
    assert '[[ "$shell_command" == return* ]]' in installer


def test_detached_partition_check_does_not_query_the_dev_mount() -> None:
    runtime = (ROOT / "assets/live/libertix-install-runtime-common.sh").read_text(encoding="utf-8")
    detached_check = runtime.split("assert_not_mounted_or_open() {", 1)[1].split(
        "mount_ntfs_rw_or_die() {", 1
    )[0]

    assert 'fuser "$partition"' in detached_check
    assert 'fuser -m "$partition"' not in detached_check
    assert "consecutive_idle_samples" in detached_check
    assert "udevadm settle --timeout=10" in detached_check


@pytest.mark.parametrize(("mode", "expected_returncode"), [("transient", 0), ("persistent", 1)])
def test_detached_partition_check_tolerates_only_transient_direct_users(
    tmp_path: Path, mode: str, expected_returncode: int
) -> None:
    for name, body in {
        "findmnt": "exit 1\n",
        "udevadm": "exit 0\n",
        "sleep": "exit 0\n",
        "fuser": (
            'if [ "$MODE" = persistent ]; then echo 1408; exit 0; fi\n'
            'count=$(cat "$COUNT_FILE" 2>/dev/null || echo 0)\n'
            'count=$((count + 1)); printf "%s\\n" "$count" > "$COUNT_FILE"\n'
            '[ "$count" -gt 1 ] && exit 1\n'
            "echo 1408\nexit 0\n"
        ),
    }.items():
        executable = tmp_path / name
        executable.write_text(f"#!/bin/sh\n{body}", encoding="utf-8")
        executable.chmod(0o755)

    command = (
        'PATH="$1:$PATH"; MODE="$2"; COUNT_FILE="$1/count"; '
        'export PATH MODE COUNT_FILE; source "$3"; '
        'die() { echo "DIE:$*"; return 1; }; '
        'assert_not_mounted_or_open "$4"'
    )
    result = subprocess.run(
        [
            "bash",
            "-c",
            command,
            "partition-user-test",
            str(tmp_path),
            mode,
            str(ROOT / "assets/live/libertix-install-runtime-common.sh"),
            "/dev/null",
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == expected_returncode
    if mode == "persistent":
        assert "DIE:partition remains in use" in result.stdout


@pytest.mark.parametrize(("raw_type", "normalized"), [(" f \n", "f"), ("0x0F\n", "f")])
def test_mbr_partition_type_normalization_ignores_sfdisk_spacing(
    raw_type: str, normalized: str
) -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"
    command = 'source "$1"; normalize_mbr_partition_type'

    result = subprocess.run(
        ["bash", "-c", command, "mbr-type-test", str(library)],
        input=raw_type,
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert result.stdout == normalized


def test_bios_rollback_removes_only_a_proven_empty_extended_container() -> None:
    rollback = read("assets/live/libertix-rollback-common.sh")
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    delete_index = rollback.index("delete_transaction_partition_best_effort || return 1")
    cleanup_index = rollback.index("firmware_cleanup_partition_container_best_effort || return 1")
    resize_index = rollback.index("if restore_windows_partition_best_effort; then")
    assert delete_index < cleanup_index < resize_index

    bios_cleanup = bios.split("firmware_cleanup_partition_container_best_effort()", 1)[1]
    bios_cleanup = bios_cleanup.split("firmware_restore_boot_state_best_effort()", 1)[0]
    assert "mbr_empty_container_from_machine_output" in bios_cleanup
    assert 'sfdisk --part-type "$DISK" "$extended_number"' in bios_cleanup
    assert "remove_mbr_partition_entry_verified" in bios_cleanup
    assert "firmware_cleanup_partition_container_best_effort()" in uefi

    # -m is only defined for mounted filesystems and can report unrelated
    # processes for raw block devices. Rollback checks the mount table, kernel
    # holders, and direct device users separately instead.
    assert 'fuser -m "$NEW_PART"' not in rollback
    assert 'fuser "$NEW_PART"' in rollback
    assert "/holders" in rollback


def test_live_rollback_restores_exact_windows_geometry_from_plan() -> None:
    plan = read("assets/live/libertix-installation-plan.py")
    loader = read("assets/live/libertix-installation-plan.sh")
    rollback = read("assets/live/libertix-rollback-common.sh")

    assert '"WINDOWS_PARTITION_SIZE_BYTES"' in plan
    assert "WINDOWS_PARTITION_SIZE_BYTES" in loader
    assert "WINDOWS_PARTITION_OFFSET_BYTES + WINDOWS_PARTITION_SIZE_BYTES" in rollback
    assert '"$((WINDOWS_PARTITION_SIZE_BYTES / logical_sector))"' in rollback
    assert "resize_partition_size_sectors" in rollback
    assert 'resize_end="100%"' not in rollback


@pytest.mark.parametrize("failed_transition", ["begin", "compensate", "complete"])
def test_live_rollback_rejects_success_when_state_persistence_fails(
    failed_transition: str,
) -> None:
    rollback = ROOT / "assets/live/libertix-rollback-common.sh"
    command = r"""
source "$1"
INSTALL_SUCCESS=false
ROLLBACK_ATTEMPTED=false
BOOTLOADER_WRITE_STARTED=false
RECOVERY_GEOMETRY_BEFORE=""
DISK=/dev/fake-disk
WINDOWS_PART=/dev/fake-windows
FAILED_TRANSITION="$2"
resolve_rollback_storage_best_effort() { return 0; }
cleanup_live_mounts_best_effort() { return 0; }
swapoff() { return 0; }
restore_pre_grub_mbr_best_effort() { return 0; }
firmware_prepare_rollback_best_effort() { return 0; }
delete_transaction_partition_best_effort() { return 0; }
firmware_cleanup_partition_container_best_effort() { return 0; }
restore_windows_partition_best_effort() { return 0; }
firmware_restore_boot_state_best_effort() { return 0; }
debug_disk_state() { return 0; }
begin_installation_state_rollback() { [ "$FAILED_TRANSITION" != begin ]; }
compensate_installation_state_step() { [ "$FAILED_TRANSITION" != compensate ]; }
complete_installation_state_rollback() { [ "$FAILED_TRANSITION" != complete ]; }
rollback_windows_layout_best_effort
"""

    result = subprocess.run(
        ["bash", "-c", command, "rollback-state-test", str(rollback), failed_transition],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 1
    assert "durable rollback state is incomplete" in result.stdout
    assert "ROLLBACK: completed best-effort Windows layout restore" not in result.stdout


def test_live_rollback_reports_success_after_durable_state_completion() -> None:
    rollback = ROOT / "assets/live/libertix-rollback-common.sh"
    command = r"""
source "$1"
INSTALL_SUCCESS=false
ROLLBACK_ATTEMPTED=false
BOOTLOADER_WRITE_STARTED=false
RECOVERY_GEOMETRY_BEFORE=""
DISK=/dev/fake-disk
WINDOWS_PART=/dev/fake-windows
resolve_rollback_storage_best_effort() { return 0; }
cleanup_live_mounts_best_effort() { return 0; }
swapoff() { return 0; }
restore_pre_grub_mbr_best_effort() { return 0; }
firmware_prepare_rollback_best_effort() { return 0; }
delete_transaction_partition_best_effort() { return 0; }
firmware_cleanup_partition_container_best_effort() { return 0; }
restore_windows_partition_best_effort() { return 0; }
firmware_restore_boot_state_best_effort() { return 0; }
debug_disk_state() { return 0; }
begin_installation_state_rollback() { return 0; }
compensate_installation_state_step() { return 0; }
complete_installation_state_rollback() { return 0; }
rollback_windows_layout_best_effort
"""

    result = subprocess.run(
        ["bash", "-c", command, "rollback-state-test", str(rollback)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert result.returncode == 0
    assert "ROLLBACK: completed best-effort Windows layout restore" in result.stdout


def test_windows_rollbacks_require_the_exact_original_system_partition_size() -> None:
    shared_rollback = read("Scripts/modules/Libertix.Rollback.psm1")
    bios_guard = read("Scripts/libertix-recovery-guard.ps1")

    assert "$partition.Size -ne $initialSize" in shared_rollback
    assert "$verified.Size -ne $initialSize" in shared_rollback
    assert "$supported.SizeMin -gt $initialSize" in shared_rollback
    assert "$currentSystemPartition.Size -ne $initialSystemSize" in bios_guard
    assert "$finalSystemPartition.Size -ne $initialSystemSize" in bios_guard
    assert "$supported.SizeMin -gt $initialSystemSize" in bios_guard
    assert "$expectedTransactionOffset" in bios_guard
    assert "$initialSystemEnd = $initialSystemOffset + $initialSystemSize" in bios_guard
    assert "$partitionStart -lt $systemPartitionEnd" in bios_guard
    assert "$partitionEnd -gt $initialSystemEnd" in bios_guard
    assert "$candidateOffsets" not in bios_guard
    assert "[int]$partition.MbrType -in @(5, 15, 133)" in bios_guard
    assert "$isRawTransaction" in bios_guard
    assert "[int64]$partitionSizeTolerance = $PartitionAlignmentBytes" in bios_guard
    assert "[int64]$minBytes" in bios_guard
    assert "[int64]$stagingMinBytes" in bios_guard
    assert "[Math]::Max" not in bios_guard


def test_bios_downloader_verifies_bundled_aria2_before_execution() -> None:
    downloader = read("Pages/ApplyChanges.Downloads.cs")
    verification = downloader.index("Artifacts.Aria2.ExecutableSha256")
    execution = downloader.index("RunStreamingProcessAsync(", verification)

    assert verification < execution
    assert "bundled aria2 hash mismatch, using HTTP downloader" in downloader


def test_downloaders_disable_split_and_resume_when_byte_ranges_are_not_proven() -> None:
    bios = read("Pages/ApplyChanges.Downloads.cs")
    uefi = read("Scripts/uefi/Libertix.Uefi.Downloads.ps1")

    assert "TestHttpByteRangeSupportAsync(url)" in bios
    assert "supportsByteRanges ? Aria2MaxConnections : 1" in bios
    assert 'supportsByteRanges ? "true" : "false"' in bios
    assert 'DeleteDownloadArtifactBestEffort(aria2OutputPath + ".aria2"' in bios
    assert "if (!byteRangeSupport.HasValue)" in bios
    assert "the partial download is retained for retry" in bios
    assert "Get-HttpByteRangeSupport -Url $Url" in uefi
    assert '$byteRangeSupport -eq "unknown"' in uefi
    assert "the partial download is retained for retry" in uefi
    assert "$connections = if ($supportsByteRanges) { $Aria2Connections } else { 1 }" in uefi
    assert "-ContinueDownload $supportsByteRanges" in uefi
    assert 'Remove-Item -LiteralPath "$downloadPath.aria2"' in uefi


def test_bios_mbr_backup_is_atomic_durable_and_reusable(tmp_path: Path) -> None:
    source_backup = tmp_path / "source.bin"
    restored_backup = tmp_path / "restored.bin"
    windows_root = tmp_path / "windows"
    source_backup.write_bytes(bytes(range(256)) * 2)
    script = r"""
set -eu
source "$1"
source "$2"
RECOVERY_ROOT_WINDOWS='C:\LibertixInstallRecovery'
publish_durable_bios_mbr_backup "$3" "$4"
load_durable_bios_mbr_backup "$3" "$5"
cmp "$4" "$5"
validate_durable_bios_mbr_backup \
    "$3/LibertixInstallRecovery/mbr-backup"
"""

    subprocess.run(
        [
            "bash",
            "-c",
            script,
            "mbr-backup-test",
            str(ROOT / "assets/live/libertix-storage-common.sh"),
            str(ROOT / "assets/live/libertix-live-context.sh"),
            str(windows_root),
            str(source_backup),
            str(restored_backup),
        ],
        check=True,
        capture_output=True,
        text=True,
    )

    durable = windows_root / "LibertixInstallRecovery/mbr-backup"
    assert (durable / "mbr-before-grub.bin").read_bytes() == source_backup.read_bytes()
    assert (durable / "mbr-before-grub.sha256").is_file()


def test_bios_mbr_backup_precedes_bootloader_write() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    rollback = read("assets/live/libertix-rollback-common.sh")

    backup = installer.index("prepare_bios_mbr_backup_or_die")
    armed = installer.index("BOOTLOADER_WRITE_STARTED=true", backup)
    grub = installer.index("grub-install --target=i386-pc", armed)
    assert backup < armed < grub
    assert "load_bios_mbr_backup_for_rollback" in rollback
    assert "bs=446 count=1 conv=notrunc status=none" in rollback


def test_failed_installation_requires_account_secret_reentry() -> None:
    apply_page = read("Pages/ApplyChanges.xaml.cs")
    account = read("Models/AccountInfo.cs")

    assert "_installationState.Account?.HasPassword == true" in apply_page
    assert "new AccountCreation(_installationState)" in apply_page
    assert "internal bool HasPassword" in account
    assert "account.ClearPassword();" in read("Pages/ApplyChanges.Plan.cs")


def test_windows_download_and_bios_boot_temporary_state_is_transaction_scoped() -> None:
    bios = read("Pages/ApplyChanges.Bios.cs")
    downloads = read("Pages/ApplyChanges.Downloads.cs")
    recovery = read("Scripts/libertix-recovery-guard.ps1")

    assert "InstallationTemporaryArtifacts.GetLiveMediaDirectory(" in bios
    assert '(_installationPlan.Disk.SystemDrive ?? WindowsSystemDrive) + @"\\"' in bios
    assert "_installationPlan.PlanId" in bios
    assert 'Path.Combine(tempIsoDirectory, "bios-live.iso")' in bios
    assert 'Path.GetTempPath(), "libertix_installer.iso"' not in bios
    assert "DeleteDownloadArtifactBestEffort(tempIsoPath" in bios
    assert "DeleteDownloadDirectoryBestEffort(" in bios
    assert "Libertix BIOS ISO transaction cleanup verified." in bios
    assert "File.Exists(tempIsoPath) || Directory.Exists(tempIsoDirectory)" in bios
    assert "removeDownloadDirectory = true;" in downloads
    assert "finally" in downloads
    assert "DeleteDownloadDirectoryBestEffort(downloadDir, label);" in downloads
    assert "Directory.Delete(path, recursive: true);" in downloads
    assert "function Invoke-VerifiedInstallationSuccess" in recovery
    assert "Restore-BcdState -Required" in recovery
    assert "Restore-BiosMbrBootCode" in recovery
    assert '[string]$recoveryExecutionState.status -eq "succeeded"' in recovery
    assert '[string]$recoveryExecutionState.status -eq "rolled-back"' in recovery
    assert "Restore-OriginalHibernationSetting" in recovery
    assert 'throw "Required pre-install BCD backup is missing."' in recovery


def test_bios_bcd_guid_and_live_copy_processes_use_strict_bounded_contracts() -> None:
    bios = read("Pages/ApplyChanges.Bios.cs")
    process_runner = read("Helpers/WindowsProcessRunner.cs")

    assert "MatchCollection guidMatches = Regex.Matches" in bios
    assert "guidMatches.Count == 1" in bios
    assert "output.IndexOf('{')" not in bios
    assert '"xcopy.exe"' in bios
    assert 'QuoteArgument(sourceDir + "*")' in bios
    assert "WindowsProcessTimeouts.FileCopy" in bios
    assert '"ISO copy process tree could not be proven stopped."' in bios
    assert "catch (UnterminatedProcessException)" in bios
    assert "DismountBiosIsoAsync" in bios
    assert '"ISO dismount process tree could not be proven stopped."' in bios
    assert "treeTerminationProven" in process_runner
    assert "taskKill.ExitCode == 0" in process_runner
    assert "Timed-out process tree could not be proven stopped" in process_runner


def test_all_blocking_windows_operations_use_the_named_timeout_policy() -> None:
    bios = read("Pages/ApplyChanges.Bios.cs")
    windows = read("Pages/ApplyChanges.Windows.cs")
    downloads = read("Pages/ApplyChanges.Downloads.cs")
    processes = read("Pages/ApplyChanges.Processes.cs")
    policy = read("Helpers/WindowsProcessRunner.cs")

    for name in (
        "BootArtifactDownload",
        "SupportArtifactDownload",
        "RecoveryOperation",
        "LiveIsoDownload",
        "DistributionIsoDownload",
    ):
        assert f"TimeSpan {name}" in policy
    assert "WindowsProcessTimeouts.RecoveryOperation" in bios
    assert "WindowsProcessTimeouts.SupportArtifactDownload" in windows
    assert "using Libertix.Helpers;" in downloads
    assert "WindowsProcessTimeouts.LiveIsoDownload" in downloads
    assert "WindowsProcessTimeouts.DistributionIsoDownload" in downloads
    assert "WindowsProcessTimeouts.BootArtifactDownload" in processes


def test_live_target_disk_requires_cross_platform_partition_table_identity() -> None:
    preflight = read("Scripts/libertix-storage-preflight.ps1")
    plan_exporter = read("assets/live/libertix-installation-plan.py")
    plan_loader = read("assets/live/libertix-installation-plan.sh")
    storage = read("assets/live/libertix-storage-common.sh")

    assert "function Get-PartitionTableIdentity" in preflight
    assert "return \"gpt:$($guid.ToString('D').ToLowerInvariant())\"" in preflight
    assert "return \"mbr:$(([uint32]$Disk.Signature).ToString('x8'))\"" in preflight
    assert '"TARGET_DISK_PARTITION_TABLE_ID": disk["partitionTableId"]' in plan_exporter
    assert "TARGET_DISK_PARTITION_TABLE_ID" in plan_loader
    assert "disk_partition_table_identity()" in storage
    assert "blkid -s PTUUID" in storage
    assert 'actual_identity="$(disk_partition_table_identity "$disk" || true)"' in storage
    assert '[ "$actual_identity" = "$TARGET_DISK_PARTITION_TABLE_ID" ]' in storage


def test_uefi_bitlocker_decryption_requests_surface_initial_and_retry_failures() -> None:
    storage = read("Scripts/uefi/Libertix.Uefi.Storage.ps1")
    orchestration = read("Scripts/libertix-uefi-install.ps1")
    execution = read("Scripts/uefi/Libertix.Uefi.Execution.ps1")
    helper = storage.split("function Request-BitLockerDecryption", 1)[1].split(
        "function Set-WindowsVolumeReadableFromLinux", 1
    )[0]
    workflow = storage.split("function Set-WindowsVolumeReadableFromLinux", 1)[1]

    assert "Disable-BitLocker -MountPoint $MountPoint -ErrorAction Stop" in helper
    assert "$manageExitCode = $LASTEXITCODE" in helper
    assert "if ($manageExitCode -ne 0)" in helper
    assert "BitLocker decryption request failed" in helper
    assert (
        workflow.count(
            "Request-BitLockerDecryption -MountPoint $SystemDrive -ManageBdePath $manageBde"
        )
        == 2
    )
    assert "-ErrorAction Continue" not in workflow
    assert "function Set-LibertixInstallationPlanWindowsBitLockerState" in execution
    assert (
        orchestration.index("Set-WindowsVolumeReadableFromLinux")
        < orchestration.index(
            'Set-LibertixInstallationPlanWindowsBitLockerState -State "FullyDecrypted"'
        )
        < orchestration.index("New-OrReuseInstallerPartition")
    )


def test_final_verification_counts_mbr_slots_instead_of_lsblk_children() -> None:
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    assert 'primary_slot_count="$(mbr_primary_slot_count "$DISK")"' in bios
    assert 'primary_slot_count="$(mbr_primary_slot_count "$DISK")"' in uefi
    assert "final verify: MBR partition count is" not in bios
    assert "final verify: MBR partition count is" not in uefi


def test_success_preserves_uefi_transaction_until_windows_archives_it() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    verify_position = installer.index("final_verify_or_die")
    terminal_state_position = installer.index("complete_installation_state", verify_position)
    success_marker_position = installer.index(
        'write_windows_recovery_marker_best_effort "install-success"',
        terminal_state_position,
    )
    retire_position = installer.index(
        "firmware_retire_completed_transaction_best_effort", success_marker_position
    )

    assert verify_position < terminal_state_position < success_marker_position < retire_position
    assert "firmware_retire_completed_transaction_best_effort()" in bios
    assert "Windows startup verifier archives this transaction" in uefi
    assert "uefi-transaction.json" not in uefi
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")
    assert "function Save-UefiTransactionArchive" in agent
    assert 'Join-Path $State.RecoveryRoot "uefi-transaction.json"' in agent
    assert "Save-UefiTransactionArchive -State $State" in agent


def test_uefi_live_failure_restores_windows_settings_for_the_same_run() -> None:
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")
    installer = read("Scripts/libertix-uefi-install.ps1")
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")

    live_failure = agent.split("$failedRunId = Read-EnvValue -Path $liveFailed", 1)[1].split(
        "$startedRunId = Read-EnvValue -Path $liveStarted", 1
    )[0]
    assert "-RestoreWindowsSettings" in live_failure
    assert "-ExpectedRecoveryRunId" in live_failure
    assert "Remove-PendingWindowsSharePayload" in live_failure
    assert (
        'executionState.status -in @("failed", "rollback-running", "rolled-back")' in live_failure
    )
    assert "Read-ValidatedExecutionState" in agent
    assert "executionState.planId" in agent
    assert 'executionState.status -eq "succeeded"' in agent
    assert "Restore-LibertixTransactionWindowsSettings" in installer
    assert "Restore-LibertixTransactionWindowsSettings" in transaction
    assert "OriginalHibernateEnabled" in transaction


def test_uefi_recovery_cleanup_preserves_the_recovery_root() -> None:
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")
    tasks = agent.split("function Remove-RecoveryTasks", 1)[1].split(
        "function Remove-StartupRecoveryTask", 1
    )[0]
    cleanup = agent.split("function Remove-TemporaryRecoveryArtifacts", 1)[1].split(
        "function Save-UefiTransactionArchive", 1
    )[0]

    assert "Unregister-ScheduledTask" in tasks
    assert "Get-ScheduledTask" in tasks
    assert "Recovery task still exists after removal" in tasks
    assert "Remove-LibertixTransactionDownloads" in cleanup
    assert "Remove-LibertixUefiToolArtifacts" in cleanup
    assert "Remove-Item -LiteralPath $root -Recurse" not in agent


def test_interrupted_post_install_verification_keeps_startup_recovery_armed() -> None:
    bios = read("Scripts/libertix-recovery-guard.ps1")
    uefi = read("Scripts/libertix-uefi-recovery-agent.ps1")

    assert 'verificationStatus -in @("succeeded", "failed")' in bios
    assert "startup recovery remains armed" in bios
    assert "$terminalResultIsCoherent" in uefi
    assert '$verificationStatus -eq "succeeded"' in uefi
    assert '[string]$State.Phase -eq "Verified"' in uefi
    assert "startup recovery remains armed" in uefi
    assert "Remove-RecoveryTask -Required" in bios
    assert "Remove-StartupRecoveryTask -State $State" in uefi


def test_uefi_finalization_is_checkpointed_before_destructive_cleanup() -> None:
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")
    finalization = agent.split("function Invoke-VerifiedInstallationSuccess", 1)[1].split(
        "$executionState = Read-ValidatedExecutionState", 1
    )[0]
    archive = agent.split("function Save-UefiTransactionArchive", 1)[1].split(
        "function Set-FinalizationStep", 1
    )[0]

    ordered_operations = (
        "Save-UefiTransactionArchive -State $State",
        "Install-BootGuardianForCurrentBootPath -State $State",
        "Invoke-WindowsShareFinalize",
        "Restore-HibernationAfterInstallation -State $State",
        "Remove-TemporaryRecoveryArtifacts -State $State",
        "Invoke-LibertixPostInstallVerification",
        '$State.Phase = "Verified"',
    )
    positions = [finalization.index(operation) for operation in ordered_operations]
    assert positions == sorted(positions)
    assert '"Permanent UEFI transaction archive belongs to another recovery session."' in archive
    assert '"UEFI transaction state was already archived permanently."' in archive
    assert '"UEFI transaction state and its permanent archive are both missing."' in archive
    assert '"FinalizationPending"' in finalization
    assert "Set-FinalizationStep -State $State -Step" in finalization


def test_post_install_tasks_retry_abnormal_system_verifier_exits() -> None:
    bios = read("Scripts/libertix-register-bios-recovery-task.ps1")
    uefi = read("Scripts/libertix-register-uefi-recovery-tasks.ps1")

    for registration in (bios, uefi):
        assert "-RestartCount 3" in registration
        assert "-RestartInterval (New-TimeSpan -Minutes 1)" in registration
        assert "-Settings $startupSettings" in registration
        assert "-Settings $promptSettings" in registration


def test_linux_first_boot_service_finishes_or_resumes_during_shutdown() -> None:
    service = read("assets/live/first-boot-resize.service")
    resize = read("assets/live/first-boot-resize.sh")
    verifier = read("assets/live/libertix-first-boot-verify.py")

    assert "KillMode=mixed" in service
    assert "TimeoutStopSec=15min" in service
    assert "trap record_shutdown_request TERM INT HUP" in resize
    assert "--record-service-start" in resize
    assert '"shutdown-requested"' in resize
    assert 'FAILURE_DETAIL=""' in resize
    assert "FIRST_BOOT_VERIFICATION_ERROR=" in resize
    assert 'FAILURE_DETAIL="$(' in resize
    assert 'if VERIFICATION_OUTPUT="$("$VERIFIER" 2>&1)"; then' in resize
    assert 'return_failure "$VERIFICATION_RC"' in resize
    assert "--archive-service-diagnostics" in resize
    assert resize.index("--archive-service-diagnostics") < resize.index(
        "systemctl disable first-boot-resize.service"
    )
    assert 'echo "First boot resize' not in resize
    assert "SERVICE_STATE_PATH" in verifier
    assert '"interruptionCount"' in verifier
    assert '(SERVICE_STATE_PATH, "first-boot-service-state.json")' in verifier


def test_linux_first_boot_repairs_interrupted_package_configuration_before_verifying() -> None:
    resize = read("assets/live/first-boot-resize.sh")

    assert 'CURRENT_STAGE="package-manager-recovery"' in resize
    assert "interruptionCount" in resize
    assert "DEBIAN_FRONTEND=noninteractive dpkg --configure -a" in resize
    assert "dpkg --audit" in resize
    assert "Pending package configuration could not be resumed after 12 attempts." in resize
    development_ssh = read("assets/live/libertix-development-ssh-first-boot.sh")
    assert "empty host-key files" in development_ssh
    assert (
        "for ssh_host_key in /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub"
    ) in development_ssh
    assert '[ -s "$ssh_host_key" ] || rm -f -- "$ssh_host_key"' in development_ssh
    assert "ssh-keygen -A" in development_ssh
    assert "-name 'ssh_host_*_key' -size +0c" in development_ssh


def test_windows_recovery_waits_durably_for_the_first_installed_linux_boot() -> None:
    bios = read("Scripts/libertix-recovery-guard.ps1")
    uefi = read("Scripts/libertix-uefi-recovery-agent.ps1")
    result_ui = read("Scripts/libertix-post-install-result.ps1")
    module = read("Scripts/modules/Libertix.PostInstallVerification.psm1")

    assert 'status = "waiting-linux-boot"' in module
    assert 'waitingFor "installed-linux-boot.json"' not in module
    assert '"installed-linux-boot.json"' in module
    assert "Set-LibertixPostInstallWaitingForLinux" in bios
    assert "Set-LibertixPostInstallWaitingForLinux" in uefi
    assert 'Phase = "AwaitingInstalledLinuxBoot"' in uefi
    assert 'status -notin @("succeeded", "failed", "rolled-back")' in result_ui
    assert "installed-linux-boot.json" in result_ui
    assert result_ui.index("installed-linux-boot.json") < result_ui.index("AddMinutes(15)")
    assert "the two tasks raced each other" in result_ui
    assert "waitingAdviceAcknowledgedAtUtc" in result_ui
    assert "Start-RecoveryPromptTask" in bios
    assert "Start-PostInstallPromptTask -State $state" in uefi
    assert "waitingTitle" in result_ui


def test_offline_ntfs_resize_schedules_a_verified_windows_boot_repair() -> None:
    bios = read("Scripts/libertix-recovery-guard.ps1")
    uefi = read("Scripts/libertix-uefi-recovery-agent.ps1")
    module = read("Scripts/modules/Libertix.PostInstallVerification.psm1")

    assert "Invoke-LibertixWindowsFilesystemRepairIfRequired" in bios
    assert "Invoke-LibertixWindowsFilesystemRepairIfRequired" in uefi
    assert 'resizeMode -ne "live-offline"' in module
    assert 'status = "waiting-windows-filesystem-repair"' in module
    assert 'foreach ($answer in @("Y", "O", "S"))' in module
    assert "BootExecute" in module
    assert "scheduledFromBootId" in module
    assert "attemptCount -ge 2" in module
    assert "shutdown.exe /r /t 5" in bios
    assert "shutdown.exe /r /t 5" in uefi


def test_post_install_result_windows_are_branded_and_survive_shutdown_close() -> None:
    windows = read("Scripts/libertix-post-install-result.ps1")
    linux = read("assets/live/libertix-first-boot-result.py")
    target = read("assets/live/libertix-target-common.sh")
    builder = read("iso-tools/build-iso.sh")

    assert '$brand.Text = "Libertix"' in windows
    assert '"Images\\icon.ico"' in windows
    assert "New-Object Windows.Controls.Image" not in windows
    assert "$script:ResultAcknowledged = $false" in windows
    assert "if (-not $isWaitingForLinux -and $script:ResultAcknowledged)" in windows
    assert 'brand = gtk.Label(label="Libertix"' in linux
    assert "Libertix.ico" in linux
    assert "dialog.set_icon_from_file" in linux
    assert "gtk.Image.new_from_file" not in linux
    assert "Libertix.ico" in target
    assert "Resources/Images/icon.ico" in builder


def test_windows_post_install_checks_retry_transient_result_file_contention() -> None:
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")
    retry_reader = checks.split("function Read-JsonFileWithRetry", 1)[1].split(
        "function Get-LinuxDrive", 1
    )[0]
    finalization = checks.split('        "finalization" {', 1)[1].split(
        '        "final_state" {', 1
    )[0]

    assert "TimeoutMilliseconds = 10000" in retry_reader
    assert "Start-Sleep -Milliseconds 200" in retry_reader
    assert "throw" in retry_reader
    assert finalization.count("Read-JsonFileWithRetry -LiteralPath $resultPath") == 1
    assert "Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8" not in finalization
    assert "FailedChecks=" in finalization
    assert "LogPath=" in finalization


def test_auto_test_reports_guest_verifier_failures_with_persistent_log_context() -> None:
    postinstall = read("auto_tests/app/services/automation_postinstall.py")
    windows_checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")

    assert '"failedChecks": failed' in postinstall
    assert 'status = str(payload.get("status") or "unknown")' in postinstall
    assert 'error = str(payload.get("error") or "").strip()' in postinstall
    assert '"state_path": state_path' in postinstall
    assert '"log_path": log_path' in postinstall
    assert "Linux first-boot verification failed: {reason}" in postinstall
    assert "\"FailedChecks='$($failedChecks -join '; ')'. \"" in windows_checks
    assert "\"LogPath='$([string]$savedResult.logPath)'.\"" in windows_checks


def test_interactive_scheduled_tasks_tolerate_nonfatal_localized_stderr() -> None:
    for relative_path in (
        "auto_tests/app/scripts/launch_libertix_elevated.ps1",
        "auto_tests/app/scripts/focus_unattended_warning.ps1",
        "auto_tests/app/scripts/focus_post_install_result.ps1",
        "auto_tests/app/scripts/request_installation_cancellation.ps1",
    ):
        script = read(relative_path)
        assert "function Invoke-ScheduledTaskCommand" in script
        assert '$ErrorActionPreference = "Continue"' in script
        assert ".ExitCode -ne 0" in script
        assert '.AddMinutes(2).ToString("HH:mm")' in script
        assert "$createOutput = schtasks.exe" not in script


def test_completed_bios_recovery_proves_task_absence_after_structured_delete() -> None:
    bios = read("Scripts/libertix-recovery-guard.ps1")
    removal = bios.split("function Test-RootScheduledTaskExists", 1)[1].split(
        "function Start-RecoveryPromptTask", 1
    )[0]

    assert 'Get-ScheduledTask -TaskPath "\\" -ErrorAction Stop' in removal
    assert "Unregister-ScheduledTask" in removal
    assert "if (-not (Test-RootScheduledTaskExists -Name $Name))" in removal
    assert "schtasks.exe" not in removal


def test_temporary_artifact_check_preserves_permanent_rollback_metadata() -> None:
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")
    temporary = checks.split('"temporary_artifacts" {', 1)[1].split('"network" {', 1)[0]

    assert "The durable BIOS rollback metadata is missing." in temporary
    assert "The BIOS recovery transaction is still pending." not in temporary
    assert "$startupRecoveryTasks.Count -eq 0" in temporary
    assert "$promptTasks.Count -le 1" in temporary


def test_low_memory_mode_reaches_bios_and_uefi_configuration() -> None:
    apply_changes = read_apply_changes()
    plan_factory = read("Installation/InstallationPlanFactory.cs")
    uefi = read("Scripts/libertix-uefi-install.ps1")
    installer = read("assets/live/libertix-install-main.sh")
    assert ". /usr/local/lib/libertix/libertix-install-platform-common.sh" in installer
    assert "libertix-install-main.sh" in read("iso/live/libertix-install.sh")
    assert "libertix-install-main.sh" in read("iso-uefi/live/libertix-install.sh")

    assert "ConfigureBiosLowMemoryBoot" in apply_changes
    assert "LowMemoryMode =" in plan_factory
    assert "compatibility.LowMemoryMode" in apply_changes
    assert "$LowMemoryMode" in uefi
    assert "toram=filesystem.squashfs" in read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    assert "libertix-live.iso" not in apply_changes


def test_uefi_generated_grub_configs_preserve_low_memory_findiso_mode() -> None:
    execution = read("Scripts/uefi/Libertix.Uefi.Execution.ps1")
    storage = read("Scripts/uefi/Libertix.Uefi.Storage.ps1")
    staging = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    grub_config = execution.split("function Get-LibertixStagingGrubConfig", 1)[1].split(
        "function Write-Log", 1
    )[0]

    assert "[bool]$UseLowMemoryMode" in grub_config
    assert "$normalArguments = $normalArguments -replace" in grub_config
    assert "$verboseArguments = $verboseArguments -replace" in grub_config
    assert grub_config.count("toram=filesystem.squashfs") == 2
    assert grub_config.count("toram=filesystem\\.squashfs") == 2
    assert (
        "Get-LibertixStagingGrubConfig `\n        -UseLowMemoryMode ([bool]$LowMemoryMode)"
        in storage
    )
    assert (
        "Get-LibertixStagingGrubConfig `\n            -UseLowMemoryMode ([bool]$LowMemoryMode)"
        in staging
    )


def run_localized_stage_function(function: str, argument: str) -> subprocess.CompletedProcess[str]:
    shell_helper = ROOT / "assets/live/libertix-i18n.sh"
    python_helper = ROOT / "assets/live/libertix-i18n.py"
    stage_library = ROOT / "assets/live/libertix-runner-stage-common.sh"
    stage_catalogue = ROOT / "assets/live/libertix-stages.tsv"
    script = (
        '. "$1"; LANGUAGE_CODE=en; load_libertix_translations "$2"; '
        'LIBERTIX_STAGE_CATALOG="$3"; . "$4"; "$5" "$6"'
    )
    return subprocess.run(
        [
            "bash",
            "-c",
            script,
            "libertix-stage-test",
            str(shell_helper),
            str(python_helper),
            str(stage_catalogue),
            str(stage_library),
            function,
            argument,
        ],
        capture_output=True,
        text=True,
        check=False,
    )


def test_runner_stage_functions_return_stable_labels_and_percentages() -> None:
    label = run_localized_stage_function("libertix_stage_label", "120-unsquashfs")
    percent = run_localized_stage_function("libertix_stage_percent", "120-unsquashfs")
    bios_normalization = run_localized_stage_function(
        "libertix_stage_percent", "055-normalize-mbr-linux-slot"
    )
    unknown_label = run_localized_stage_function("libertix_stage_label", "custom-stage")

    assert label.returncode == 0
    assert label.stdout.strip() == "Extracting the Linux system"
    assert percent.returncode == 0
    assert percent.stdout.strip() == "54"
    assert bios_normalization.returncode == 0
    assert bios_normalization.stdout.strip() == "32"
    assert unknown_label.stdout.strip() == "custom-stage"


def test_every_literal_live_install_stage_is_declared() -> None:
    install = read("assets/live/libertix-install-main.sh")
    declared_stages = {
        line.split("\t", 1)[0]
        for line in read("assets/live/libertix-stages.tsv").splitlines()
        if line.strip()
    }
    requested_stages = set(re.findall(r'^mark "([^"]+)"$', install, re.MULTILINE))

    assert requested_stages <= declared_stages
    assert "105-verify-installer-iso" in requested_stages


def test_failure_shortcut_does_not_offer_reboot_before_verified_rollback() -> None:
    runner = read("assets/live/libertix-runner-main.sh")
    catalogue = json.loads(read("Resources/Libertix.Translations.json"))

    assert 'if [ "$rollback_status" = "completed" ]' in runner
    assert "$LIBERTIX_I18N_SHORTCUTS_FAILURE_BLOCKED" in runner
    for language in ("en", "fr", "es"):
        translations = catalogue["languages"][language]["live"]
        blocked = translations["shortcuts_failure_blocked"]
        assert "[R]" in blocked
        assert translations["shortcuts_failure"] != blocked


def test_shared_progress_helper_maps_unsquashfs_output(tmp_path: Path) -> None:
    log = tmp_path / "install.log"
    log.write_text(
        "STAGE: 120-unsquashfs\n123/246\nSTAGE: 130-target-system-config\n99%\n",
        encoding="utf-8",
    )
    result = subprocess.run(
        [
            "python3",
            str(ROOT / "assets/live/libertix_progress.py"),
            "--catalogue",
            str(ROOT / "assets/live/libertix-stages.tsv"),
            "--log",
            str(log),
            "--stage",
            "120-unsquashfs",
        ],
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "65\t50"


def test_uefi_copy_preserves_live_boot_case_sensitive_names() -> None:
    uefi = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")

    assert '$actualLiveDirectories[0].Name -cne "live"' in uefi
    assert "Live directory name case normalization failed" in uefi
    assert '"live\\filesystem.squashfs"' in uefi
    assert "$actual[0].Name -cne $expectedName" in uefi
    assert "Live file name case normalization failed" in uefi


def test_uefi_firmware_fallback_reuses_verified_prepared_installer() -> None:
    fallback = read("Pages/UefiBootFallback.xaml.cs")
    orchestration = read("Scripts/libertix-uefi-install.ps1")
    staging = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    transaction_module = read("Scripts/modules/Libertix.Transaction.psm1")

    assert "-BootStrategy FirmwareBootOrder -ReusePreparedInstaller" in fallback
    fallback_command = fallback.split("-BootStrategy FirmwareBootOrder", 1)[0].rsplit(
        "powershell,", 1
    )[1]
    assert "-Force" not in fallback_command

    assert "function Save-PreparedInstallerManifest" in transaction
    assert "function Assert-PreparedInstallerManifest" in transaction
    assert '"live\\filesystem.squashfs"' in transaction_module
    assert '"live\\initrd.img"' in transaction_module
    assert '"live\\vmlinuz"' in transaction_module
    assert '"EFI\\BOOT\\BOOTX64.EFI"' in transaction_module
    assert "Prepared installer SHA256 manifest verified" in transaction
    assert "Temporary ESP loader SHA256 verified" in staging

    reuse_path = orchestration.split("try {\n    if ($ReusePreparedInstaller)", 1)[1].split(
        "\n    Assert-LibertixPlanMatchesCurrentStorage\n", 1
    )[0]
    assert "Get-ReusablePreparedInstallerPartition" in reuse_path
    assert "Assert-PreparedInstallerManifest" in reuse_path
    assert "Set-LibertixUefiBootEntry" in reuse_path
    assert "-ReusePreparedInstaller" in reuse_path
    assert "Install-LibertixIsoToPartition" not in reuse_path
    assert "Start-RobustDownload" not in reuse_path
    assert "FALLBACK_REUSED_PREPARED_INSTALLER=true" in reuse_path

    boot_setup = staging.split("function Set-LibertixUefiBootEntry", 1)[1]
    assert "Remove-LibertixTemporaryFirmwareEntries" in boot_setup
    assert 'Remove-FirmwareVariable -Name "BootNext"' in boot_setup
    assert "Firmware BootOrder fallback verified" in boot_setup


def test_uefi_firmware_fallback_is_blocked_by_secure_boot_after_verified_restore() -> None:
    state_model = read("Helpers/UefiRecoveryState.cs")
    apply_changes = read("Pages/ApplyChanges.Uefi.cs")
    fallback = read("Pages/UefiBootFallback.xaml.cs")
    fallback_xaml = read("Pages/UefiBootFallback.xaml")
    recovery_agent = read("Scripts/libertix-uefi-recovery-agent.ps1")

    assert "public bool SecureBootEnabled { get; set; }" in state_model
    assert (
        "SecureBootEnabled = _installationState.Compatibility?.SecureBootEnabled == true"
        in apply_changes
    )
    assert "if (_state.SecureBootEnabled)" in fallback
    secure_boot_flow = fallback.split("private void ConfigureSecureBootFlow()", 1)[1].split(
        "private async void UefiBootFallback_Loaded", 1
    )[0]
    assert "FallbackButton.Visibility = Visibility.Collapsed" in secure_boot_flow
    assert "CancelButton.Visibility = Visibility.Collapsed" in secure_boot_flow
    assert "SecureBootCloseButton.Visibility = Visibility.Visible" in secure_boot_flow
    restore_flow = fallback.split("private async Task RestoreWindowsForSecureBootAsync()", 1)[
        1
    ].split("private async Task<int> RestoreWindowsAsync()", 1)[0]
    assert "await RestoreWindowsAsync()" in restore_flow
    assert "_secureBootRestored = true" in restore_flow
    assert restore_flow.index("await RestoreWindowsAsync()") < restore_flow.index(
        "_secureBootRestored = true"
    )
    assert "-Action Cancel" in fallback
    assert "-WaitForProcessId {processId}" in fallback
    assert "Remove-TemporaryRecoveryArtifacts" in recovery_agent
    assert "Remove-RecoveryTasks" in recovery_agent
    assert "Remove-Item -LiteralPath $root -Recurse" not in recovery_agent
    assert (
        "https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/"
        "disabling-secure-boot?view=windows-11" in fallback_xaml
    )


def test_uefi_firmware_reads_and_deletions_fail_closed() -> None:
    firmware = read("Scripts/uefi/Libertix.Uefi.Firmware.ps1")
    staging = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")

    reader = firmware.split("function Get-FirmwareVariableReadResult", 1)[1].split(
        "function Test-FirmwareVariableExists", 1
    )[0]
    deletion = firmware.split("function Remove-FirmwareVariable", 1)[1].split(
        "function Remove-FirmwareBootNumberFromOrder", 1
    )[0]
    fallback = staging.split("$fallbackEspDrive = $null", 1)[0].rsplit(
        'if ($BootStrategy -eq "BootNext")', 1
    )[1]

    assert "[LibertixFirmwareApi]::LastError()" in reader
    assert "$script:Win32ErrorEnvironmentVariableNotFound" in reader
    assert "$script:Win32ErrorNotFound" in reader
    assert "GetFirmwareEnvironmentVariable failed" in reader
    assert "DeleteFirmwareEnvironmentVariable" in deletion
    assert "if (-not $ok)" in deletion
    assert "still exists after deletion" in deletion
    assert 'Remove-FirmwareVariable -Name "BootNext"' in fallback
    assert "refusing a BootOrder fallback" in fallback
    assert "catch" not in fallback


def test_uefi_firmware_ownership_is_persisted_before_bootnext_or_bcd_followup() -> None:
    firmware = read("Scripts/uefi/Libertix.Uefi.Firmware.ps1")
    staging = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")

    assert "function Remove-TrackedLibertixFirmwareEntry" in firmware
    assert "Transaction state" in firmware
    assert "$null -eq $State.InstallerBootNumber" in firmware
    assert "[string]::IsNullOrWhiteSpace([string]$State.InstallerBootVariable)" in firmware
    boot_next = staging.split('if ($BootStrategy -eq "BootNext")', 1)[1].split(
        "$fallbackEspDrive = $null", 1
    )[0]
    assert boot_next.index("Update-TransactionFirmwareState") < boot_next.index(
        'Set-FirmwareVariable -Name "BootNext"'
    )
    bcd_create = firmware.split("function New-LibertixBcdFirmwareEntry", 1)[1]
    assert bcd_create.index("Update-TransactionBcdEntryState") < bcd_create.index(
        'Invoke-BcdeditCommand -Arguments @("/set", $entryId, "device"'
    )
    assert bcd_create.index("Update-TransactionFirmwareState") < bcd_create.index(
        "Get-EfiLoadOptionOptionalDataLength"
    )
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    bcd_owner = transaction.split("function Update-TransactionBcdEntryState", 1)[1].split(
        "function Get-ValidatedLibertixTransactionState", 1
    )[0]
    assert "RecoveryRunId -ne $RecoveryRunId" in bcd_owner
    assert "Save-LibertixTransactionStateAtomic" in bcd_owner


def test_uefi_temporary_artifacts_are_owned_by_the_recovery_run() -> None:
    orchestration = read("Scripts/libertix-uefi-install.ps1")
    firmware = read("Scripts/uefi/Libertix.Uefi.Firmware.ps1")
    storage = read("Scripts/uefi/Libertix.Uefi.Storage.ps1")
    staging = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    live = read("assets/live/libertix-uefi-adapter.sh")

    assert '"Libertix UEFI Installer $firmwareOwnerRunId"' in orchestration
    assert '$InstallerEspOwnershipFile = ".libertix-owner"' in orchestration
    assert "function Assert-LibertixTemporaryEspOwnership" in storage
    assert "belongs to another recovery run" in storage
    assert "Assert-LibertixTemporaryEspOwnership -Directory $destination" in staging
    assert "Remove-LibertixTemporaryEspFiles -EspDrive $esp" in transaction
    assert "does not contain exactly one canonical object identifier" in firmware
    assert "Could not parse exactly one canonical firmware entry identifier" in firmware
    assert 'expected_description="Libertix UEFI Installer $RECOVERY_RUN_ID"' in live
    assert "EFI/LibertixInstaller/.libertix-owner" in live
    assert "EFI/Libertix/.libertix-owner" in live
    assert 'LIBERTIX_FINAL_BOOTNUM="$bootnum"' in live
    assert '"$esp_guid"' in live
    assert '"$LIBERTIX_BOOT_LOADER" > "$efi_dir/.libertix-owner"' in live
    assert "find_exact_uefi_bootnumbers" in live
    assert "ensure_windows_bootentry_for_current_esp_or_die" in live
    installed_removal = firmware.split("function Remove-LibertixInstalledFirmwareEntries", 1)[
        1
    ].split("function Set-NativeUefiBootOrderOnce", 1)[0]
    assert "$bootNumberText" in installed_removal
    assert "Remove-NativeFirmwareEntriesByDescription" not in installed_removal
    assert 'efibootmgr -b "$bootnum" -B' in live


def test_release_restore_dismount_and_latest_logs_fail_closed() -> None:
    build = read("auto_tests/app/scripts/build_libertix.ps1")
    storage = read("Scripts/uefi/Libertix.Uefi.Storage.ps1")
    log_copy = read("assets/live/libertix-copy-logs.sh")

    restore = build.split("if ($releaseBackup -and (Test-Path -LiteralPath $releaseBackup))", 1)[1]
    assert "function Assert-PowerShellSyntax" in build
    assert "Assert-PowerShellSyntax -SourceRoot $srcLocal" in build
    assert "Management.Automation.Language.Parser" in build
    assert "Failed to restore the previous Libertix release" in restore
    assert (
        "Move-Item -LiteralPath $releaseBackup -Destination $releasePath -ErrorAction Stop"
    ) in restore

    dismount = storage.split("function Dismount-Letter", 1)[1].split(
        "function Get-FreeDriveLetter", 1
    )[0]
    assert "$removedWithPowerShell" in dismount
    assert "with PowerShell or diskpart" in dismount
    assert "still exists after PowerShell and diskpart" in dismount
    assert "continuing" not in dismount

    assert 'latest_staging="$log_root/.latest-$RUN_ID"' in log_copy
    assert 'latest_backup="$log_root/.latest-previous"' in log_copy
    assert 'cp -a "$log_dir/." "$latest_staging/"' in log_copy
    assert 'mv -- "$latest_staging" "$latest_dir"' in log_copy
    assert 'cp -a "$LOG_DIR/." "$log_root/latest/"' not in log_copy


def test_unattended_warning_is_a_single_fail_safe_keyboard_dialog() -> None:
    dialog_xaml = read("Dialogs/UnattendedWarningDialog.xaml")
    dialog_code = read("Dialogs/UnattendedWarningDialog.xaml.cs")
    wizard = read("auto_tests/app/services/automation_wizard.py")

    assert 'x:Name="NoButton"' in dialog_xaml
    assert 'TabIndex="0"' in dialog_xaml
    assert 'IsCancel="True"' in dialog_xaml
    assert 'x:Name="YesButton"' in dialog_xaml
    assert 'TabIndex="1"' in dialog_xaml
    assert 'IsDefault="False"' in dialog_xaml
    assert 'BorderBrush="{StaticResource ErrorColor}"' in dialog_xaml
    assert 'Background="{StaticResource ErrorColor}"' in dialog_xaml
    assert "UnattendedWarningTitle" in dialog_xaml
    assert "UnattendedWarningMessage" in dialog_xaml
    assert "{DynamicResource WarningMessage}" not in dialog_xaml
    assert "{DynamicResource WarningRisks}" not in dialog_xaml
    assert "{DynamicResource WarningRecommendations}" not in dialog_xaml
    assert '"warning-ready",' in dialog_code
    assert "timeoutSeconds: 45" in dialog_code
    assert "maximumAttempts = 3" in dialog_code
    decision_start = dialog_code.index("if (completed == dialog._decision.Task)")
    acknowledgement_after_decision = dialog_code.index("await acknowledgement;", decision_start)
    accepted_return = dialog_code.index("return true;", decision_start)
    assert acknowledgement_after_decision < accepted_return
    assert "finally" in dialog_code
    assert "if (dialog.IsVisible)" in dialog_code
    assert 'self._press_key(client, "tab", 0.25)' in wizard
    assert 'self._press_key(client, "enter", 0.5)' in wizard
    assert "AddSeconds(5)" in wizard
    assert "catch [IO.IOException]" in wizard
    assert "Start-Sleep -Milliseconds 50" in wizard
    assert "_set_warning_acknowledgement" not in wizard
    assert "_click_wizard_path" not in wizard


def test_unattended_mode_requires_a_development_channel_or_filepool() -> None:
    app = read("App.xaml.cs")
    guard = app.split("bool usesPublishedDevelopmentChannel", 1)[1].split(
        "RuntimeOptions = options;", 1
    )[0]

    assert "Build.IsDevelopment" in guard
    assert "Filepool.BaseUrl" in guard
    assert "Build.MetadataBaseUrl" in guard
    assert "!Filepool.IsDevelopmentMode" in guard
    assert "requires a development build channel" in guard


def test_forced_offline_ntfs_resize_is_explicit_and_development_only() -> None:
    startup = read("Helpers/StartupOptions.cs")
    app = read("App.xaml.cs")
    bios = read("Pages/ApplyChanges.Bios.cs")
    uefi = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")

    assert 'ForceOfflineNtfsResizeOption = "--force-offline-ntfs-resize"' in startup
    option = startup.split("ForceOfflineNtfsResizeOption", 2)[2].split(
        "// Ignoring a misspelled safety", 1
    )[0]
    assert "can only be specified once" in option
    assert "options.ForceOfflineNtfsResize = true" in option
    guard = app.split("if (options.ForceOfflineNtfsResize", 1)[1].split(
        "RuntimeOptions = options;", 1
    )[0]
    assert "!Filepool.IsDevelopmentMode" in guard
    assert "!usesPublishedDevelopmentChannel" in guard
    assert "requires a development build channel" in guard
    assert "RuntimeOptions.ForceOfflineNtfsResize" in bios
    assert 'resizeMode -eq "live-offline"' in uefi


def test_unattended_acknowledgement_reader_does_not_lock_out_the_controller() -> None:
    unattended = read("Helpers/UnattendedWorkflow.cs")

    assert "ReadCoordinationFile(options.AcknowledgementPath).Trim()" in unattended
    assert "FileShare.ReadWrite | FileShare.Delete" in unattended


def test_windows_process_tree_must_be_proven_stopped_before_rollback() -> None:
    runner = read("Helpers/WindowsProcessRunner.cs")
    termination = runner.split("public static bool TerminateProcessTree", 1)[1].split(
        "public static WindowsProcessResult Run", 1
    )[0]

    assert "taskKillCompleted && taskKill.ExitCode == 0 && process.HasExited" in termination
    assert "return treeTerminationProven;" in termination
    assert "return false;" in termination
    assert "Timed-out process tree could not be proven stopped" in runner


def test_linux_hostname_contract_is_identical_in_every_runtime() -> None:
    pattern = "^[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$"
    validator = read("Installation/InstallationPlanValidator.cs")
    account_policy = read("Installation/AccountPolicy.cs")
    powershell = read("Scripts/modules/Libertix.InstallationPlan.psm1")
    live = read("assets/live/libertix-installation-plan.py")
    schema = read("schemas/installation-plan.schema.json")

    assert "AccountPolicy.IsValidComputerName" in validator
    assert pattern in account_policy
    assert pattern in powershell
    assert pattern[1:-1] in live
    assert pattern in schema


def test_uefi_aria2_and_ext4_installer_timeouts_stop_their_processes() -> None:
    downloads = read("Scripts/uefi/Libertix.Uefi.Downloads.ps1")
    process_module = read("Scripts/modules/Libertix.Process.psm1")
    windows_share = read("Scripts/libertix-configure-windows-share.ps1")

    aria = downloads.split("function Start-Aria2Download", 1)[1].split(
        "function Start-RobustDownload", 1
    )[0]
    aria_arguments = downloads.split("function New-Aria2DownloadArguments", 1)[1].split(
        "function Start-Aria2Download", 1
    )[0]
    assert "Invoke-LibertixNativeProcess" in aria
    assert "-TimeoutSeconds 14400" in aria
    assert "ConvertTo-LibertixNativeArgument" in aria
    assert "& $aria2 @aria2Arguments" not in aria
    assert '"--dir=$DownloadDir"' in aria_arguments
    assert '"--continue=$continueValue"' in aria_arguments
    assert '"--max-tries=5"' in aria_arguments
    assert '"--retry-wait=10"' in aria_arguments
    assert '"--enable-color=false"' in aria_arguments
    assert "Push-Location" not in aria
    assert "$downloadPath -ne $destinationFullPath" in aria
    assert "Resuming the partial aria2 download" in aria
    assert "function ConvertTo-LibertixNativeArgument" in process_module
    assert "PROCESS_TREE_NOT_STOPPED:" in process_module
    assert '$_.Exception.Message -like "PROCESS_TREE_NOT_STOPPED:*"' in downloads

    timeout = windows_share.split("function Invoke-ProcessWithTimeout", 1)[1].split(
        "function Get-Config", 1
    )[0]
    assert 'taskkill.exe"' in timeout
    assert "/T /F" in timeout
    assert "$taskkillExitCode -ne 0 -or -not $process.HasExited" in timeout
    assert "process tree could not be proven stopped" in timeout


def test_ext4_installer_cannot_reopen_maintenance_ui_at_user_logon() -> None:
    windows_share = read("Scripts/libertix-configure-windows-share.ps1")
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")

    cleanup = windows_share.split("function Remove-VerifiedExt4InstallerResume", 1)[1].split(
        "function Get-Config", 1
    )[0]
    assert "Microsoft\\Windows\\CurrentVersion\\RunOnce" in cleanup
    assert '[string]$displayName.Value -eq "ext4-win-driver"' in cleanup
    assert '$_.PSObject.Properties["DisplayName"]' in cleanup
    assert '$_.PSObject.Properties["BundleCachePath"]' in cleanup
    assert "[string]$_.DisplayName" not in cleanup
    assert "[string]$_.BundleCachePath" not in cleanup
    assert "BundleCachePath" in cleanup
    assert "Get-FileHash" in cleanup
    assert "SetupSha256" in cleanup
    assert "PSChildName" in cleanup
    assert "$expectedCommand = '\"{0}\" /burn.runonce' -f $cachePath" in cleanup
    assert "Remove-ItemProperty" in cleanup
    assert "PSObject.Properties[$bundleCode]" in cleanup
    assert windows_share.index("Start-ReadOnlyMount -Config $config") < windows_share.index(
        "Remove-VerifiedExt4InstallerResume -Config $config"
    )

    ext4_check = checks.split('"ext4_driver"', 1)[1].split('"ext4_readonly_mount"', 1)[0]
    assert "ext4-win-driver.*setup\\.exe" in ext4_check
    assert "The ext4 installer is still running" in ext4_check
    assert "Microsoft\\Windows\\CurrentVersion\\RunOnce" in ext4_check
    assert "BundleCachePath" in ext4_check
    assert "The ext4 installer has a pending RunOnce resume" in ext4_check


def test_all_download_transports_enforce_bounded_file_sizes() -> None:
    downloads = read("Pages/ApplyChanges.Downloads.cs")
    processes = read("Pages/ApplyChanges.Processes.cs")
    types = read("Pages/ApplyChanges.Types.cs")
    windows_share = read("Pages/ApplyChanges.Windows.cs")
    uefi_downloads = read("Scripts/uefi/Libertix.Uefi.Downloads.ps1")
    uefi_staging = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    process_module = read("Scripts/modules/Libertix.Process.psm1")

    for name in (
        "MaximumLiveIsoBytes",
        "MaximumInstallerIsoBytes",
        "MaximumSupportArtifactBytes",
        "MaximumBootArtifactBytes",
    ):
        assert name in types
    assert "maximumBytes: MaximumLiveIsoBytes" in downloads
    assert "maximumBytes: MaximumInstallerIsoBytes" in downloads
    assert "maximumBytes: MaximumSupportArtifactBytes" in windows_share
    assert "response.Content.Headers.ContentLength" in downloads
    assert "totalRead > maximumBytes - bytesRead" in downloads
    assert "policyLimitExceeded:" in downloads
    assert "StreamingProcessCompletion.PolicyLimitExceeded" in downloads
    assert "policyLimitExceeded?.Invoke()" in processes

    boot_download = processes.split("private async Task<bool> DownloadFileAsync", 1)[1].split(
        "private async Task<bool> VerifySha256Async", 1
    )[0]
    assert "HttpCompletionOption.ResponseHeadersRead" in boot_download
    assert "MaximumBootArtifactBytes" in boot_download
    assert "ReadAsByteArrayAsync" not in boot_download

    assert "function Invoke-BoundedHttpDownload" in uefi_downloads
    assert "DOWNLOAD_SIZE_LIMIT_EXCEEDED:" in uefi_downloads
    assert "BytesTransferred" in uefi_downloads
    assert "BytesTotal" in uefi_downloads
    assert "-MonitoredFilePath $downloadPath" in uefi_downloads
    assert "-MaximumFileBytes $MaxBytes" in uefi_downloads
    assert "Invoke-WebRequest -Uri $Url -OutFile $Destination" not in uefi_downloads
    assert "MaximumDistributionIsoBytes = 8GB" in uefi_downloads
    assert "MaximumLiveIsoBytes = 2GB" in uefi_downloads
    assert "MinimumDistributionIsoBytes = 100MB" in uefi_downloads
    assert uefi_downloads.count("$script:MinimumDistributionIsoBytes") == 3
    assert "-MaxBytes $script:MaximumLiveIsoBytes" in uefi_staging
    assert "MaximumFileBytes" in process_module
    assert "Stop-LibertixNativeProcessTree" in process_module


def test_uefi_recovery_retires_only_the_exact_transaction_partition() -> None:
    state = read("Helpers/UefiRecoveryState.cs")
    creation = read("Pages/ApplyChanges.Uefi.cs")
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")

    for field in (
        "PlanId",
        "SystemDiskUniqueId",
        "SystemDiskPartitionTableId",
        "SystemDiskSize",
        "BootPartitionNumber",
        "BootPartitionOffset",
        "BootPartitionSize",
        "ExpectedLinuxPartitionOffset",
        "ExpectedLinuxPartitionSize",
    ):
        assert field in state
        assert field in creation
        assert field in agent
    partition_check = agent.split("function Test-LinuxPartitionPresent", 1)[1].split(
        "function Remove-RecoveryTasks", 1
    )[0]
    assert "[int64]$_.Offset -eq $expectedOffset" in partition_check
    assert "[int64]$_.Size -eq $expectedSize" in partition_check
    assert "gpt:" in partition_check
    assert "256MB" not in partition_check


def test_uefi_recovery_proves_firmware_bypass_before_offering_preferred_path() -> None:
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")
    firmware = read("Scripts/modules/Libertix.Firmware.psm1")
    firmware_read = read("Scripts/modules/Libertix.FirmwareRead.psm1")

    evidence = agent.split("function Get-FirmwareBootBypassEvidence", 1)[1].split(
        "function Remove-RecoveryTasks", 1
    )[0]
    assert "function Get-VerifiedEspPartition" in agent
    for required in (
        "Invoke-WithVerifiedEsp",
        ".libertix-owner",
        "BootCurrent",
        "BootOrder",
        "\\EFI\\Microsoft\\Boot\\bootmgfw.efi",
        "\\EFI\\Libertix\\shimx64.efi",
        "Test-EfiLoadOptionTargetsPartition",
        "firmware-retained-windows-first",
    ):
        assert required in evidence
    assert "$currentBootNumber -ne $firstBootNumber" in evidence
    assert "$firstBootNumber -eq $ownedBootNumber" in evidence
    assert "firmware-boot-bypass.json" in agent
    assert 'Phase = "InstalledBootBypassed"' in agent
    assert "Get-EfiLoadOptionHardDriveNodes" in firmware
    assert "GetFirmwareEnvironmentVariable" in firmware_read
    assert "SetFirmwareEnvironmentVariable" not in firmware_read
    prompt_flow = agent.split('if ($Action -eq "Prompt")', 1)[1].split(
        'if ($Action -eq "Cancel")', 1
    )[0]
    assert "Get-FirmwareBootBypassEvidence -State $state" in prompt_flow
    assert prompt_flow.index("Get-FirmwareBootBypassEvidence -State $state") < prompt_flow.index(
        "Start-PostInstallResultUi -State $state"
    )


def test_preferred_windows_path_is_transactional_and_avoids_grub_recursion() -> None:
    module = read("Scripts/modules/Libertix.PreferredBootPath.psm1")
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")
    target = read("assets/live/configure-target-main.sh")
    sync = read("assets/live/libertix-sync-efi.sh")
    preferred_sync = read("assets/live/libertix-preferred-boot-path.py")

    for required in (
        "bootmgfw.libertix-windows.efi",
        'Join-Path $State.RecoveryRoot "preferred-boot-path"',
        "Copy-LibertixPreferredPathFileAtomic",
        "Move-LibertixPreferredPathFileAtomic",
        "MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH",
        "Restore-LibertixPreferredBootPath",
        "secure-boot-chain.json",
        "PreferredPathOriginals",
        'Join-Path $ArchiveRoot "original-files"',
        'manifest["originalFiles"]',
        "Restore-LibertixPreferredPathOriginalFiles",
    ):
        assert required in module
    assert module.index("PreferredGrubRelativePath") < module.index("-Destination $windowsLoader")
    assert '"InstallPreferredPath"' in agent
    assert "Get-FirmwareBootBypassEvidence -State $state" in agent
    assert agent.index("Restore-PreferredBootPathIfPresent") < agent.index(
        "Restore-UefiTransactionArchive -State $state"
    )
    assert "set libertix_windows_loader=/EFI/Microsoft/Boot/bootmgfw.efi" in target
    assert "chainloader \\${libertix_windows_loader}" in target
    assert "export libertix_windows_loader" in module
    assert "export libertix_windows_loader" in preferred_sync
    assert "synchronize_preferred_boot_path" in sync
    assert "[IO.File]::Replace" not in module
    assert "Do not display the generic first-Linux-boot advice" in agent

    catalogue = json.loads(read("Resources/Libertix.Translations.json"))
    keys = {
        "UefiPreferredPathTitle",
        "UefiPreferredPathDescription",
        "UefiPreferredPathReady",
        "UefiPreferredPathUse",
        "UefiPreferredPathDetectedLog",
        "UefiPreferredPathPreparing",
        "UefiPreferredPathFailedFormat",
        "UefiPreferredPathRebootReady",
    }
    for language in catalogue["supportedLanguages"]:
        assert keys <= catalogue["languages"][language]["wpf"].keys()


def test_windows_share_and_postinstall_checks_bind_ext4_to_the_planned_partition() -> None:
    apply_changes = read("Pages/ApplyChanges.Windows.cs")
    share = read("Scripts/libertix-configure-windows-share.ps1")
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")

    for field in (
        "SystemDiskNumber",
        "SystemDiskUniqueId",
        "ExpectedLinuxPartitionOffset",
        "ExpectedLinuxPartitionSize",
        "PartitionSizeToleranceBytes",
    ):
        assert field in apply_changes
        assert field in share
    partition_lookup = share.split("function Get-LinuxPartition", 1)[1].split(
        "function Set-ReadOnlyDriverPolicy", 1
    )[0]
    assert "Get-Disk -Number" in partition_lookup
    assert ".UniqueId" in partition_lookup
    assert "[int64]$_.Offset -eq $expectedOffset" in partition_lookup
    assert "$minimum = $expected - [int64]$Config.PartitionSizeToleranceBytes" in partition_lookup
    assert "[int64]$_.Size -le $expected" in partition_lookup
    assert "[int64]$_.Size -ge $minimum" in partition_lookup
    assert "256MB" not in partition_lookup

    assert "function Get-ExpectedLinuxMountIdentity" in checks
    mount_identity = checks.split("function Get-ExpectedLinuxMountIdentity", 1)[1].split(
        "function Get-LibertixPostInstallControllerStatus", 1
    )[0]
    assert "[int64]$config.partition_alignment_bytes" in mount_identity
    assert "[int64]$_.Size -le $plannedSize" in mount_identity
    assert "[int64]$_.Size -ge ($plannedSize - $alignmentBytes)" in mount_identity
    readonly_check = checks.split('"ext4_readonly_mount"', 1)[1].split('"linux_home"', 1)[0]
    assert "$writableProcesses.Count -eq 0" in readonly_check
    assert "$ownedProcesses.Count -eq 1" in readonly_check
    assert "PhysicalDrive$($identity.DiskNumber)" in readonly_check
    assert "$identity.PartitionNumber" in readonly_check
    assert "mount-status.json" in readonly_check
    assert "$mountStatus.processId" in readonly_check
    assert "$mountStatus.processId -gt 0" in readonly_check


def test_auto_test_exercises_windows_before_linux_and_both_result_dialogs() -> None:
    postinstall = read("auto_tests/app/services/automation_postinstall.py")
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")
    focus_result = read("auto_tests/app/scripts/focus_post_install_result.ps1")
    result_dismissal = postinstall.split("def _capture_and_dismiss_post_install_result", 1)[
        1
    ].split("def _prepare_linux_graphical_session", 1)[0]

    assert '"check": "waiting_for_linux"' in postinstall
    assert 'grub_entry="windows"' in postinstall
    assert 'grub_entry="linux"' in postinstall
    assert postinstall.index('"check": "waiting_for_linux"') < postinstall.index(
        '"linux.first_boot_verification_ready"'
    )
    assert postinstall.count("self._capture_and_dismiss_post_install_result(") == 2
    assert '"waiting_for_linux" {' in checks
    assert '"explorer_integration" {' in checks
    assert '"post_install_result_ui" {' in checks
    assert '"post_install_result_ui_dismissed" {' in checks
    result_process_lookup = checks.split("function Get-PostInstallResultUiProcesses", 1)[1].split(
        "function Get-InteractiveUserProfile", 1
    )[0]
    assert "libertix-post-install-result\\.ps1" in result_process_lookup
    assert "libertix-uefi-recovery-agent\\.ps1" in result_process_lookup
    assert "-Action\\s+Prompt" in result_process_lookup
    assert 'Join-Path $Session.Root "state.json"' in result_process_lookup
    assert "$graphicalProcess.MainWindowHandle" not in result_process_lookup
    assert "AutomationElement]::ProcessIdProperty" in focus_result
    assert "AutomationElement]::RootElement.FindAll" in focus_result
    assert "$window.Current.IsOffscreen" in focus_result
    assert "LibertixPostInstallCloseButton" in focus_result
    assert "$attempt -lt 450" in focus_result
    assert '"/Query", "/TN", $taskName, "/V", "/FO", "LIST"' in focus_result
    assert 'script_name="focus_post_install_result.ps1"' in result_dismissal
    assert "timeout=60" in result_dismissal
    result_ui = checks.split('"post_install_result_ui" {', 1)[1].split(
        '"post_install_result_ui_dismissed" {', 1
    )[0]
    assert "Get-PostInstallResultUiProcesses" in result_ui
    assert "AwaitingInstalledLinuxBoot" in checks
    assert "first-boot-result-ack.json" in postinstall
    assert "guest-state-process-and-dismissal" in postinstall


def test_unattended_warning_keyboard_action_requires_proven_ui_focus() -> None:
    wizard = read("auto_tests/app/services/automation_wizard.py")
    focus_script = read("auto_tests/app/scripts/focus_unattended_warning.ps1")
    dialog = read("Dialogs/UnattendedWarningDialog.xaml")

    acceptance = wizard.split("def _accept_unattended_warning_dialog", 1)[1].split(
        "def _capture_from_client", 1
    )[0]
    observation = wizard.split("def _observe_unattended_wizard", 1)[1].split(
        "def _wait_for_unattended_stage", 1
    )[0]
    assert 'script_name="focus_unattended_warning.ps1"' in acceptance
    assert "self.vnc.connect" not in acceptance
    assert observation.index("warning_client = self.vnc.connect") < observation.index(
        "self._accept_unattended_warning_dialog"
    )
    assert observation.index("self._capture_and_acknowledge_unattended_stage") < observation.index(
        "warning_client.disconnect"
    )
    assert "UnattendedWarningNoButton" in focus_script
    assert "UnattendedWarningYesButton" in focus_script
    assert "$target.Current.HasKeyboardFocus" in focus_script
    assert "Set-LibertixControlFocus" in focus_script
    assert "$attempt -lt 450" in focus_script
    assert '"/Query", "/TN", $taskName, "/V", "/FO", "LIST"' in focus_script
    assert "timeout=60" in acceptance
    assert 'AutomationProperties.AutomationId="UnattendedWarningNoButton"' in dialog
    assert 'AutomationProperties.AutomationId="UnattendedWarningYesButton"' in dialog


def test_bios_post_install_prompt_hides_its_powershell_console() -> None:
    registration = read("Scripts/libertix-register-bios-recovery-task.ps1")
    prompt_arguments = registration.split("$promptArguments =", 1)[1].split("$promptAction =", 1)[0]

    assert "-WindowStyle Hidden" in prompt_arguments


def test_local_build_runs_the_same_powershell_quality_gates_as_ci() -> None:
    build = read("auto_tests/app/scripts/build_libertix.ps1")
    validation = read("auto_tests/app/services/validation.py")

    assert "Assert-PowerShellSyntax -SourceRoot $srcLocal" in build
    assert 'RequiredVersion "1.25.0"' in build
    assert "Invoke-ScriptAnalyzer" in build
    assert 'RequiredVersion "6.0.1"' in build
    assert "New-PesterConfiguration" in build
    assert "Invoke-Pester" in build
    assert 'Write-Result -Name "PSSCRIPTANALYZER"' in build
    assert 'Write-Result -Name "PESTER"' in build
    assert '"PSSCRIPTANALYZER"' in validation
    assert '"PESTER"' in validation


def test_windows_result_ui_waits_only_after_linux_evidence_and_verifies_explorer() -> None:
    result_ui = read("Scripts/libertix-post-install-result.ps1")
    share = read("Scripts/libertix-configure-windows-share.ps1")
    module = read("Scripts/modules/Libertix.PostInstallVerification.psm1")

    guard_start = result_ui.index(
        'if ([string]$result.status -notin @("succeeded", "failed", "rolled-back"))'
    )
    guard_end = result_ui.index("Complete-InteractiveWindowsShareVerification", guard_start)
    evidence_guard = result_ui[guard_start:guard_end]
    assert "installed-linux-boot.json" in evidence_guard
    assert "AddMinutes(15)" in evidence_guard
    assert evidence_guard.index("installed-linux-boot.json") < evidence_guard.index(
        "AddMinutes(15)"
    )
    assert 'Name "explorer-integration"' in result_ui
    assert "$closeButton.IsDefault = $true" in result_ui
    assert "$closeButton.Focus()" in result_ui
    assert "MountBroadcastDriveChange" in share
    assert 'Value "LocalSystem"' in share
    assert "Value 1" in share
    assert "mount-status.json" in share
    assert "pintohome" in share
    assert "Quick Access pin verified" in share
    assert "windows-read-only-linux-share" in module
    assert "SECURITY ERROR: the Windows ext4 mount accepted a write" in module


def test_windows_postinstall_checks_all_libertix_recovery_tasks() -> None:
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")

    helper = checks.split("function Get-LibertixRecoveryTasks", 1)[1].split(
        "function Get-ExpectedLinuxMountIdentity", 1
    )[0]
    for pattern in (
        "LibertixInstallRecovery",
        "LibertixUefiRecovery_*",
        "LibertixUefiRecoveryPrompt_*",
    ):
        assert pattern in helper
    assert checks.count("Get-LibertixRecoveryTasks") >= 4


def test_windows_finalization_does_not_count_the_result_prompt_as_recovery() -> None:
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")
    finalization = checks.split('"finalization" {', 1)[1].split('"final_state" {', 1)[0]

    assert '$_.TaskName -like "LibertixUefiRecovery_*"' in finalization
    assert '$_.TaskName -notmatch "Prompt"' in finalization


def test_boot_guardian_timeout_fixture_is_limited_to_the_lab_helper() -> None:
    fixture = read("auto_tests/app/scripts/test_boot_guardian_fault.ps1")
    service = read("BootGuardian/ServiceHost.cs")

    assert '"suspend-guardian"' in fixture
    assert '"resume-guardian"' in fixture
    assert "NtSuspendProcess" in fixture
    assert "NtResumeProcess" in fixture
    assert '"inspect-boot-order"' in fixture
    assert "NtSuspendProcess" not in service
    assert "NtResumeProcess" not in service


def test_uefi_fallback_publishes_recovery_phase_atomically() -> None:
    fallback = read("Pages/UefiBootFallback.xaml.cs")

    save_state = fallback.split("private void SaveState()", 1)[1].split(
        "private static string QuoteArgument", 1
    )[0]
    assert "AtomicJsonFile.Write(_statePath" in save_state
    assert "File.WriteAllText" not in save_state


def test_uefi_fallback_fails_closed_when_process_termination_is_unknown() -> None:
    fallback = read("Pages/UefiBootFallback.xaml.cs")

    assert "bool stopped;" in fallback
    assert "if (!stopped)" in fallback
    assert "ProcessTreeTerminationException" in fallback
    termination_handler = fallback.split("catch (ProcessTreeTerminationException ex)", 1)[1].split(
        "catch (Exception ex)", 1
    )[0]
    assert "FallbackButton.IsEnabled = true" not in termination_handler
    assert "CancelButton.IsEnabled = true" not in termination_handler
    click_handler = fallback.split("FallbackButton_Click", 1)[1].split("CancelButton_Click", 1)[0]
    assert click_handler.index("try") < click_handler.index("SaveState();")


def test_uefi_fallback_buttons_fit_long_localized_labels() -> None:
    fallback = read("Pages/UefiBootFallback.xaml")

    for button_name in (
        "CancelButton",
        "FallbackButton",
        "RebootButton",
        "SecureBootCloseButton",
    ):
        button = fallback.split(f'x:Name="{button_name}"', 1)[1].split("/>", 1)[0]
        assert 'Width="330"' in button
        assert 'Height="56"' in button
        assert 'Padding="20,8"' in button


def test_bios_copy_preserves_live_boot_case_sensitive_names() -> None:
    apply_changes = read_apply_changes()

    assert "NormalizeLiveBootNames(destDir)" in apply_changes
    assert "StringComparison.OrdinalIgnoreCase" in apply_changes
    assert '"filesystem.squashfs", "initrd.img", "vmlinuz"' in apply_changes
    assert "Live directory name case normalization failed" in apply_changes


def test_grub4dos_finds_the_staging_volume_instead_of_guessing_its_mbr_index() -> None:
    boot_arguments = read("Installation/LiveBootArguments.cs")

    assert '"find --set-root /installation-plan.json"' in boot_arguments
    assert '"root (hd0,' not in boot_arguments


def test_live_reuses_mbr_staging_partition_by_offset_not_windows_number() -> None:
    installer = read("assets/live/libertix-install-main.sh")

    assert (
        'LIVE_PART=$(partition_at_offset "$DISK" "$INSTALLER_PARTITION_OFFSET_BYTES"' in installer
    )
    assert "expected to reuse partition 3" not in installer


def test_live_initializes_the_disk_name_before_target_configuration() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    target = read("assets/live/libertix-target-common.sh")

    assert 'DISKNAME=""' in installer
    assert 'DISKNAME="$(basename "$DISK")"' in installer
    assert 'DISKNAME="$DISKNAME"' in target


def test_live_rollback_flag_is_initialized_before_any_error_trap() -> None:
    installer = read("assets/live/libertix-install-main.sh")

    assert "ROLLBACK_ATTEMPTED=false" in installer.split("trap on_err ERR", 1)[0]


def test_mbr_logical_partition_accepts_only_one_alignment_unit_of_shortfall() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    storage = read("assets/live/libertix-storage-common.sh")

    assert "maximum_partition_bytes=" in installer
    assert "installer_partition_target_bytes" in installer
    assert 'alignment_tolerance_bytes="${3:-${INSTALLER_ALIGNMENT_BYTES:-}}"' in storage


def test_live_manifest_survives_detached_toram_medium_and_fat_name_case() -> None:
    apply_changes = read_apply_changes()
    assert "PublishInstallationContextToLive" in apply_changes
    assert "installation-plan.json" in apply_changes

    adapters = (
        read("assets/live/libertix-bios-adapter.sh"),
        read("assets/live/libertix-uefi-adapter.sh"),
    )
    context = read("assets/live/libertix-live-context.sh")
    assert "/run/live/medium/installation-plan.json" in context
    assert 'plan="$mount_dir/installation-plan.json"' in context
    for adapter in adapters:
        assert "-name installation-plan.json" in adapter
        assert "Prerequisite timeout: disk_ready=$disk_ready config_ready=$config_ready" in adapter


def test_sharing_options_reach_both_live_installers() -> None:
    apply_changes = read_apply_changes()
    plan_loader = read("assets/live/libertix-installation-plan.sh")
    plan_exporter = read("assets/live/libertix-installation-plan.py")
    target = read("assets/live/libertix-target-common.sh")
    for variable in (
        "SHARE_WINDOWS_FILES_IN_LINUX",
        "SHARE_LINUX_FILES_IN_WINDOWS",
        "WINDOWS_PROFILES_JSON_BASE64",
    ):
        assert variable in plan_loader
        assert variable in target

    assert "ShareWindowsFilesInLinux" in apply_changes
    assert "ShareLinuxFilesInWindows" in apply_changes
    assert "WindowsProfilesJsonBase64" in apply_changes
    assert '"Default"' in apply_changes
    assert '"Default User"' in apply_changes
    assert '"WsiAccount"' in apply_changes
    assert "excludedProfiles.Contains(profileName)" in apply_changes

    assert '"WsiAccount"' in plan_exporter
    assert "project_windows_profiles" in plan_exporter


def test_mint_shortcuts_and_windows_mount_are_read_only_by_contract() -> None:
    target = read("assets/live/configure-target-main.sh")
    assert 'shortcut="User_$profile"' in target
    assert ".config/gtk-3.0/bookmarks" in target

    windows_share = read("Scripts/libertix-configure-windows-share.ps1")
    assert "--ro" in windows_share
    assert "winfsp-x64.dll" in windows_share
    assert "launchctl-x64.exe" in windows_share
    assert "New-ScheduledTaskTrigger -AtStartup" in windows_share
    assert "New-ScheduledTaskPrincipal" in windows_share
    assert '-UserId "SYSTEM"' in windows_share
    assert "Register-ScheduledTask" in windows_share
    assert "Start-ScheduledTask -TaskName $taskName" in windows_share
    assert "LibertixLinuxReadOnlyPin" in windows_share
    assert "New-ScheduledTaskTrigger -AtLogOn" in windows_share
    assert "Get-CimInstance Win32_UserProfile" in windows_share
    assert "-LogonType Interactive" in windows_share
    assert "-RunLevel Highest" in windows_share
    assert "Install-ExplorerPinTasks" in windows_share
    assert "[switch]$Pin" in windows_share
    assert "cmd.exe /d /c mklink /J" in windows_share
    assert '$junctionShellItem.Self.InvokeVerb("pintohome")' in windows_share
    assert "$quickAccess.Items()" in windows_share
    assert "Linux shortcut was not visible in Explorer Home/Quick Access" in windows_share
    assert "Start-ReadOnlyMount -Config $config" in windows_share
    assert "MountBroadcastDriveChange" in windows_share
    assert "-Name Recovery" in windows_share
    assert "status = [ordered]@{" in windows_share
    assert "readOnly = $true" in windows_share
    assert "Refusing to replace a non-junction path" in windows_share
    assert "Get-CimInstance Win32_UserProfile" in windows_share
    assert "Install-ExplorerShortcuts" in windows_share
    assert "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" in windows_share
    assert '& $launchCtl start "ext4-mount"' in windows_share
    assert "SECURITY ERROR: the Linux volume accepted a write despite --ro" in windows_share
    assert "Set-Service -Name ExtFsWatcher -StartupType Disabled" in windows_share


def test_installed_keyboard_layout_is_applied_once_after_the_desktop_starts() -> None:
    target = read("assets/live/configure-target-main.sh")
    target_common = read("assets/live/libertix-target-common.sh")
    first_session = read("assets/live/libertix-apply-keyboard-once.sh")

    assert "/etc/xdg/autostart/libertix-keyboard.desktop" in target
    assert "Exec=/usr/local/bin/libertix-apply-keyboard-once" in target
    assert "libertix-apply-keyboard-once.sh" in target_common
    assert ". /etc/default/keyboard" in first_session
    assert "setxkbmap \\" in first_session
    assert '-variant "${XKBVARIANT:-}"' in first_session
    assert 'KEYBOARD_VARIANT="$KEYBOARD_VARIANT"' in target_common
    assert 'XKBVARIANT="$KEYBOARD_VARIANT"' in target
    assert 'keyboard_source="${KEYBOARD_LAYOUT}+${KEYBOARD_VARIANT}"' in target
    assert 'marker_path="$marker_directory/keyboard-initialized.json"' in first_session
    assert "org.gnome.desktop.input-sources" in first_session
    assert "org.cinnamon.desktop.input-sources" in first_session
    assert "expected_sources=\"[('xkb', '$keyboard_source')]\"" in first_session
    assert 'gsettings set "$schema" sources "$expected_sources"' in first_session
    assert 'gsettings get "$schema" sources' in first_session
    assert '"status": "succeeded"' in first_session
    assert '[ ! -e "$marker_path" ] || exit 0' not in first_session
    assert "marker.get(key) == value" in first_session
    assert "all(marker.get(key) == value for key, value in expected.items())" in first_session


def test_ext4_setup_payload_matches_pinned_release_hash() -> None:
    setup = ROOT / "auto_tests/app/filepool/ext4-win-driver.exe"
    assert setup.is_file()
    assert hashlib.sha256(setup.read_bytes()).hexdigest() == (
        "967a001e6bd80de0af44b085c73097a96ea4ab0f5dd4d766cca4959231891031"
    )


def test_live_gui_uses_the_proven_direct_xorg_path() -> None:
    rootfs = read("assets/live/setup-live-rootfs.sh")
    runner = read("assets/live/libertix-runner-main.sh")

    assert "xinit" not in runner
    assert " xinit " not in rootfs
    assert '"$x_server" "$GUI_DISPLAY" "vt$GUI_VT"' in runner
    assert "-ac -noreset" in runner
    assert "XAUTHORITY=/dev/null /usr/local/sbin/libertix-gui" in runner


def test_live_gui_sets_a_visible_pointer_on_both_boot_paths() -> None:
    gui = read("assets/live/libertix-gui.py")
    runner = read("assets/live/libertix-runner-main.sh")

    assert 'option_add("*Cursor", "left_ptr")' in gui
    assert 'cursor="left_ptr"' in gui
    assert "xsetroot -cursor_name left_ptr" in runner


def test_live_reboot_is_only_offered_after_verified_rollback() -> None:
    gui = read("assets/live/libertix-gui.py")
    failure_branch = gui.split('elif success == "false" and rc is not None:', 1)[1]

    verified, unverified = failure_branch.split("else:", 1)
    assert 'rollback == "completed"' in verified
    assert "self.reboot_button.pack" in verified
    assert "self.reboot_button.pack_forget()" in unverified
    assert '["systemctl", "reboot", "-i"]' in gui


def test_live_failure_summary_stays_bounded_with_reachable_details() -> None:
    gui = read("assets/live/libertix-gui.py")

    assert "def compact_failure_value" in gui
    assert "maximum: int = 240" in gui
    assert "height=5" in gui
    assert 'anchor="nw"' in gui
    assert 'if stage.startswith("installer-failed-"):' in gui
    assert 'return label, 100, ""' in gui
    assert "self.details_button" in gui
    assert "self.details_frame.pack(fill=tk.BOTH, expand=True" in gui

    assert "self.root.bind_all(sequence, self.request_verified_failure_reboot)" in gui
    failure_reboot = gui.split("def request_verified_failure_reboot", 1)[1].split(
        "def draw_progress", 1
    )[0]
    assert 'result.get("LIBERTIX_INSTALL_SUCCESS") == "false"' in failure_reboot
    assert 'result.get("LIBERTIX_INSTALL_ROLLBACK") == "completed"' in failure_reboot

    inspector = read("auto_tests/app/scripts/inspect_live_failure.ps1")
    assert "$systemDrive = [string]$env:SystemDrive" in inspector
    assert 'Join-Path $systemDrive "LibertixInstallLogs\\Linux\\latest"' in inspector
    assert '"C:\\LibertixInstallLogs\\Linux\\latest"' not in inspector
    assert 'Read-EnvValue -Path $failurePath -Name "error"' in inspector
    assert 'Write-Output "LIVE_FAILURE_PRESENT=True"' in inspector


def test_windows_installation_can_be_cancelled_with_verified_rollback() -> None:
    xaml = read("Pages/ApplyChanges.xaml")
    cancellation = read("Pages/ApplyChanges.Cancellation.cs")
    apply_changes = read_apply_changes()

    assert 'x:Name="CancelInstallationButton"' in xaml
    assert 'Click="CancelInstallationButton_Click"' in xaml
    assert "_installationCancellation.Cancel()" in cancellation
    processes = read("Pages/ApplyChanges.Processes.cs")
    assert "WindowsProcessRunner.TerminateProcessTree(process)" in processes
    assert 'Arguments = $"/PID {processId} /T /F"' in read("Helpers/WindowsProcessRunner.cs")
    assert "FailBiosPreparationAndRollbackAsync" in cancellation
    assert '"ApplyChangesCancelledRestored"' in cancellation
    assert '"Installation cancelled. Windows has been restored."' in cancellation
    assert "QuoteArgument(scriptPath)} -Revert" in cancellation
    assert "observeCancellation: false" in cancellation
    assert "catch (OperationCanceledException)" in apply_changes


def test_unattended_failures_preserve_the_exact_cause_after_rollback() -> None:
    apply_changes = read("Pages/ApplyChanges.xaml.cs")
    cancellation = read("Pages/ApplyChanges.Cancellation.cs")
    bios = read("Pages/ApplyChanges.Bios.cs")
    uefi = read("Pages/ApplyChanges.Uefi.cs")

    assert "private void PublishUnattendedFailure(" in cancellation
    assert "UnattendedWorkflow.TryPublishFailure(errorCode, errorMessage);" in cancellation
    assert '"windows-preparation-failed",\n                    ex.Message' in apply_changes
    assert '$"{reason} Automatic rollback was verified."' in bios
    assert '$"{reason} Automatic rollback was verified."' in uefi
    assert '$"{reason} Automatic rollback could not be verified."' in bios
    assert '$"{reason} Automatic rollback could not be verified."' in uefi
    assert '"bios-artifact-preparation-failed",\n                reason' in bios
    assert "string persistedFailure = _executionLedger?.State?.Failure?.Message;" in uefi
    assert "string.IsNullOrWhiteSpace(persistedFailure)" in uefi


def test_process_termination_failure_never_starts_partition_rollback() -> None:
    apply_changes = read("Pages/ApplyChanges.xaml.cs")
    types = read("Pages/ApplyChanges.Types.cs")
    downloads = read("Pages/ApplyChanges.Downloads.cs")
    system = read("Pages/ApplyChanges.System.cs")
    uefi = read("Pages/ApplyChanges.Uefi.cs")

    assert "class UnterminatedProcessException" in types
    handler = apply_changes.split("catch (UnterminatedProcessException ex)", 1)[1].split(
        "catch (Exception ex)", 1
    )[0]
    assert "FailBiosPreparationAndRollbackAsync" not in handler
    assert "FinishInstallation(enableBackButton: false)" in handler
    assert "UnterminatedProcessException" in downloads
    assert "UnterminatedProcessException" in system
    assert "UnterminatedProcessException" in uefi


def test_bios_mutating_preflight_matches_armed_plan_before_bitlocker() -> None:
    preflight = read("Scripts/libertix-storage-preflight.ps1")
    system = read("Pages/ApplyChanges.System.cs")

    assert "[string]$ExpectedPlanPath" in preflight
    assert "function Assert-StorageMatchesExpectedPlan" in preflight
    assertion_position = preflight.index("Assert-StorageMatchesExpectedPlan `")
    decryption_position = preflight.index('Write-Output "BITLOCKER_ACTION=decrypting"')
    assert assertion_position < decryption_position
    assert "-ExpectedPlanPath {QuoteArgument(_installationPlanPath)}" in system


def test_bios_bootsequence_does_not_permanently_change_boot_manager_policy() -> None:
    bios = read("Pages/ApplyChanges.Bios.cs")

    assert '"Libertix BIOS Installer {_installationPlan.Runtime.RecoveryRunId}"' in bios
    assert '"/set {bootmgr} displaybootmenu no"' not in bios
    assert '"/timeout 0"' not in bios
    assert '"/default {current}"' not in bios
    assert 'RunBcdeditCommandAsync(bcdeditPath, $"/bootsequence {guid}")' in bios


def test_reboot_requests_are_bounded_checked_and_recoverable() -> None:
    apply_changes = read("Pages/ApplyChanges.xaml.cs")
    fallback = read("Pages/UefiBootFallback.xaml.cs")
    main_window = read("MainWindow.xaml.cs")

    for source in (apply_changes, fallback):
        assert "WindowsProcessRunner.Run(" in source
        assert '"shutdown.exe"' in source
        assert "WindowsProcessTimeouts.QuickCommand" in source
        assert "result.ExitCode != 0" in source
        assert "CancelSystemRestartPreparation" in source
    assert "public void CancelSystemRestartPreparation()" in main_window


def test_uefi_cancellation_before_recovery_session_is_read_only() -> None:
    cancellation = read("Pages/ApplyChanges.Cancellation.cs")

    assert "_activeFirmware == FirmwareType.Uefi && _activeUefiRecovery != null" in cancellation


def test_all_rollbacks_verify_bitlocker_against_the_pre_decryption_state() -> None:
    cancellation = read("Pages/ApplyChanges.Cancellation.cs")
    system = read("Pages/ApplyChanges.System.cs")
    storage = read("Installation/StoragePreflightInfo.cs")
    preflight = read("Scripts/libertix-storage-preflight.ps1")
    bios = read("Pages/ApplyChanges.Bios.cs")
    uefi = read("Pages/ApplyChanges.Uefi.cs")

    for field in (
        "InitialBitLockerConversionStatus",
        "InitialBitLockerEncryptionPercentage",
        "InitialBitLockerProtectionStatus",
    ):
        assert field in storage
        assert field in system
        assert field in cancellation
    assert "$initialBitLocker = $bitLocker" in preflight
    assert "initialBitLockerConversionStatus = [int]$initialBitLocker.ConversionStatus" in preflight
    assert "BitLockerMatchesInitialPreflightStateAfterRollbackAsync" in cancellation
    assert "BitLockerMatchesInitialPreflightStateAfterRollbackAsync" in bios
    assert "BitLockerMatchesInitialPreflightStateAfterRollbackAsync" in uefi
    assert "decryptBitLocker: false" in cancellation
    assert "observeCancellation: false" in cancellation
    assert "bool observeCancellation = true" in system
    assert "observeCancellation: observeCancellation" in system
    assert "firmware == FirmwareType.Bios && decryptBitLocker && !info.BitLockerSafe" in system
    assert "BitLocker did not " in cancellation
    assert "return to its initial state." in cancellation
    assert '"ApplyChangesBitLockerReenable"' in cancellation
    assert "BitLocker must be re-enabled in Windows" in cancellation


def test_windows_close_behavior_uses_tray_while_installation_runs() -> None:
    main = read("MainWindow.xaml.cs")
    state = read("Models/InstallationState.cs")
    tray = read("Helpers/TrayIconController.cs")

    assert "if (_installationState.IsInstallationRunning)" in main
    assert "HideInTrayDuringInstallation();" in main
    assert "LocalizedConfirmationDialog.Show(" in main
    assert 'ResourceText("ConfirmationYes", "Yes")' in main
    assert 'ResourceText("ConfirmationNo", "No")' in main
    assert "MessageBoxButton.YesNo" not in main
    assert "InstallationRunningChanged" in main
    assert "RestoreFromTray();" in main
    assert "ShowBalloonTip" in tray
    assert "Resources/Images/icon.ico" in tray
    assert "SystemIcons.Application.Clone()" in tray
    assert "SetInstallationRunning" in state


def test_installation_log_controls_preserve_manual_scroll_and_button_layout() -> None:
    xaml = read("Pages/ApplyChanges.xaml")
    apply_changes = read("Pages/ApplyChanges.xaml.cs")

    expand = xaml.split('x:Name="ExpandLogsButton"', 1)[1].split("/>", 1)[0]
    cancel = xaml.split('x:Name="CancelInstallationButton"', 1)[1].split("/>", 1)[0]
    append = apply_changes.split("private void AppendLogLine", 1)[1].split(
        "private void ExpandLogsButton_Click", 1
    )[0]

    assert 'Height="50"' in expand
    assert 'HorizontalAlignment="Right"' in cancel
    assert xaml.count('ScrollViewer.ScrollChanged="LogOutput_ScrollChanged"') == 2
    assert "double previousOffset" in append
    assert "DispatcherPriority.Background" in append
    assert "if (IsAutoScrollEnabled(output))" in append
    assert "forceScrollToEnd" not in append
    assert "SetAutoScrollEnabled(output, IsAtBottom(output))" in append
    assert "output.ScrollToEnd()" in append
    assert "output.ScrollToVerticalOffset(previousOffset)" in append


def test_wpf_sensitive_state_catalog_and_timeout_guards_are_enforced() -> None:
    warning = read("Pages/WarningConfirmation.xaml.cs")
    unattended_warning = read("Dialogs/UnattendedWarningDialog.xaml.cs")
    compatibility = read("Pages/CompatibilityCheck.xaml.cs")
    configurator = read("Installation/UnattendedInstallationConfigurator.cs")
    account = read("Pages/AccountCreation.xaml.cs")
    apply_changes = read("Pages/ApplyChanges.xaml.cs")
    apply_cancellation = read("Pages/ApplyChanges.Cancellation.cs")
    apply_bios = read("Pages/ApplyChanges.Bios.cs")
    apply_uefi = read("Pages/ApplyChanges.Uefi.cs")
    startup_options = read("Helpers/StartupOptions.cs")
    unattended = read("Helpers/UnattendedWorkflow.cs")
    downloads = read("Pages/ApplyChanges.Downloads.cs")
    processes = read("Pages/ApplyChanges.Processes.cs")
    atomic_json = read("Installation/AtomicJsonFile.cs")

    assert "_installationState.Account?.ClearPassword();" in warning
    assert "Dispatcher.BeginInvoke(" in warning
    assert "ConfirmCheckBox.IsChecked = true" not in warning
    assert '"warning-ready",' in unattended_warning
    assert "timeoutSeconds: 45" in unattended_warning
    assert "maximumAttempts = 3" in unattended_warning
    assert "UnattendedInstallationConfigurator.ConfigureAsync(" in compatibility
    assert "new ApplyChanges(_installationState)" in compatibility
    assert '"warning-accepted"' not in compatibility
    assert '"configuration-distribution-applied"' in configurator
    assert '"configuration-disk-size-applied"' in configurator
    assert '"configuration-sharing-applied"' in configurator
    assert '"configuration-account-applied"' in configurator
    assert 'PublishStageAndWaitAsync("installation-started")' in apply_changes
    assert (
        "UnattendedWorkflow.Complete();"
        not in apply_changes.split("ApplyChanges_Loaded", 1)[1].split(
            "private void LoadSummary", 1
        )[0]
    )
    assert 'PublishStageAndWaitAsync("reboot-ready")' in apply_cancellation
    assert '"installation-preparation-failed"' in apply_cancellation
    assert "await PublishUnattendedRebootReadyAsync();" in apply_bios
    assert "await PublishUnattendedRebootReadyAsync();" in apply_uefi
    assert "UnattendedWorkflow.Complete();" in apply_changes.split("RebootButton_Click", 1)[1]
    reboot_handler = apply_changes.split("RebootButton_Click", 1)[1].split(
        "private void UpdateProgress", 1
    )[0]
    assert reboot_handler.index("if (result.ExitCode != 0)") < reboot_handler.index(
        "UnattendedWorkflow.Complete();"
    )
    for page in (
        "Pages/Welcome.xaml.cs",
        "Pages/ChooseDistro.xaml.cs",
        "Pages/ResizeDisk.xaml.cs",
        "Pages/SharingOptionsPage.xaml.cs",
        "Pages/AccountCreation.xaml.cs",
        "Pages/WarningConfirmation.xaml.cs",
    ):
        assert "UnattendedWorkflow" not in read(page)
    assert "internal void CompleteUnattendedWorkflow()" in startup_options
    assert "Unattended = null;" in startup_options
    assert "RuntimeOptions.CompleteUnattendedWorkflow();" in unattended
    assert '["stage"] = "failed"' in unattended
    assert '["errorCode"] = safeCode' in unattended
    assert "TryPublishFailure(ex.Code, ex.Message);" in compatibility
    assert "DistributionCatalogLoader.LoadAsync(_filepool)" in read("Pages/ChooseDistro.xaml.cs")
    assert '"wpf-dispatcher-unhandled"' in read("App.xaml.cs")
    assert "ToLowerInvariant()" in account
    assert "new Lazy<ArtifactCatalog>" in apply_changes
    assert "ArtifactCatalog.LoadFromApplicationDirectory();" not in apply_changes
    assert downloads.count("when (!_installationCancellation.IsCancellationRequested)") >= 1
    assert "Boot artifact download timed out after 5 minutes" in processes
    assert "Exception writeFailure = null;" in atomic_json
    assert "when (writeFailure != null)" in atomic_json


def test_windows_launch_requires_a_visible_uia_main_window() -> None:
    launch = read("auto_tests/app/scripts/launch_libertix_elevated.ps1")
    confirm = read("auto_tests/app/scripts/confirm_libertix_process.ps1")

    for script in (launch, confirm):
        assert "AutomationElement]::FromHandle" in script
        assert ".Current.IsOffscreen" in script
        assert "$bounds.Width -ge 100 -and $bounds.Height -ge 100" in script
        assert "WINDOW_VISIBLE" in script
        assert "ParentProcessId=" in script
        assert "RUNTIME_EXECUTABLE" in script
    assert "launcher displayed an error" in launch


def test_post_install_login_typing_requires_a_proven_guest_login_screen() -> None:
    postinstall = read("auto_tests/app/services/automation_postinstall.py")
    windows_probe = read("auto_tests/app/scripts/inspect_windows_graphical_session.ps1")

    assert '"LIBERTIX_GREETER_READY" not in response.stdout' in postinstall
    assert 'values.get("LOGIN_SCREEN_PRESENT") != "True"' in postinstall
    assert "Name='LogonUI.exe'" in windows_probe
    assert "LOGIN_SCREEN_PRESENT" in windows_probe


def test_distribution_catalogue_key_is_embedded_and_payloads_are_bounded() -> None:
    project = read("Libertix.csproj")
    loader = read("Installation/DistributionCatalogLoader.cs")
    trust = read("Installation/DistributionCatalogTrust.cs")

    key_entry = project.split(
        '<EmbeddedResource Include="Scripts\\config\\Libertix.CatalogPublicKey.xml">',
        1,
    )[1].split("</EmbeddedResource>", 1)[0]
    assert "Libertix.Resources.CatalogPublicKey.xml" in key_entry
    assert "CopyToOutputDirectory" not in key_entry
    assert "VerifyWithApplicationKey" in loader
    assert "BoundedHttpContent.ReadAsync" in loader
    assert "MaximumCatalogBytes" in loader
    assert "GetManifestResourceStream" in trust


def test_optional_uefi_detail_progress_is_not_bound_as_null() -> None:
    execution = read("Scripts/uefi/Libertix.Uefi.Execution.ps1")
    progress = execution.split("function Write-LibertixProgress", 1)[1].split(
        "function Test-LibertixTrackedExecution", 1
    )[0]

    assert "if ($null -ne $DetailPercent)" in progress
    assert "$progressArguments.DetailPercent = [int]$DetailPercent" in progress
    assert "Set-LibertixExecutionProgress @progressArguments" in progress
    assert "-DetailPercent $DetailPercent" not in progress


def test_bios_adapter_resolves_partition_table_without_ambient_state() -> None:
    bios = read("assets/live/libertix-bios-adapter.sh")

    assert "bios_partition_table_or_die()" in bios
    assert bios.count("bios_partition_table_or_die >/dev/null") == 3
    assert "$PART_TABLE" not in bios


def test_uefi_adapter_resolves_partition_table_without_ambient_state() -> None:
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    assert "uefi_partition_table_or_die()" in uefi
    assert uefi.count('partition_table="$(uefi_partition_table_or_die)"') == 2
    assert "$PART_TABLE" not in uefi


def test_live_unhandled_exit_guard_routes_nounset_failures_to_rollback() -> None:
    main = read("assets/live/libertix-install-main.sh")

    assert "on_exit()" in main
    assert "trap on_exit EXIT" in main
    assert "set +u" in main
    assert 'fail_and_exit "$rc" "unhandled shell exit' in main


def test_windows_boot_tasks_do_not_launch_visible_command_windows() -> None:
    apply_changes = read("Pages/ApplyChanges.xaml.cs")
    recovery_tasks = read("Scripts/libertix-register-uefi-recovery-tasks.ps1")
    share = read("Scripts/libertix-configure-windows-share.ps1")

    assert "run-recovery-agent.cmd" not in apply_changes
    assert "run-recovery-prompt.cmd" not in apply_changes
    assert "-WindowStyle Hidden -ExecutionPolicy Bypass -File" in recovery_tasks
    assert "-WindowStyle Hidden -ExecutionPolicy Bypass -File" in share
    assert "New-ScheduledTaskTrigger -AtStartup" in share
    assert 'UserId "SYSTEM"' in share


def test_windows_preparation_log_is_persisted_for_every_gui_line() -> None:
    cancellation = read("Pages/ApplyChanges.Cancellation.cs")
    apply_changes = read("Pages/ApplyChanges.xaml.cs")

    assert "RuntimeNames.InstallationLogDirectory" in cancellation
    assert "AppendPersistentLog(line);" in apply_changes


def test_filepool_defaults_to_a_signed_build_channel_and_supports_an_override() -> None:
    filepool = read("Helpers/FilepoolConfig.cs")
    build = read("Helpers/ApplicationBuild.cs")
    startup = read("Helpers/StartupOptions.cs")
    app = read("App.xaml.cs")
    launch = read("auto_tests/app/scripts/launch_libertix_elevated.ps1")

    assert 'GitHubPagesBaseUrl = "https://ekimiateam.github.io/libertix"' in build
    assert "return new FilepoolConfig(\n                build.MetadataBaseUrl," in filepool
    assert 'FilepoolOption = "--filepool-base-url"' in startup
    assert 'DevelopmentSshStaticIpOption = "--dev-ssh-static-ip"' in startup
    assert 'DevelopmentSshPrefixLengthOption = "--dev-ssh-prefix-length"' in startup
    assert 'DevelopmentSshGatewayOption = "--dev-ssh-gateway"' in startup
    assert 'DevelopmentSshDnsOption = "--dev-ssh-dns"' in startup
    assert "FilepoolConfig.TryCreate(" in app
    assert "public sealed class FilepoolConfig" in filepool
    assert "public string BaseUrl { get; }" in filepool
    assert "public bool RequiresCatalogSignature => _requiresCatalogSignature;" in filepool
    assert "public bool IsDevelopmentMode => _isDevelopmentOverride;" in filepool
    assert "public static string BaseUrl" not in filepool
    assert "DEVELOPMENT MODE - catalog signature verification is disabled." in read(
        "MainWindow.xaml"
    )
    main_window = read("MainWindow.xaml")
    main_window_code = read("MainWindow.xaml.cs")
    assert 'Panel.ZIndex="1000"' in main_window
    assert 'VerticalAlignment="Top"' in main_window
    assert 'IsHitTestVisible="False"' in main_window
    assert 'Grid.Row="1"' not in main_window
    assert "Height += DevelopmentModeBanner.Height" not in main_window_code
    assert "MinHeight += DevelopmentModeBanner.Height" not in main_window_code
    assert "application.Filepool.IsDevelopmentMode" in read("MainWindow.xaml.cs")
    assert "$useDefaultFilepool" in launch
    assert "if (-not $useDefaultFilepool)" in launch
    assert "$applicationArguments += ' --filepool-base-url \"{0}\"' -f $filepoolBaseUrl" in launch
    assert '--dev-ssh-static-ip "{0}"' in launch
    assert '--dev-ssh-prefix-length "{0}"' in launch
    assert '--dev-ssh-gateway "{0}"' in launch
    assert '--dev-ssh-dns "{0}"' in launch


def test_libertix_launch_proves_the_identified_interactive_window() -> None:
    launch = read("auto_tests/app/scripts/launch_libertix_elevated.ps1")
    confirmation = read("auto_tests/app/scripts/confirm_libertix_process.ps1")

    for script in (launch, confirmation):
        assert "function Test-VisibleMainWindow" in script
        assert "MainWindowHandle -eq [IntPtr]::Zero" in script
        assert 'MainWindowTitle -ne "Libertix"' in script
        assert "Current.IsOffscreen" in script
        assert "$bounds.Width -ge 100 -and $bounds.Height -ge 100" in script
        assert "WINDOW_HANDLE" in script
        assert "WINDOW_TITLE" in script

    assert "[switch]$InteractiveWorker" in launch
    assert "function Invoke-InteractiveWorker" in launch
    assert "Start-Process" in launch
    assert "$launcherProcess.WaitForExit()" in launch
    assert "window_width = [int]$bounds.Width" in launch
    assert "window_height = [int]$bounds.Height" in launch
    assert "The interactive Libertix worker did not report a result" in launch


def test_development_ssh_is_installed_only_from_the_explicit_plan_flag() -> None:
    target = read("assets/live/configure-development-access.sh")
    first_boot = read("assets/live/libertix-development-ssh-first-boot.sh")
    unit = read("assets/live/libertix-development-ssh.service")
    automation = read("auto_tests/app/services/automation.py")
    validation = read("auto_tests/app/services/validation.py")
    launch_script = read("auto_tests/app/scripts/launch_libertix_elevated.ps1")

    assert '[ "${DEVELOPMENT_SSH_ENABLED:-false}" = "true" ] || exit 0' in target
    assert "autoconnect-priority=1000" in target
    assert "address1=$DEVELOPMENT_STATIC_IPV4_ADDRESS/" in target
    assert "command -v sshd >/dev/null 2>&1 && return 0" in first_boot
    assert "local attempt max_attempts=6 retry_delay_seconds" in first_boot
    assert "Acquire::http::No-Cache=true" in first_boot
    assert "Acquire::https::No-Cache=true" in first_boot
    assert first_boot.index("update \\") < first_boot.index("install -y --no-install-recommends")
    assert "retry_delay_seconds=$((attempt * 10))" in first_boot
    assert "openssh-server" in first_boot
    assert "PasswordAuthentication yes" in target
    assert "PermitRootLogin no" in target
    assert "AllowUsers $USERNAME" in target
    assert "sshd_policy=/etc/ssh/sshd_config.d/90-libertix-development.conf" in first_boot
    assert 'grep -Fx "AllowUsers $username" "$sshd_policy"' in first_boot
    assert first_boot.index("install -d -m 0755 /run/sshd") < first_boot.index("/usr/sbin/sshd -t")
    assert "After=network-online.target" in unit
    assert "launch_elevated_process(" in automation
    assert "force_offline_ntfs_resize=options.force_offline_ntfs_resize" in automation
    assert "if ($forceOfflineNtfsResize)" in launch_script
    assert "$applicationArguments += ' --force-offline-ntfs-resize'" in launch_script
    assert '"development_static_ipv4": vm.host' in validation
    assert '"development_dns_servers": list(self.settings.development_dns_servers)' in validation
    postinstall = read("auto_tests/app/services/automation_postinstall.py")
    assert "test -e /var/lib/libertix/development-ssh-ready" in postinstall


def test_windows_integrity_check_preserves_preexisting_boot_drive_letter() -> None:
    script = read("auto_tests/app/scripts/check_windows_integrity.ps1")

    assert "$bootLetter = [string]$mountedBootPartition.DriveLetter" in script
    assert "if ([string]::IsNullOrWhiteSpace($bootLetter))" in script
    assert "$bootLetterWasAssigned = $true" in script
    assert "$mountedBootPartition -and $bootLetterWasAssigned -and $bootLetter" in script


def test_uefi_early_revert_does_not_require_absent_transaction_state() -> None:
    revert = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1").split("function Invoke-Revert", 1)[
        1
    ]

    assert "Remove-LibertixInstallerPartitionIfPresent" in revert
    assert "No transaction state found; $SystemDrive was not resized by this run." in revert
    assert "Cannot restore $SystemDrive without the saved transaction state." not in revert


def test_uefi_revert_does_not_require_download_configuration() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
    validation = script.split("# Networking defaults", 1)[0].rsplit(
        "# A rollback only consumes", 1
    )[1]
    downloads = script.split("# Download hashes and names", 1)[1].split("# Defaults", 1)[0]

    assert (
        "if (-not $Revert -and -not $RestoreWindowsSettings -and -not $RecoverPreviousTransaction)"
    ) in validation
    assert "FilepoolBaseUrl is required" in validation
    assert (
        "if (-not $Revert -and -not $RestoreWindowsSettings -and -not $RecoverPreviousTransaction)"
    ) in downloads
    assert "New-LibertixDownloadUrls" in downloads


def test_uefi_configuration_requires_the_versioned_installation_plan() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
    config_block = script.split("if (-not [string]::IsNullOrWhiteSpace($ConfigPath))", 1)[1].split(
        "$installationPlan = $null", 1
    )[0]

    assert 'Properties.Name -contains "InstallationPlanPath"' in config_block
    assert 'Properties.Name -contains "ExecutionStatePath"' in config_block
    assert "LinuxUsername" not in config_block
    assert "LinuxPasswordHash" not in config_block


def test_powershell_atomic_writers_use_real_same_directory_backups() -> None:
    atomic_module = read("Scripts/modules/Libertix.AtomicFile.psm1")
    assert "$script:AtomicPublishAttempts = 8" in atomic_module
    assert "Test-LibertixTransientAtomicPublishFailure" in atomic_module
    assert "Start-Sleep -Milliseconds (25 * $attempt)" in atomic_module

    for module_path in (
        "Scripts/modules/Libertix.InstallationPlan.psm1",
        "Scripts/modules/Libertix.InstallationState.psm1",
    ):
        module = read(module_path)
        atomic_writer = module.split("function Write-Libertix", 1)[1].split(
            "function Read-Libertix", 1
        )[0]

        assert "$backupPath = Join-Path" in atomic_writer
        assert "$directory" in atomic_writer
        assert "ToString('N')).bak\"" in atomic_writer
        assert "Publish-LibertixFileAtomic" in atomic_writer
        assert "[IO.File]::Replace($temporaryPath, $fullPath, $null)" not in atomic_writer
        assert "[IO.File]::Delete($backupPath)" in atomic_writer


def test_uefi_rollback_uses_the_validated_runtime_owner_for_download_cleanup() -> None:
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    rollback = transaction.split("function Invoke-Revert", 1)[1]

    assert rollback.count("-PlanId $RecoveryRunId") == 2
    assert "-PlanId $ExpectedRecoveryRunId" not in rollback


def test_uefi_previous_transaction_is_recovered_before_a_new_plan_or_payload() -> None:
    apply = read("Pages/ApplyChanges.xaml.cs")
    uefi = read("Pages/ApplyChanges.Uefi.cs")
    installer = read("Scripts/libertix-uefi-install.ps1")
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    storage = read("Scripts/uefi/Libertix.Uefi.Storage.ps1")

    recovery_call = apply.index("RecoverPreviousUefiTransactionAsync()")
    share_payload = apply.index("PrepareWindowsSharePayloadAsync()")
    new_session = uefi.index("CreateUefiRecoverySession()")
    recovery_method = uefi.index("private async Task<bool> RecoverPreviousUefiTransactionAsync()")

    assert recovery_call < share_payload
    assert recovery_method < new_session
    assert '"-RecoverPreviousTransaction"' in uefi
    assert "[switch]$RecoverPreviousTransaction" in installer
    assert "Get-ValidatedLibertixTransactionState" in installer
    assert "A completed UEFI installation still owns the active transaction" in installer
    assert "LIBERTIX_PREVIOUS_TRANSACTION=none" in uefi
    assert "LIBERTIX_PREVIOUS_TRANSACTION=recovered" in uefi
    assert "Volatile.Read(ref recoveryDispositionSeen) == 1" in uefi
    assert "Assert-LibertixTransactionRecoveryRunId" in installer
    assert "Remove-LibertixRecoveryTasksForRunId" in transaction
    assert "Save-LibertixRollbackTransactionArchive" in transaction
    assert "Get-VerifiedTransactionPartition -AllowMissing" in storage


def test_uefi_rollback_validates_owner_before_touching_firmware_or_storage() -> None:
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    rollback = transaction.split("function Invoke-Revert", 1)[1]

    identity_check = rollback.index("Assert-LibertixTransactionRecoveryRunId")
    mount_esp = rollback.index("Mount-Esp")
    remove_partition = rollback.index("Remove-LibertixInstallerPartitionIfPresent")
    archive = rollback.index("Save-LibertixRollbackTransactionArchive")
    complete_ledger = rollback.index("Complete-LibertixTrackedRollback")
    remove_active_state = rollback.index("Remove-Item -LiteralPath $TransactionStatePath")

    assert identity_check < mount_esp < remove_partition
    assert complete_ledger < archive < remove_active_state


def test_uefi_rollback_archive_reloads_the_latest_validated_transaction_state() -> None:
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    archive = transaction.split("function Save-LibertixRollbackTransactionArchive", 1)[1].split(
        "function Remove-LibertixRecoveryTasksForRunId", 1
    )[0]

    assert "$state = Get-ValidatedLibertixTransactionState" in archive
    assert "Save-LibertixTransactionStateAtomic -State $state" in archive
    assert "param([Parameter(Mandatory = $true)]$State)" not in archive


def test_uefi_rollback_preserves_active_owner_until_the_ledger_is_terminal() -> None:
    installer = read("Scripts/libertix-uefi-install.ps1")
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    artifacts = read("Scripts/modules/Libertix.TemporaryArtifacts.psm1")
    rollback = transaction.split("function Invoke-Revert", 1)[1]

    assert "[switch]$PreserveTransactionState" in artifacts
    assert "-PreserveTransactionState" in rollback
    assert rollback.index("Complete-LibertixTrackedRollback") < rollback.index(
        "Save-LibertixRollbackTransactionArchive"
    )
    assert rollback.index("Save-LibertixRollbackTransactionArchive") < rollback.index(
        "Remove-Item -LiteralPath $TransactionStatePath"
    )
    assert installer.count("Complete-LibertixTrackedRollback") == 0


def test_uefi_explicit_rollback_reloads_and_tracks_its_durable_context() -> None:
    installer = read("Scripts/libertix-uefi-install.ps1")
    execution = read("Scripts/uefi/Libertix.Uefi.Execution.ps1")
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    revert = installer.split("if ($Revert) {", 1)[1].split("if ($RestoreWindowsSettings)", 1)[0]

    assert "function Get-LibertixDurableRecoveryContext" in installer
    assert "Get-LibertixDurableRecoveryContext -RunId $ExpectedRecoveryRunId" in revert
    assert "$installationPlan = $rollbackContext.Plan" in revert
    assert "$ExecutionStatePath = $rollbackContext.StatePath" in revert
    assert "UEFI recovery execution state is pending" in revert
    assert '@("running", "failed", "succeeded")' in execution
    rollback = transaction.split("function Invoke-Revert", 1)[1]
    assert rollback.index("UEFI transaction state is missing while rollback still requires") < (
        rollback.index("Mount-Esp")
    )


def test_uefi_installer_partition_paths_use_available_drive_letters() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    create_or_reuse = script.split("function New-OrReuseInstallerPartition", 1)[1].split(
        "function Get-ReusablePreparedInstallerPartition", 1
    )[0]
    prepared_reuse = script.split("function Get-ReusablePreparedInstallerPartition", 1)[1].split(
        "function Install-LibertixIsoToPartition", 1
    )[0]

    assert "$existingDriveLetter = Get-LibertixFreeDriveLetter" in create_or_reuse
    assert "-NewDriveLetter $existingDriveLetter" in create_or_reuse
    create_position = create_or_reuse.index("$newPartition = New-Partition")
    format_position = create_or_reuse.index("Format-Volume", create_position)
    assign_position = create_or_reuse.index("Add-PartitionAccessPath", format_position)
    assert "-AssignDriveLetter" not in create_or_reuse[create_position:format_position]
    assert "-Partition $newPartition" in create_or_reuse[format_position:assign_position]
    assert "-AssignDriveLetter" in create_or_reuse[assign_position:]
    assert "$createdDriveLetter = [string]$verifiedPartition.DriveLetter" in create_or_reuse
    assert 'Test-Path "${createdDriveLetter}:\\"' in create_or_reuse
    assert 'Drive = "${createdDriveLetter}:"' in create_or_reuse
    assert "-DriveLetter $InstallerLetter" not in create_or_reuse

    assert "$preparedDriveLetter = Get-LibertixFreeDriveLetter" in prepared_reuse
    assert "-NewDriveLetter $preparedDriveLetter" in prepared_reuse
    assert "-NewDriveLetter $InstallerLetter" not in prepared_reuse


def test_uefi_dismount_closes_only_explorer_windows_on_temporary_drive() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Storage.ps1")
    close_explorer = script.split("function Close-ExplorerWindowsForDrive", 1)[1].split(
        "function Dismount-Letter", 1
    )[0]
    dismount = script.split("function Dismount-Letter", 1)[1].split(
        "function Get-FreeDriveLetter", 1
    )[0]

    assert "$locationUrl -match" in close_explorer
    assert "^file:///" in close_explorer
    assert "$window.Quit()" in close_explorer
    assert "UIAutomationClient" in close_explorer
    assert '"CabinetWClass", "ExploreWClass"' in close_explorer
    assert "[Windows.Automation.ValuePattern]::Pattern" in close_explorer
    assert "$windowPattern.Close()" in close_explorer
    assert "LibertixExplorerWindowApi" in close_explorer
    assert "EnsureClosed($nativeHandle, 5000)" in close_explorer
    assert "return !IsWindow(hWnd);" in close_explorer
    assert "$driveReferencePattern" in close_explorer
    assert '$windowClass -eq "#32770"' in close_explorer
    assert "$IncludeErrorDialogs" in close_explorer
    assert "-IncludeErrorDialogs" in dismount
    assert "-RetryCount 25" in dismount
    assert "Close-ExplorerWindowsForDrive -Letter $Letter" in dismount


def test_uefi_large_linux_partition_uses_fat32_staging_and_full_reservation() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    create_or_reuse = script.split("function New-OrReuseInstallerPartition", 1)[1].split(
        "function Get-ReusablePreparedInstallerPartition", 1
    )[0]

    assert (
        "$requestedBytes = [int64]$installationPlan.disk.installer.finalSizeBytes"
        in create_or_reuse
    )
    assert (
        "$stagingBytes = [int64]$installationPlan.disk.installer.stagingSizeBytes"
        in create_or_reuse
    )
    assert "$stagingSizeGB = [int]($stagingBytes / 1GB)" in create_or_reuse
    assert "Wait-LibertixWindowsFreeSpaceBudget" in create_or_reuse
    assert "-AllocationBytes $shrinkBytes" in create_or_reuse
    assert "$fullGeometry = Get-LibertixAlignedShrinkGeometry" in create_or_reuse
    assert "$stagingGeometry = Get-LibertixAlignedShrinkGeometry" in create_or_reuse
    assert "$shrinkGeometry = if ($useOfflineResize)" in create_or_reuse
    assert "$shrinkBytes = [int64]$shrinkGeometry.ShrinkBytes" in create_or_reuse
    assert "-Size $stagingBytes" in create_or_reuse


def test_bios_large_linux_partition_uses_fat32_staging_and_full_reservation() -> None:
    apply_changes = read("Pages/ApplyChanges.Bios.cs")
    partitioning = apply_changes.split("private async Task ExecutePartitioningAsync", 1)[1].split(
        "private async Task FailBiosPreparationAndRollbackAsync", 1
    )[0]

    assert "InstallationSizePolicy.FromRequestedGigabytes" in apply_changes
    assert "installationSizes.StagingSizeMiB" in partitioning
    assert "ShrinkWindowsPartitionAsync(windowsShrinkMB)" in partitioning
    assert "useOfflineResize ? stagingMB : requestedLinuxMB" in partitioning
    assert "CreateFat32PartitionSimpleAsync(biosStagingMB)" in partitioning
    assert "the live will prepare the final" in partitioning
    workflow = apply_changes.split("private async Task ExecutePartitioningAsync", 1)[1].split(
        "private async Task<bool> PrepareBiosPartitionAsync", 1
    )[0]
    assert workflow.index("PrepareBiosDistributionIsoAsync(distribution)") < (
        workflow.index("PrepareBiosPartitionAsync(installationSizes)")
    )


def test_live_offline_ntfs_resize_is_fail_closed_and_runs_before_ext4() -> None:
    resize = read("assets/live/libertix-offline-ntfs-resize.sh")
    installer = read("assets/live/libertix-install-main.sh")
    builder = read("iso-tools/build-iso.sh")
    stages = read("assets/live/libertix-stages.tsv")

    assert '[ "$INSTALLER_RESIZE_MODE" = "live-offline" ] || return 0' in resize
    assert "assert_no_target_disk_mounts" in resize
    assert 'assert_not_mounted_or_open "$LIVE_PART"' in resize
    assert 'assert_not_mounted_or_open "$WINDOWS_PART"' in resize
    assert "assert_recovery_unchanged_or_die" in resize
    assert "FullyDecrypted|NotEncryptable" in resize
    assert "BitLocker to be absent or fully decrypted" in resize
    assert "ntfs-3g.probe --readwrite" in resize
    assert "ntfsresize --check" in resize
    assert "ntfsresize --info" in resize
    assert "ntfsresize --no-action --force --size" in resize
    assert resize.index("ntfsresize --no-action --force --size") < resize.index(
        "ntfsresize --force --size"
    )
    assert resize.index("ntfsresize --force --size") < resize.index(
        'resize_partition_size_sectors "$DISK" "$windows_number"'
    )
    assert "sfdisk --lock --no-reread -N" in resize
    assert "sfdisk --verify" in resize
    assert "offline Windows partition-table resize failed" in resize
    assert "offline Windows partition start changed unexpectedly" in resize
    assert "firmware_relocate_installer_partition_or_die" in resize
    assert "relocated installer partition offset verification failed" in resize
    assert installer.index("prepare_offline_ntfs_resize_or_die") < installer.index(
        'mark "080-mkfs-ext4"'
    )
    assert "libertix-offline-ntfs-resize.sh" in builder
    assert "045-offline-ntfs-preflight" in stages
    assert "046-offline-ntfs-resize" in stages
    assert "047-relocate-installer-partition" in stages


def test_offline_resize_rollback_resolves_staging_or_final_geometry() -> None:
    rollback = read("assets/live/libertix-rollback-common.sh")
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")

    for adapter in (bios, uefi):
        assert 'partition_at_offset "$DISK" "$INSTALLER_FINAL_OFFSET_BYTES"' in adapter
        assert 'partition_at_offset "$DISK" "$INSTALLER_PARTITION_OFFSET_BYTES"' in adapter
        assert '"$INSTALLER_FINAL_OFFSET_BYTES"' in adapter
        assert '"$INSTALLER_PARTITION_OFFSET_BYTES"' in adapter
    assert "restore_windows_partition_best_effort" in rollback
    assert "resize_partition_size_sectors" in rollback
    assert 'ntfsresize -f "$WINDOWS_PART"' in rollback
    assert "installationPlan.runtime.recoveryRunId" in transaction
    assert "installationPlan.planId -eq [string]$state.RecoveryRunId" not in transaction
    assert "finalOffsetBytes" in transaction
    assert "finalSizeBytes" in transaction


def test_bios_recovery_guard_accepts_staging_or_final_partition_size() -> None:
    apply_changes = read("Pages/ApplyChanges.Windows.cs")
    recovery = read("Scripts/libertix-recovery-guard.ps1")

    assert '$"STAGING_SIZE_MB={stagingSizeMB:F0}"' in apply_changes
    assert 'Read-EnvValue -Path $Pending -Name "STAGING_SIZE_MB"' in recovery
    assert "$matchesStagingSize" in recovery
    assert "$matchesFinalSize" in recovery
    assert "$isTemporaryFat -and -not $matchesStagingSize -and -not $matchesFinalSize" in recovery


def test_bios_recovery_guard_removes_only_the_empty_transaction_extended_container() -> None:
    recovery = read("Scripts/libertix-recovery-guard.ps1")
    helper = recovery.split("function Remove-EmptyTransactionExtendedContainer", 1)[1].split(
        "\ntry {", 1
    )[0]
    rollback = recovery.split("if (@($candidates).Count -eq 1)", 1)[1].split("Restore-BcdState", 1)[
        0
    ]

    assert '[string]$disk.PartitionStyle -ne "MBR"' in helper
    assert "$mbrType -in @(5, 15, 133)" in helper
    assert "$partitionStart -ge $SystemPartitionEnd" in helper
    assert "$partitionStart -le $TransactionOffset" in helper
    assert "$partitionEnd -ge $transactionEnd" in helper
    assert "$partitionEnd -le $RecoveryPartitionOffset" in helper
    assert "$trustedContainerBoundary" in helper
    assert "$insideTrustedContainerBoundary" in helper
    assert "$partitionStart -lt $OriginalSystemPartitionEnd" in helper
    assert "$containedPartitions.Count -ne 0" in helper
    assert "Remove-Partition -InputObject $container" in helper
    assert "The empty transaction MBR extended container still exists after removal" in helper
    recovery_offset_read = (
        'Read-EnvValue `\n        -Path $Pending `\n        -Name "RECOVERY_PARTITION_OFFSET_BYTES"'
    )
    assert recovery_offset_read in recovery

    remove_transaction_match = re.search(
        r"Remove-Partition\s+`?\s*"
        r"-DiskNumber \$diskNumber\s+`?\s*"
        r"-PartitionNumber \$number",
        rollback,
    )
    assert remove_transaction_match is not None
    remove_transaction = remove_transaction_match.start()
    remove_container = rollback.index("Remove-EmptyTransactionExtendedContainer")
    wait_for_capacity = rollback.index("Wait-SystemDriveResizeCapacity")
    resize_windows_match = re.search(
        r"Resize-Partition\s+`?\s*-DriveLetter \$SystemDriveLetter",
        rollback,
    )
    assert resize_windows_match is not None
    resize_windows = resize_windows_match.start()
    assert remove_transaction < remove_container < wait_for_capacity < resize_windows


def test_bios_recovery_guard_persists_and_aggregates_independent_compensations() -> None:
    recovery = read("Scripts/libertix-recovery-guard.ps1")

    assert 'status = "running"' in recovery
    assert "operations = $script:RecoveryOperationRecords.ToArray()" in recovery
    assert "errors = $script:RecoveryErrors.ToArray()" in recovery
    assert "attempts = @($script:RecoveryPriorAttempts) + @($currentAttempt)" in recovery
    assert "Publish-LibertixFileAtomic" in recovery
    assert "$atomicFileModule = Import-Module" in recovery
    assert "& $atomicFileModule {" in recovery
    assert "-Global" not in recovery
    assert 'operation = "state.persistence"' in recovery
    assert "Invoke-MinimumRecoveryFallback" in recovery
    assert "The recovery tasks and durable rollback payload remain armed." in recovery

    rollback = recovery.split(
        '$diskLayoutRestored = Invoke-RecoveryOperation -Name "disk-layout.restore"',
        1,
    )[1]
    independent_operations = [
        'Invoke-RecoveryOperation -Name "bcd.restore"',
        'Invoke-RecoveryOperation -Name "mbr.restore"',
        'Invoke-RecoveryOperation -Name "windows-share.cleanup"',
        'Invoke-RecoveryOperation -Name "hibernation.restore"',
        'Invoke-RecoveryOperation -Name "boot-payload.cleanup"',
        'Invoke-RecoveryOperation -Name "downloads.cleanup"',
    ]
    positions = [rollback.index(operation) for operation in independent_operations]
    first_aggregate_check = rollback.index("Assert-RecoveryOperationsSucceeded")
    assert positions == sorted(positions)
    assert all(position < first_aggregate_check for position in positions)

    ledger_complete = rollback.index('-Name "ledger.rollback.complete"')
    startup_task_remove = rollback.index('Invoke-RecoveryOperation -Name "startup-task.remove"')
    assert ledger_complete < startup_task_remove
    assert "Existing recovery operation history is unreadable" in recovery
    assert '$script:RecoveryAttemptStatus = "failed"' in recovery
    assert "function Test-RootScheduledTaskExists" in recovery
    assert "Get-ScheduledTask" in recovery
    assert "Unregister-ScheduledTask" in recovery
    assert "schtasks.exe /Delete" not in recovery
    save_state = recovery.split("function Save-RecoveryOperationState", 1)[1].split(
        "function Initialize-RecoveryOperationHistory", 1
    )[0]
    assert "$atomicFileModule = Import-Module" in save_state
    assert "-PassThru `" in save_state
    assert "& $atomicFileModule {" in save_state


def test_bios_recovery_retries_transient_storage_capacity_refresh_failures() -> None:
    recovery = read("Scripts/libertix-recovery-guard.ps1")
    helper = recovery.split("function Wait-SystemDriveResizeCapacity", 1)[1].split(
        "function Remove-EmptyTransactionExtendedContainer", 1
    )[0]

    assert "$capacityReadFailures = 0" in helper
    assert "Get-PartitionSupportedSize `" in helper
    assert "Windows storage capacity is still refreshing" in helper
    assert "Start-Sleep -Seconds 2" in helper
    assert "Windows storage capacity did not become readable" in helper


def test_bios_recovery_cleanup_verifies_files_share_tasks_bcd_and_hibernation() -> None:
    recovery = read("Scripts/libertix-recovery-guard.ps1")

    assert "Temporary boot payload remains:" in recovery
    assert "Pending Windows sharing payload still exists after removal." in recovery
    assert "Windows read-only Linux sharing cleanup could not be verified." in recovery
    assert 'bcdedit.exe /enum "{bootmgr}" /v' in recovery
    assert '"BCD restore completed but Windows Boot Manager could not be "' in recovery
    assert "\"verified (rc=$LASTEXITCODE output=$($verification -join ' ')).\"" in recovery
    assert 'powercfg.exe" /hibernate on' in recovery
    assert 'powercfg.exe" /hibernate off' in recovery
    assert "Hibernation restore did not enable HibernateEnabled." in recovery
    assert "Hibernation restore did not disable HibernateEnabled." in recovery


def test_uefi_raw_staging_partition_is_owned_before_fat32_format() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    create_or_reuse = script.split("function New-OrReuseInstallerPartition", 1)[1].split(
        "function Get-ReusablePreparedInstallerPartition", 1
    )[0]

    create_position = create_or_reuse.index("$newPartition = New-Partition")
    save_position = create_or_reuse.index(
        "Save-TransactionPartitionState -Partition $newPartition", create_position
    )
    geometry_position = create_or_reuse.index(
        "Windows created the installer partition with unexpected geometry", create_position
    )
    format_position = create_or_reuse.index("\n    Format-Volume `", create_position)

    assert create_position < save_position < geometry_position < format_position


def test_bios_staging_is_formatted_before_mount_manager_exposes_it() -> None:
    script = read("Scripts/libertix-bios-storage.ps1")
    create_staging = script.split('"CreateStaging" {', 1)[1]
    create_position = create_staging.index("$partition = New-Partition")
    format_position = create_staging.index("Format-Volume", create_position)
    assign_position = create_staging.index("Add-PartitionAccessPath", format_position)

    assert "-AssignDriveLetter" not in create_staging[create_position:format_position]
    assert "-Partition $partition" in create_staging[format_position:assign_position]
    assert "$createdDriveLetter = Get-LibertixFreeDriveLetter" in create_staging
    assert '-AccessPath "${createdDriveLetter}:\\"' in create_staging[assign_position:]


def test_windows_staging_size_is_exact_across_bios_and_uefi() -> None:
    bios_plan = read("Pages/ApplyChanges.Plan.cs")
    bios_storage = read("Scripts/libertix-bios-storage.ps1")
    uefi_execution = read("Scripts/uefi/Libertix.Uefi.Execution.ps1")
    size_policy = read("Installation/InstallationSizePolicy.cs")

    assert "if (size != installer.StagingSizeBytes)" in bios_plan
    assert "IsObservedStagingSizeAcceptable" not in size_policy
    assert "[int64]$verifiedPartition.Size -ne $SizeBytes" in bios_storage
    assert (
        "[int64]$Partition.Size -ne [int64]$installationPlan.disk.installer.stagingSizeBytes"
    ) in uefi_execution


def test_uefi_shrink_limit_is_measured_from_the_current_partition_size() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    create_or_reuse = script.split("function New-OrReuseInstallerPartition", 1)[1].split(
        "function Get-ReusablePreparedInstallerPartition", 1
    )[0]

    assert (
        "$maxShrink = [int64]$systemPartition.Size - [int64]$supported.SizeMin" in create_or_reuse
    )
    assert "$supported.SizeMax - $supported.SizeMin" not in create_or_reuse


def test_uefi_shrink_uses_shared_geometry_for_partition_creation() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    create_or_reuse = script.split("function New-OrReuseInstallerPartition", 1)[1].split(
        "function Get-ReusablePreparedInstallerPartition", 1
    )[0]

    assert "$fullGeometry = Get-LibertixAlignedShrinkGeometry" in create_or_reuse
    assert "$stagingGeometry = Get-LibertixAlignedShrinkGeometry" in create_or_reuse
    assert "$shrinkGeometry = if ($useOfflineResize)" in create_or_reuse
    assert "$shrinkBytes = [int64]$shrinkGeometry.ShrinkBytes" in create_or_reuse
    hibernation_position = create_or_reuse.index("Set-HibernateEnabled -Enabled $false")
    free_space_position = create_or_reuse.index("Wait-LibertixWindowsFreeSpaceBudget")
    assert hibernation_position < free_space_position
    assert "-Size ($systemPartition.Size - $shrinkBytes)" in create_or_reuse
    assert "Windows partition geometry does not match the aligned shrink target" in create_or_reuse
    assert "-Size $stagingBytes" in create_or_reuse
    assert "-Offset $installerOffsetBytes" in create_or_reuse
    assert "-Alignment ([int64]$shrinkGeometry.AlignmentBytes)" in create_or_reuse


def test_windows_hibernation_validation_distinguishes_preference_from_capability() -> None:
    staging = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")

    assert "$hibernationDisabled = $ShareWindowsFilesInLinux -or $forcedOfflineResize" in staging
    assert "Set-HibernateEnabled -Enabled $false" in staging
    assert '"HIBERNATION_ENABLED={0}"' in checks
    assert '"FAST_STARTUP_CONFIGURED={0}"' in checks
    assert '"FAST_STARTUP_CAPABLE={0}"' in checks
    assert "$fastStartupConfigured -and" in checks
    assert "$hibernateEnabled -and" in checks
    assert "$hiberfilePresent" in checks
    assert "Assert-Condition (-not $hibernateEnabled)" in checks
    assert "Assert-Condition (-not $fastStartupCapable)" in checks
    assert "Assert-Condition (-not $hiberfilePresent)" not in checks


def test_bios_storage_uses_the_same_alignment_geometry_as_uefi() -> None:
    script = read("Scripts/libertix-bios-storage.ps1")

    assert '"modules\\Libertix.StorageGeometry.psm1"' in script
    assert "Get-LibertixPartitionEndAlignmentPadding" in script
    assert "$maximumAllocationBytes" in script
    assert "[int64]$maximumAllocationBytes" in script
    assert "[Math]::Max" not in script
    assert "$allocationWithMbrMetadata = $SizeBytes + $partitionAlignmentBytes" in script
    assert "$shrinkGeometry = Get-LibertixAlignedShrinkGeometry" in script
    assert "Wait-LibertixWindowsFreeSpaceBudget" in script
    assert "-AllocationBytes ([int64]$shrinkGeometry.ShrinkBytes)" in script
    assert "-Offset $containerOffsetBytes" in script
    assert "-Alignment $partitionAlignmentBytes" in script


def test_uefi_preparation_failure_distinguishes_verified_and_incomplete_rollback() -> None:
    source = read("Pages/ApplyChanges.Uefi.cs")
    exit_failure = source.split(
        "if (processResult.Completion != StreamingProcessCompletion.Exited", 1
    )[1].split('recovery.Phase = "AwaitingReboot"', 1)[0]
    recovery_arming = source.split("ArmUefiRecoveryAgent(recovery, powershell);", 1)[1].split(
        "StreamingProcessResult processResult", 1
    )[0]
    failure_handler = source.split("private async Task HandleUefiPreparationFailureAsync", 1)[
        1
    ].split("private UefiRecoveryState CreateUefiRecoverySession", 1)[0]

    assert "HandleUefiPreparationFailureAsync" in exit_failure
    assert '"UEFI_RECOVERY_AGENT_FAILED"' in recovery_arming
    assert "before disk mutation" in recovery_arming
    assert "InstallationStatus.RolledBack" in failure_handler
    assert "-Revert" in failure_handler
    assert "-ExpectedRecoveryRunId" in failure_handler
    assert "observeCancellation: false" in failure_handler
    assert '"ApplyChangesPreparationErrorRestored"' in failure_handler
    assert '"ApplyChangesRollbackIncomplete"' in failure_handler
    assert '"ApplyChangesPreparationRollbackIncompleteDetails"' in failure_handler
    assert "FinishInstallation(enableBackButton: false)" in failure_handler


def test_live_bitlocker_diagnostic_is_shared_by_bios_and_uefi() -> None:
    common = read("assets/live/libertix-storage-common.sh")
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")
    installer = read("assets/live/libertix-install-main.sh")

    assert "find_biggest_bitlocker_partition()" in common
    assert "find_biggest_bitlocker_partition()" not in bios
    assert "find_biggest_bitlocker_partition()" not in uefi
    assert 'find_biggest_bitlocker_partition "$DISK"' in installer


def test_live_bitlocker_diagnostic_names_its_windows_partition_threshold() -> None:
    common = read("assets/live/libertix-storage-common.sh")

    assert "readonly MINIMUM_LIKELY_WINDOWS_PARTITION_MIB=1000" in common
    assert '"$size_mib" -gt "$MINIMUM_LIKELY_WINDOWS_PARTITION_MIB"' in common
    assert '"$size_mib" -gt 1000' not in common


def test_final_verification_waits_for_a_clean_target_release_in_both_modes() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    target = read("assets/live/libertix-target-common.sh")
    runtime = read("assets/live/libertix-install-runtime-common.sh")
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    assert 'unmount_target_system || die "target filesystem could not be released' in installer
    assert "for ((attempt = 1; attempt <= 10; attempt++)); do" in target
    assert "findmnt -rn -R /mnt/target" in target
    assert 'findmnt -rn -S "$NEW_PART"' in target
    assert "mount_linux_root_read_only_or_die()" in runtime
    for adapter in (bios, uefi):
        assert 'mount_linux_root_read_only_or_die "$NEW_PART" "$target_verify"' in adapter
        assert 'mount -o ro "$NEW_PART" "$target_verify"' not in adapter


def test_live_boot_partition_identity_never_scans_other_disks() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    target = read("assets/live/configure-target-main.sh")
    target_runtime = read("assets/live/libertix-target-common.sh")
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    assert 'WINDOWS_BOOT_PART=$(partition_at_offset "$DISK"' in installer
    assert 'WINDOWS_BOOT_PART="$WINDOWS_BOOT_PART"' in target_runtime
    assert 'blkid -s UUID -o value "$WINDOWS_BOOT_PART"' in target
    assert 'bcd_part="$WINDOWS_BOOT_PART"' in bios
    assert 'windows_part="$WINDOWS_PART"' in bios
    esp = uefi.split("find_esp_partition()", 1)[1].split(
        "cleanup_final_uefi_bootloader_best_effort()", 1
    )[0]
    assert 'partition_at_offset "$DISK" "$WINDOWS_BOOT_PARTITION_OFFSET_BYTES"' in esp
    assert "candidate_disks" not in esp
    uefi_cleanup = uefi.split("cleanup_windows_live_boot_artifacts()", 1)[1]
    assert "bcd_part=$(find_esp_partition || true)" in uefi_cleanup


def test_live_disk_discovery_has_the_same_fallback_for_both_firmwares() -> None:
    common = read("assets/live/libertix-storage-common.sh")
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    discovery = common.split("candidate_disks()", 1)[1].split("disk_partition_table_identity()", 1)[
        0
    ]
    for adapter in (bios, uefi):
        wait = adapter.split("wait_for_prereqs()", 1)[1].split(
            "set_linux_partition_type_or_die()", 1
        )[0]
        assert "done < <(candidate_disks)" in wait
        assert "candidate_disks()" not in adapter
        assert "disk_matches_manifest()" not in adapter
    assert "lsblk -dnpo NAME,TYPE" in discovery
    assert "for disk in /sys/block/*" in discovery


def test_live_rollback_ownership_uses_manifest_offset_for_both_firmwares() -> None:
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    for adapter in (bios, uefi):
        ownership = adapter.split("firmware_rollback_partition_is_owned()", 1)[1]
        ownership = ownership.split("firmware_cleanup_partition_container_best_effort()", 1)[0]
        assert 'parent_disk_from_part "$partition"' in ownership
        assert 'partition_start_bytes "$DISK" "$partition"' in ownership
        assert '"$INSTALLER_PARTITION_OFFSET_BYTES"' in ownership


def test_temporary_windows_boot_cleanup_fails_closed_for_both_firmwares() -> None:
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    bios_cleanup = bios.split("cleanup_windows_live_boot_artifacts()", 1)[1]
    uefi_cleanup = uefi.split("cleanup_windows_live_boot_artifacts()", 1)[1]
    assert 'die "Windows BCD store disappeared after mount"' in bios_cleanup
    assert 'die "Windows UEFI BCD store disappeared after mount"' in uefi_cleanup
    assert "delete_live_bcd_entry_or_die" in bios_cleanup
    assert "delete_live_bcd_entry_or_die" in uefi_cleanup
    assert "UEFI BCD cleanup failed; continuing" not in uefi_cleanup
    assert "temporary UEFI installer entry remains after cleanup" in uefi


def test_live_invokes_the_bcd_cleanup_implementation_without_a_wrapper() -> None:
    runtime = read("assets/live/libertix-install-runtime-common.sh")
    builder = read("iso-tools/build-iso.sh")
    verifier = read("docker/iso-builder/verify-built-iso.sh")

    assert 'python3 /usr/local/lib/libertix/cleanup-bcd-main.py "$bcd_file"' in runtime
    assert "assets/live/cleanup-bcd-main.py" in builder
    assert "cleanup-bcd-main.py" in verifier
    assert "cleanup-bcd.py" not in runtime
    assert "cleanup-bcd.py" not in builder
    assert "cleanup-bcd.py" not in verifier
    assert not (ROOT / "assets/live/cleanup-bcd.py").exists()


def test_recovery_geometry_uses_manifest_offset_for_both_firmwares() -> None:
    common = read("assets/live/libertix-storage-common.sh")
    runtime = read("assets/live/libertix-install-runtime-common.sh")
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    assert "manifest_partition_geometry()" in common
    assert 'manifest_partition_geometry "$disk" "$RECOVERY_PARTITION_OFFSET_BYTES"' in runtime
    assert "recovery_geometry()" not in bios
    assert "recovery_geometry()" not in uefi
    assert "'$1==\"4\"'" not in bios
    assert "'$1==\"4\"'" not in uefi


def test_uefi_low_memory_boot_files_are_writable_and_revert_uses_transaction_state() -> None:
    staging = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")
    install = staging.split("function Install-LibertixIsoToPartition", 1)[1].split(
        "function Set-LibertixUefiBootEntry", 1
    )[0]
    revert = transaction.split("function Invoke-Revert", 1)[1]

    attributes_position = install.index("attrib -R -S -H $bootConfig.FullName")
    write_position = install.index(
        "Set-Content -LiteralPath $bootConfig.FullName", attributes_position
    )

    assert attributes_position < write_position
    assert "LowMemoryMode = [bool]$LowMemoryMode" in transaction
    assert "$transactionUsedLowMemory" in revert
    assert "$LowMemoryMode -and (Test-Path -LiteralPath $LowMemoryIsoPath" not in revert
    assert "Remove-Item -LiteralPath $LowMemoryIsoPath -Force" in revert


def test_uefi_live_expands_fat32_staging_before_ext4_format() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    reuse = installer.split(
        'echo "=== Reusing live partition $LIVE_PART as final Linux partition ==="', 1
    )[1].split("prepare_installer_partition_for_target_format_or_die", 1)[0]

    assert "requested_partition_bytes=$((LINUX_SIZE_GB * 1024 * 1024 * 1024))" in reuse
    assert 'desired_partition_bytes="$requested_partition_bytes"' in reuse
    assert "recovery_start_sector=$(bytes_to_logical_sectors" in reuse
    assert '"$RECOVERY_PARTITION_OFFSET_BYTES" "$logical_sector_bytes"' in reuse
    assert 'run_logged parted -s "$DISK" unit s resizepart' in reuse
    assert 'expanded_partition_bytes=$(blockdev --getsize64 "$NEW_PART"' in reuse
    assert '"$expanded_partition_bytes" -eq "$desired_partition_bytes"' in reuse
    assert reuse.index("resizepart") < installer.index('run_logged wipefs -a "$NEW_PART"')


def test_bios_live_expands_fat32_staging_before_ext4_format() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    reuse = installer.split(
        'echo "=== Reusing live partition $LIVE_PART as final Linux partition ==="', 1
    )[1].split("prepare_installer_partition_for_target_format_or_die", 1)[0]

    assert "requested_partition_bytes=$((LINUX_SIZE_GB * 1024 * 1024 * 1024))" in reuse
    assert 'desired_partition_bytes="$requested_partition_bytes"' in reuse
    assert "recovery_start_sector=$(bytes_to_logical_sectors" in reuse
    assert '"$RECOVERY_PARTITION_OFFSET_BYTES" "$logical_sector_bytes"' in reuse
    assert 'run_logged parted -s "$DISK" unit s resizepart' in reuse
    assert 'expanded_partition_bytes=$(blockdev --getsize64 "$NEW_PART"' in reuse
    assert '"$expanded_partition_bytes" -eq "$desired_partition_bytes"' in reuse
    assert reuse.index("resizepart") < installer.index('run_logged wipefs -a "$NEW_PART"')


def test_uefi_iso_download_uses_the_canonical_url_without_cache_busting() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    download = script.split("function Install-LibertixIsoToPartition", 1)[1].split(
        "function Set-LibertixUefiBootEntry", 1
    )[0]

    assert "$downloadUrl = $InstallerIsoUrl" in download
    assert "cacheBust" not in download
    assert "Start-RobustDownload `" in download
    assert "-Url $downloadUrl `" in download
    assert "-MaxBytes $script:MaximumLiveIsoBytes" in download


def test_mint_installer_uses_the_official_mirror_in_every_download_contract() -> None:
    official_url = "https://pub.linuxmint.io/stable/22.3/linuxmint-22.3-cinnamon-64bit.iso"
    distributions = json.loads(read("release-config.json"))["distributions"]
    download_module = read("Scripts/modules/Libertix.Download.psm1")

    assert distributions[0]["isoInstaller"] == official_url
    assert distributions[0]["isoInstallerSha256"] == (
        "a081ab202cfda17f6924128dbd2de8b63518ac0531bcfe3f1a1b88097c459bd4"
    )
    assert "MintIso =" not in download_module
    assert "$baseUrl/mint.iso" not in download_module


def test_bios_windows_progress_does_not_regress_after_distribution_download() -> None:
    bios = read("Pages/ApplyChanges.Bios.cs")
    downloads = read("Pages/ApplyChanges.Downloads.cs")
    progress_catalogue = read("Pages/ApplyChanges.Types.cs")

    assert "DistributionDownload = 2" in progress_catalogue
    assert "DistributionReady = 8" in progress_catalogue
    assert "ShrinkWindows = 10" in progress_catalogue
    assert "LiveDownloadTransferStart = 60" in progress_catalogue
    assert "LiveDownloadTransferSpan = 20" in progress_catalogue
    assert "InstallationContextReady = 95" in progress_catalogue
    assert "BootloaderDownload = 96" in progress_catalogue
    assert "BootEntryReady = 98" in progress_catalogue
    assert "BiosProgress.DistributionDownload" in bios
    assert "BiosProgress.DistributionReady" in bios
    installer_download = downloads.split("private async Task<bool> DownloadInstallerIsoAsync", 1)[
        1
    ].split("private async Task<bool> DownloadFileWithRetriesAsync", 1)[0]
    assert "progressStart: BiosProgress.DistributionDownload" in installer_download
    assert (
        "progressSpan: BiosProgress.DistributionReady - BiosProgress.DistributionDownload"
        in installer_download
    )


def test_bios_preparation_log_steps_follow_execution_order() -> None:
    bios = read("Pages/ApplyChanges.Bios.cs")
    messages = [
        "Step 1: Downloading Linux installer",
        "Step 2: Shrinking Windows",
        "Step 3: Creating",
        "Step 4: No second shrink needed",
        "Step 5: Downloading ISO",
        "Step 6: Mounting ISO",
        "Step 7: Downloading GRUB4DOS",
        "Step 8: Configuring GRUB4DOS",
    ]
    for message in messages:
        assert message in bios
    assert "Step 9:" not in bios


def test_windows_pages_share_the_wow64_safe_powershell_resolver() -> None:
    page_sources = [
        read("Pages/ApplyChanges.Bios.cs"),
        read("Pages/ApplyChanges.Cancellation.cs"),
        read("Pages/ApplyChanges.Plan.cs"),
        read("Pages/ApplyChanges.System.cs"),
        read("Pages/ApplyChanges.Uefi.cs"),
        read("Pages/ApplyChanges.Windows.cs"),
        read("Pages/ChooseDistro.xaml.cs"),
        read("Pages/UefiBootFallback.xaml.cs"),
    ]

    assert (
        sum(source.count("WindowsProcessRunner.ResolvePowerShell()") for source in page_sources)
        >= 12
    )
    assert all(
        'SpecialFolder.System), "WindowsPowerShell"' not in source for source in page_sources
    )


def test_live_handoff_is_published_atomically_and_hidden_before_reboot() -> None:
    bios = read("Pages/ApplyChanges.Bios.cs")
    uefi = read("Scripts/uefi/Libertix.Uefi.Execution.ps1")
    orchestrator = read("Scripts/libertix-uefi-install.ps1")

    assert "RemoveBiosInstallerAccessPathAsync" in bios
    assert "Remove-PartitionAccessPath -InputObject $p" in bios
    assert "Installer partition drive letter remains assigned" in bios
    assert "Publish-LibertixFileAtomic" in uefi
    assert "$outputStream.Flush($true)" in uefi
    assert "Installation context publication hash mismatch" in uefi
    assert 'Dismount-Letter -Letter ($drive.TrimEnd(":"))' in orchestrator


def test_uefi_recovery_uses_shared_atomic_publish_without_null_backup_paths() -> None:
    recovery = read("Scripts/libertix-uefi-recovery-agent.ps1")
    transaction = read("Scripts/uefi/Libertix.Uefi.Transaction.ps1")

    assert '"Scripts\\modules\\Libertix.AtomicFile.psm1"' in recovery
    assert "Publish-RecoveryFileAtomic" in recovery
    assert "& $atomicFileModule {" in recovery
    assert "Publish-LibertixFileAtomic" in recovery
    assert "Write-AgentErrorRecord -ErrorRecord $fatalError" in recovery
    assert "ERROR PowerShellStack:" in recovery
    assert "[IO.File]::Replace($temporary, $path, $null)" not in recovery
    assert "[IO.File]::Replace($temporary, $destination, $null)" not in recovery
    assert "[IO.File]::Replace($temporary, $destination, $null)" not in transaction
    assert "Publish-LibertixFileAtomic" in transaction


def test_temporary_media_and_grub_generator_workspaces_are_cleaned() -> None:
    staging = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    grub_generator = read("grub/10_libertix")

    assert "$env:TEMP" not in staging
    assert '"ProgramData\\Libertix\\Downloads\\$RecoveryRunId\\live-media"' in staging
    assert "Remove-Item -Path $tmpDir -Recurse -Force" in staging
    assert "trap 'rm -rf \"$workdir\"' EXIT HUP INT TERM" in grub_generator
    assert "exec python3" not in grub_generator


def test_distribution_minimum_uses_the_shared_installation_size_policy() -> None:
    catalog_loader = read("Installation/DistributionCatalogLoader.cs")

    assert "distribution.SizeInGB < InstallationSizePolicy.MinimumFinalSizeGiB" in catalog_loader
    assert "distribution.SizeInGB < 20" not in catalog_loader


def test_bios_iso_output_name_matches_the_filepool_contract() -> None:
    defaults = read("iso/config/defaults.env")
    docker_builder = read("docker/iso-builder/build-isos.sh")
    workflow = read(".github/workflows/ci.yml")
    catalog = read("auto_tests/app/filepool/catalog.json")

    expected_name = "libertix-installer-bios.iso"
    assert f'OUTPUT_ISO="{expected_name}"' in defaults
    assert f"/workspace/{expected_name}" in docker_builder
    assert expected_name in workflow
    assert f'"fileName": "{expected_name}"' in catalog
    assert f'"url": "{expected_name}"' in catalog
    assert "libertix-installer.iso" not in defaults
    assert "/workspace/libertix-installer.iso" not in docker_builder


def test_iso_build_defaults_do_not_embed_account_or_locale_fallbacks() -> None:
    for relative_path in ("iso/config/defaults.env", "iso-uefi/config/defaults.env"):
        defaults = read(relative_path)
        assert "USERNAME=" not in defaults
        assert "PASSWORD_HASH=" not in defaults
        assert "LANGUAGE_CODE=" not in defaults
        assert "KEYBOARD_LAYOUT=" not in defaults


def test_published_artifacts_are_traceable_and_include_notices() -> None:
    workflow = read(".github/workflows/ci.yml")
    assembly = read("Properties/AssemblyInfo.cs")
    standalone_assembly = read("Standalone/AssemblyInfo.cs")
    payload = read("Standalone/Create-Payload.ps1")

    assert 'AssemblyInformationalVersion("dev_0000000")' in assembly
    assert 'AssemblyInformationalVersion("dev_0000000")' in standalone_assembly
    assert "Stamp source revision in the executable" in workflow
    assert '@("LICENSE", "THIRD_PARTY.md")' in payload
    assert "iso-tools/prepare-support-artifacts.py" in workflow
    for support_file in (
        "aria2-64.zip",
        "ext4-win-driver.exe",
        "grldr",
        "grldr.mbr",
    ):
        assert f"release-assets/{support_file}" in workflow
        assert f"release-metadata/{support_file}" in workflow
    assert "release-assets/SHA256SUMS" not in workflow


def test_standalone_release_contains_and_verifies_the_complete_runtime() -> None:
    solution = read("Libertix.sln")
    project = read("Standalone/Libertix.Standalone.csproj")
    launcher = read("Standalone/Program.cs")
    payload = read("Standalone/Create-Payload.ps1")
    build = read("auto_tests/app/scripts/build_libertix.ps1")
    workflow = read(".github/workflows/ci.yml")

    assert '"Libertix.Standalone", "Standalone\\Libertix.Standalone.csproj"' in solution
    assert "GenerateStandalonePayload" in project
    assert "Libertix.Standalone.Payload.zip" in project
    assert "Libertix.Standalone.PayloadManifest.json" in project
    assert 'requestedExecutionLevel level="requireAdministrator"' in read("Standalone/app.manifest")
    assert "ProtectDirectory(parent)" in launcher
    assert 'Path.Combine(parent, ".extraction.lock")' in launcher
    assert "FileShare.None" in launcher
    assert "EnsureRuntimeLocked" in launcher
    assert "ExtractVerifiedPayload" in launcher
    assert "ValidateRuntime(destination, manifest)" in launcher
    assert "Sha256File" in launcher
    assert "NormalizeRelativePath(entry.FullName)" in launcher
    assert "CopyAndHash(source, temporary" in launcher
    assert 'seen.Contains("Libertix.exe")' in launcher
    assert 'seen.Contains("Libertix.BootGuardian.exe")' in launcher
    assert '"Libertix.BootGuardian.exe"' in payload
    assert "Get-PayloadFileSha256" in payload
    assert "[Security.Cryptography.SHA256]::Create()" in payload
    assert "ZipArchive" in payload
    assert "stagedEntries.Count -ne 1" in build
    assert "publishedEntries.Count -ne 1" in build
    assert "path: Standalone/bin/Release/Libertix.exe" in workflow
    assert 'unzip -Z1 "release-assets/$wpf_archive"' in workflow
    assert "release-metadata/SHA256SUMS" not in workflow


def test_release_metadata_is_generated_signed_and_isolated_by_channel() -> None:
    workflow = read(".github/workflows/ci.yml")
    generator = read("iso-tools/generate-release-metadata.py")
    signer = read("iso-tools/sign-release-metadata.py")
    config = json.loads(read("release-config.json"))

    assert set(config) == {"schemaVersion", "mainRelease", "distributions"}
    assert '--channel "$RELEASE_CHANNEL"' in workflow
    assert "LIBERTIX_SIGNING_PRIVATE_KEY" in workflow
    assert "release-metadata/catalog.json" in workflow
    assert "release-metadata/releases.json" in workflow
    assert "group: libertix-pages-publication" in workflow
    assert 'install -d -m 0755 "pages-branch/$RELEASE_CHANNEL"' in workflow
    assert 'gh api --method POST "repos/$GH_REPO/pages/builds"' in workflow
    assert "https://ekimiateam.github.io/libertix/$RELEASE_CHANNEL/$filename" in workflow
    assert 'cmp -- "generated-metadata/$filename"' in workflow
    assert "legacy_channel_files=(" in workflow
    assert "distros.json.sig" in workflow
    assert 'git -C pages-branch rm --ignore-unmatch -- "$RELEASE_CHANNEL/$filename"' in workflow
    assert 'test "$status_code" = 404' in workflow
    assert 'if channel == "dev":' in generator
    assert 'build_version = f"dev_{tag}"' in generator
    assert "private_key.public_key().public_numbers()" in signer


def test_offline_documentation_preserves_the_catalogue_requirement() -> None:
    readme = read("README.md")
    architecture = read("docs/ARCHITECTURE.md")

    assert "Reusing local ISO files does not remove the catalogue requirement" in readme
    assert "`catalog.json` and its detached signature" in readme
    assert "Local ISO files reduce artifact" in architecture
    assert "do not provide a standalone" in architecture
    assert "An isolated laboratory must expose a" in architecture
    assert "local HTTP filepool" in architecture


def test_recovery_documentation_does_not_promise_reversible_decryption() -> None:
    architecture = read("docs/ARCHITECTURE.md")

    assert "BitLocker is verified separately against its captured state" in architecture
    assert "cannot be reversed safely by the installer" in architecture
    assert "prevents Libertix from reporting a fully verified rollback" in architecture


def test_wpf_and_automation_require_the_same_minimum_password_length() -> None:
    account_page = (ROOT / "Pages" / "AccountCreation.xaml.cs").read_text(encoding="utf-8-sig")
    account_policy = (ROOT / "Installation" / "AccountPolicy.cs").read_text(encoding="utf-8-sig")
    api_models = (ROOT / "auto_tests" / "app" / "models.py").read_text(encoding="utf-8")

    assert "PasswordBox.Password.Length < AccountPolicy.MinimumPasswordLength" in account_page
    assert "public const int MinimumPasswordLength = 4;" in account_policy
    assert "linux_password: str = Field(min_length=4" in api_models


def test_account_page_distinguishes_reserved_usernames_from_invalid_syntax() -> None:
    account_page = read("Pages/AccountCreation.xaml.cs")
    account_policy = read("Installation/AccountPolicy.cs")

    assert "AccountPolicy.CreateDefaultUsername(Environment.UserName)" in account_page
    assert "AccountPolicy.IsValidUsernameSyntax" in account_page
    assert "AccountPolicy.IsReservedUsername" in account_page
    assert 'Localization.GetString("UsernameReserved")' in account_page
    assert 'private const string DefaultUsernameSuffix = "-linux";' in account_policy


def test_uefi_bits_fallback_times_out_and_cleans_an_incomplete_job() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Downloads.ps1")
    bits = script.split("function Start-BitsDownload", 1)[1].split("function Get-Aria2Exe", 1)[0]
    robust = script.split("function Start-RobustDownload", 1)[1].split(
        "function Set-DistributionIsoOnWindows", 1
    )[0]

    assert "NoProgressTimeoutSeconds = 120" in bits
    assert '"Connecting", "Transferring", "TransientError"' in bits
    assert "$idleSeconds -ge $NoProgressTimeoutSeconds" in bits
    assert "BITS transfer made no progress" in bits
    assert "if (-not $completed)" in bits
    assert "Remove-BitsTransfer -BitsJob $remainingJob" in bits
    assert "BITS completed but the downloaded file is missing" in bits
    assert "Invoke-BoundedHttpDownload" in robust
    assert "-TimeoutSeconds 120" in robust
    assert "$maximumAria2Attempts = [int]$script:DownloadPolicy.maximumAttempts" in robust
    assert "$retryBaseDelaySeconds = [int]$script:DownloadPolicy.retryBaseDelaySeconds" in robust
    assert "Start-Sleep -Seconds ($retryBaseDelaySeconds * $attempt)" in robust
    assert "retaining the partial download and retrying" in robust


def test_windows_downloads_resume_and_present_clean_utf8_diagnostics() -> None:
    downloads = read("Pages/ApplyChanges.Downloads.cs")
    runner = read("Helpers/WindowsProcessRunner.cs")
    apply_page = read("Pages/ApplyChanges.xaml.cs")
    uefi = read("Scripts/libertix-uefi-install.ps1")

    assert '$"--continue={continueDownload}"' in downloads
    assert '"--max-tries=5"' in downloads
    assert '"--retry-wait=10"' in downloads
    assert '"--enable-color=false"' in downloads
    assert "partial download retained for the next resume attempt" in downloads
    assert "NormalizeTerminalText" in runner
    assert "WindowsProcessRunner.NormalizeTerminalText(message)" in apply_page
    assert "[Console]::OutputEncoding = $utf8NoBom" in uefi
    assert "$OutputEncoding = $utf8NoBom" in uefi


def test_terminal_fallback_does_not_reset_video_mode_on_redraw() -> None:
    rootfs = read("assets/live/setup-live-rootfs.sh")
    runner = read("assets/live/libertix-runner-main.sh")

    assert "write_tty1_screen" in runner
    assert "cmp -s" in runner
    assert "perl -pe 's/\\n/\\033[K\\r\\n/g'" in runner
    assert "printf '\\033c'" not in runner
    assert "dmesg -n 1" in runner
    assert "prepare_terminal_ui" in runner
    assert "getty@tty1.service" in rootfs
    assert "ln -sf /dev/null" in rootfs


def test_live_rootfs_masks_unused_serial_login_prompt() -> None:
    rootfs = read("assets/live/setup-live-rootfs.sh")

    assert "ln -sf /dev/null /etc/systemd/system/serial-getty@ttyS0.service" in rootfs


def test_live_installer_shutdown_contract_is_identical_and_rollback_safe() -> None:
    bios_unit = read("iso/systemd/libertix-install.service")
    uefi_unit = read("iso-uefi/systemd/libertix-install.service")
    runner = read("assets/live/libertix-runner-main.sh")
    installer = read("assets/live/libertix-install-main.sh")
    rollback = read("assets/live/libertix-rollback-common.sh")

    assert bios_unit == uefi_unit
    assert "Conflicts=getty@tty1.service" in bios_unit
    assert "Before=getty@tty1.service" in bios_unit
    assert "TimeoutStopSec=30min" in bios_unit
    assert "KillMode=mixed" in bios_unit
    assert "function request_graceful_stop" not in runner
    assert "request_graceful_stop()" in runner
    assert 'kill -TERM "$INSTALLER_PID"' in runner
    assert 'wait "$INSTALLER_PID"' in runner
    assert runner.index('kill -TERM "$INSTALLER_PID"') < runner.index(
        "copy_logs_to_windows_best_effort", runner.index("request_graceful_stop()")
    )
    assert "trap 'on_termination_signal TERM 143' TERM" in installer
    assert "trap 'on_termination_signal INT 130' INT" in installer
    signal_handler = installer.split("on_termination_signal()", 1)[1].split("on_exit()", 1)[0]
    assert "fail_and_exit" in signal_handler
    assert 'sync || true\n    exit "$rc"' in rollback


def test_live_rootfs_does_not_ship_an_unused_passworded_sudo_account() -> None:
    rootfs = read("assets/live/setup-live-rootfs.sh")

    assert "useradd" not in rootfs
    assert "user:live" not in rootfs
    assert "NOPASSWD" not in rootfs
    packages = rootfs.split("packages=(", 1)[1].split(")", 1)[0]
    assert "sudo" not in packages.split()


def test_ntfs_scan_uses_the_documented_numeric_result_not_localized_text() -> None:
    preflight = read("Scripts/libertix-compatibility-preflight.ps1")
    scan = preflight.split('Write-Check "COMPAT_050_FILESYSTEM"', 1)[1].split(
        "Get-PartitionSupportedSize", 1
    )[0]

    assert "[uint32]$scanResult" in scan
    assert "$scanResult -ne 0" in scan
    assert "NoErrorsFound" not in scan
    assert "No Error" not in scan
    assert "Aucune" not in scan


def test_obsolete_clickonce_metadata_and_unused_test_dependency_are_absent() -> None:
    project = read("Libertix.csproj")
    pyproject = read("auto_tests/pyproject.toml")
    lock = read("auto_tests/uv.lock")
    requirements = read("auto_tests/requirements-dev.txt")

    for clickonce_name in ("PublishUrl", "UpdateEnabled", "BootstrapperPackage"):
        assert clickonce_name not in project
    assert 'name = "httpx2"' not in lock
    assert '"httpx2' not in pyproject
    assert "httpx2" not in requirements


def test_uefi_recovery_runtime_modules_are_packaged_with_the_wpf_application() -> None:
    project = read("Libertix.csproj")
    apply_changes = read("Pages/ApplyChanges.Uefi.cs")

    for relative_path in (
        r"Scripts\modules\Libertix.FirmwareRead.psm1",
        r"Scripts\modules\Libertix.PreferredBootPath.psm1",
        r"Scripts\modules\Libertix.BootGuardian.psm1",
    ):
        entry = project.split(f'<Content Include="{relative_path}">', 1)[1].split("</Content>", 1)[
            0
        ]
        assert "<CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>" in entry
        assert relative_path.rsplit("\\", 1)[-1] in apply_changes
    assert "Libertix.BootGuardian.exe" in apply_changes
    assert "Libertix.BootGuardian.csproj" in project


def test_uefi_boot_guardian_is_armed_before_waiting_for_first_linux_boot() -> None:
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")
    waiting_branch = agent.split(
        "if (-not (Test-Path -LiteralPath $linuxBootEvidence -PathType Leaf)) {", 1
    )[1].split('Write-AgentLog "Live success found;', 1)[0]
    preferred_action = agent.split('if ($Action -eq "InstallPreferredPath") {', 1)[1].split(
        "$successRunId = Read-EnvValue", 1
    )[0]

    assert waiting_branch.index("Install-BootGuardianForCurrentBootPath") < waiting_branch.index(
        "Set-LibertixPostInstallWaitingForLinux"
    )
    assert "firmwareBypassEvaluationSucceeded" in waiting_branch
    assert preferred_action.index("Install-LibertixPreferredBootPath") < preferred_action.index(
        "Install-BootGuardianForCurrentBootPath"
    )
    guardian_index = preferred_action.index("Install-BootGuardianForCurrentBootPath")
    assert guardian_index < preferred_action.index('"AwaitingPreferredPathReboot"')


def test_boot_guardian_uses_the_windows_preshutdown_contract_and_quiet_logs() -> None:
    native = read("BootGuardian/NativeMethods.cs")
    service = read("BootGuardian/ServiceHost.cs")
    engine = read("BootGuardian/BootGuardianEngine.cs")
    journal = read("BootGuardian/RepairJournal.cs")

    assert "ServiceControlPreshutdown = 0x0000000F" in native
    assert "ServiceConfigPreshutdownInfo = 7" in native
    assert (
        '[DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]\n'
        "        [return: MarshalAs(UnmanagedType.Bool)]\n"
        "        internal static extern bool ChangeServiceConfig2" in native
    )
    assert "PreshutdownTimeout = 10000" in service
    assert "TimeSpan.FromMilliseconds(8500)" in service
    assert "last-attempt.state" in read("BootGuardian/GuardianAttemptState.cs")
    assert "Stopwatch.StartNew()" in read("BootGuardian/RepairDeadline.cs")
    assert "RepairJournal.WriteUncorrelatedError(error)" in engine
    assert "if (!journaled)" in engine
    assert "SeSystemEnvironmentPrivilege" in service
    assert "ServiceAcceptPreshutdown" in service
    firmware = read("BootGuardian/FirmwareEnvironment.cs")
    assert "NativeMethods.SetLastError(0);" in firmware
    assert firmware.index("NativeMethods.SetLastError(0);") < firmware.index(
        "NativeMethods.AdjustTokenPrivileges("
    )
    assert 'Flush("repair")' in journal
    healthy_completion = journal.split("internal void Complete()", 1)[1].split(
        "internal void Fail", 1
    )[0]
    assert "if (_repairRequired || _interruptedAttemptRecovered)" in healthy_completion
    assert "ArchiveUnexpected(" in engine
    assert "config," in engine
    assert "AtomicFile.CopyVerified" in engine


def test_boot_guardian_is_removed_before_any_uefi_boot_restoration() -> None:
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")
    cancel = agent.split('if ($Action -eq "Cancel") {', 1)[1].split(
        'if ($Action -eq "InstallPreferredPath") {', 1
    )[0]

    assert cancel.index("Remove-BootGuardianIfPresent") < cancel.index(
        "Restore-PreferredBootPathIfPresent"
    )
    assert cancel.index("Remove-BootGuardianIfPresent") < cancel.index(
        "Restore-UefiTransactionArchive"
    )


def test_uefi_recovery_mounts_a_letterless_esp_at_an_explicit_free_access_path() -> None:
    agent = read("Scripts/libertix-uefi-recovery-agent.ps1")
    mount = agent.split("function Invoke-WithVerifiedEsp", 1)[1].split(
        "function Test-EfiLoadOptionTargetsPartition", 1
    )[0]

    assert ').Trim().TrimEnd(":")' in mount
    assert "$driveLetter -notmatch '^[A-Za-z]$'" in mount
    assert "Get-LibertixFreeDriveLetter" in mount
    assert "-AccessPath $assignedAccessPath" in mount
    assert "-AssignDriveLetter" not in mount
    assert "Remove-PartitionAccessPath" in mount


def test_auto_test_documentation_points_detailed_logs_to_run_workspaces() -> None:
    documentation = read("auto_tests/README.md")

    assert "the request workspace in `auto_tests/runtime/captures/`" in documentation
    assert "detailed file automatically under\n`auto_tests/logs/`" not in documentation
    assert "A published `dev_<sha7>` build enables this" in documentation
    assert "Published builds do not enable this contract" not in documentation


def test_web_form_uses_the_shared_four_character_password_minimum() -> None:
    web = read("auto_tests/app/web/index.html")

    assert 'minlength="4"' in web
    assert 'minlength="8"' not in web


def test_developer_terminal_is_verbose_and_initialized_only_once() -> None:
    runner = read("assets/live/libertix-runner-main.sh")

    assert "DEV_TERMINAL_ACTIVE=false" in runner
    assert '[ "$DEV_TERMINAL_ACTIVE" = false ] || return 1' in runner
    assert "DEV_TERMINAL_ACTIVE=true" in runner
    assert 'UI_MODE="details"' in runner
    assert "log_lines=$((rows - 10))" in runner
    assert 'tail -n "$log_lines" "$LOG"' in runner
    assert 'render_key="$(current_stage):$UI_MODE:$log_size"' in runner


def test_live_logs_are_copied_completely_and_verified() -> None:
    helper = read("assets/live/libertix-copy-logs.sh")
    build = read("iso-tools/build-iso.sh")

    assert "journalctl -b --no-pager" in helper
    assert 'dmesg > "$LOG_DIR/dmesg.log"' in helper
    assert "cp -f /var/log/Xorg.*.log" in helper
    assert 'umount "$target"' in helper
    assert 'mount -t ntfs-3g -o rw "$win" "$target"' in helper
    assert 'cp -a "$LOG_DIR/." "$log_dir/"' in helper
    assert "sha256sum > SHA256SUMS" in helper
    assert "trap cleanup_mount EXIT" in helper
    assert 'mount -t ntfs-3g -o ro "$win" "$target"' in helper
    assert 'log_root="$target/LibertixInstallLogs/Linux"' in helper

    runner = read("assets/live/libertix-runner-main.sh")
    assert "/usr/local/sbin/libertix-copy-logs" in runner
    assert "libertix-copy-logs.sh" in build
    assert 'LOG_COPY_STATUS="success"' in runner


def test_product_logs_are_grouped_by_operating_system_without_retention() -> None:
    application_logger = read("Helpers/ApplicationLogger.cs")
    preparation = read("Pages/ApplyChanges.Cancellation.cs")
    bios_recovery = read("Scripts/libertix-recovery-guard.ps1")
    uefi_recovery = read("Scripts/libertix-uefi-recovery-agent.ps1")
    windows_share = read("Scripts/libertix-configure-windows-share.ps1")
    first_boot = read("assets/live/libertix-first-boot-verify.py")

    assert "RuntimeNames.WindowsLogDirectory" in application_logger
    assert "RuntimeNames.WindowsLogDirectory" in preparation
    assert "PruneApplicationLogs" not in application_logger
    assert '"LibertixInstallLogs\\Windows"' in bios_recovery
    assert '"LibertixInstallLogs\\Linux"' in bios_recovery
    assert '"LibertixInstallLogs\\Windows\\$($State.RunId)"' in uefi_recovery
    assert '"LibertixInstallLogs\\Windows"' in windows_share
    assert 'WINDOWS_LOG_ROOT = Path("LibertixInstallLogs/Linux")' in first_boot
    assert "archive_linux_diagnostics(plan, windows_device)" in first_boot


def test_grub_submenu_entries_always_have_a_transparent_icon_class() -> None:
    renderer = read("grub/render-libertix-menu.py")
    assert "add_invisible_icon_class" in renderer
    assert "--class find.none" in renderer
    assert (ROOT / "assets/grub-theme/icons/find.none.png").is_file()


@pytest.mark.parametrize(
    ("display_name", "icon"),
    [
        ("Linux Mint 22.3 Cinnamon", "linuxmint"),
        ("Zorin OS 18.1 Core", "zorin"),
    ],
)
def test_grub_renderer_uses_plan_presentation_without_flattening_advanced_entries(
    tmp_path: Path,
    display_name: str,
    icon: str,
) -> None:
    linux = tmp_path / "linux.cfg"
    windows = tmp_path / "windows.cfg"
    firmware = tmp_path / "firmware.cfg"
    plan = tmp_path / "installation-plan.json"
    linux.write_text(
        "menuentry 'Vendor Linux' --class vendor --class gnu-linux {\n"
        "\tlinux /vmlinuz\n"
        "}\n"
        "submenu 'Advanced options for Vendor Linux' --class vendor {\n"
        "\tmenuentry 'Vendor Linux recovery' --class vendor {\n"
        "\t}\n"
        "}\n",
        encoding="utf-8",
    )
    windows.write_text("menuentry 'Windows Boot Manager' --class windows {\n}\n", encoding="utf-8")
    firmware.write_text(
        "menuentry 'UEFI Firmware Settings' --class firmware {\n}\n", encoding="utf-8"
    )
    plan.write_text(
        json.dumps(
            {
                "distribution": {"grubDisplayName": display_name, "grubIcon": icon},
                "locale": {"languageCode": "en"},
            }
        ),
        encoding="utf-8",
    )

    rendered = subprocess.run(
        [
            "python3",
            str(ROOT / "grub/render-libertix-menu.py"),
            "--linux",
            str(linux),
            "--windows",
            str(windows),
            "--firmware",
            str(firmware),
            "--plan",
            str(plan),
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    assert f"menuentry '{display_name}' --class {icon} --class vendor" in rendered
    assert rendered.count("submenu 'Advanced options' --class efi") == 1
    advanced = rendered.split("submenu 'Advanced options' --class efi", 1)[1]
    assert "Vendor Linux recovery" in advanced
    assert "UEFI Firmware Settings" in advanced
    assert (ROOT / f"assets/grub-theme/icons/{icon}.png").is_file()


def test_grub_renderer_nests_capability_generators_without_extra_root_entries(
    tmp_path: Path,
) -> None:
    linux = tmp_path / "linux.cfg"
    windows = tmp_path / "windows.cfg"
    firmware = tmp_path / "firmware.cfg"
    memtest = tmp_path / "memtest.cfg"
    plan = tmp_path / "installation-plan.json"
    linux.write_text(
        "menuentry 'Vendor Linux' --class vendor {\n}\n"
        "submenu 'Advanced options for Vendor Linux' --class vendor {\n"
        "\tmenuentry 'Vendor recovery' --class vendor {\n\t}\n}\n",
        encoding="utf-8",
    )
    windows.write_text("menuentry 'Windows' --class windows {\n}\n", encoding="utf-8")
    firmware.write_text("menuentry 'UEFI Firmware Settings' {\n}\n", encoding="utf-8")
    memtest.write_text(
        "menuentry 'Memory test' --class memtest86 {\n\tlinux16 /memtest86+.bin\n}\n",
        encoding="utf-8",
    )
    plan.write_text(
        json.dumps(
            {
                "distribution": {"grubDisplayName": "Vendor Linux", "grubIcon": "vendor"},
                "locale": {"languageCode": "en"},
            }
        ),
        encoding="utf-8",
    )

    rendered = subprocess.run(
        [
            "python3",
            str(ROOT / "grub/render-libertix-menu.py"),
            "--linux",
            str(linux),
            "--windows",
            str(windows),
            "--firmware",
            str(firmware),
            "--extra",
            str(memtest),
            "--plan",
            str(plan),
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout

    root_entries = [
        line for line in rendered.splitlines() if line.startswith(("menuentry ", "submenu "))
    ]
    assert len(root_entries) == 4
    advanced = rendered.split("submenu 'Advanced options' --class efi", 1)[1]
    assert "Memory test" in advanced
    assert "UEFI Firmware Settings" in advanced


def test_distribution_payload_validation_is_capability_driven(tmp_path: Path) -> None:
    iso_root = tmp_path / "iso"
    rootfs = iso_root / "casper/filesystem.squashfs"
    rootfs.parent.mkdir(parents=True)
    rootfs.write_bytes(b"test rootfs")
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    fake_unsquashfs = fake_bin / "unsquashfs"
    fake_unsquashfs.write_text(
        "#!/bin/sh\n"
        'if [ "$1" = -ll ]; then printf \'%s\\n\' "squashfs-root/$3"; exit 0; fi\n'
        'if [ "$1" = -cat ] && [ "$3" = etc/os-release ]; then\n'
        "  printf '%s\\n' 'ID=sample' 'ID_LIKE=\"ubuntu debian\"'; exit 0\n"
        "fi\n"
        "exit 1\n",
        encoding="utf-8",
    )
    fake_unsquashfs.chmod(0o755)
    module = ROOT / "assets/live/libertix-distribution-common.sh"
    command = (
        f"PATH={str(fake_bin)!r}:$PATH; . {str(module)!r}; "
        f"resolved=$(resolve_distribution_rootfs_or_die {str(iso_root)!r}); "
        'test "$resolved" = ' + repr(str(rootfs)) + "; "
        'assert_distribution_rootfs_compatible_or_die "$resolved" sample; '
        'if assert_distribution_rootfs_compatible_or_die "$resolved" other; then exit 9; fi'
    )

    result = subprocess.run(["bash", "-c", command], check=False, capture_output=True, text=True)

    assert result.returncode == 0, result.stderr
    assert "Distribution payload verified: ID=sample ID_LIKE=ubuntu debian" in result.stdout
    source = module.read_text(encoding="utf-8")
    assert 'case "$DISTRIBUTION_ID"' not in source
    assert "mint" not in source.casefold()
    assert "zorin" not in source.casefold()


def test_target_rebuilds_initramfs_without_live_boot_markers() -> None:
    target = read("assets/live/configure-target-main.sh")
    distribution = read("assets/live/libertix-distribution-common.sh")

    assert "refresh_installed_initramfs" in target
    assert "env -u CASPER_GENERATE_UUID update-initramfs -u -k all" in target
    assert "default-boot-to-casper" in target
    assert "live-initrd" in target
    assert "conf/uuid" in target
    assert target.index("cleanup_live_boot_artifacts") < target.index("refresh_installed_initramfs")
    assert "usr/sbin/update-initramfs" in distribution
    assert "usr/bin/lsinitramfs" in distribution


def test_windows_storage_waits_only_for_small_transient_free_space_deficits() -> None:
    policy = read("Scripts/modules/Libertix.StorageGeometry.psm1")
    bios = read("Scripts/libertix-bios-storage.ps1")
    uefi = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")

    assert "Get-LibertixInstallationPolicy" in policy
    assert "targetWindowsFreeSpaceGiB" in policy
    assert "windowsFreeSpaceToleranceGiB" in policy
    assert "windowsFreeSpaceRetryWindowGiB" in policy
    assert "function Wait-LibertixWindowsFreeSpaceBudget" in policy
    assert "$deficitBytes -gt $retryWindowBytes" in policy
    assert "$stopwatch.Elapsed.TotalSeconds -ge $TimeoutSeconds" in policy
    assert "Wait-LibertixWindowsFreeSpaceBudget" in bios
    assert "Wait-LibertixWindowsFreeSpaceBudget" in uefi


def test_grub_generators_remain_nested_after_package_updates() -> None:
    target = read("assets/live/configure-target-main.sh")
    validator = read("assets/live/libertix-validate-grub.sh")
    postinstall = read("auto_tests/app/services/automation_postinstall.py")

    assert "dpkg-divert --local --add --rename --divert" in target
    assert "dpkg-divert --truename" in target
    assert "/usr/local/lib/libertix/grub-generators/10_linux" in target
    assert "/usr/local/lib/libertix/grub-generators/30_uefi-firmware" in target
    assert "/etc/grub.d/20_memtest86+" in target
    assert '"/usr/local/lib/libertix/grub-generators/$(basename "$generator")"' in target
    firmware_diversion = (
        "/usr/local/lib/libertix/grub-generators/30_uefi-firmware \\\n        optional"
    )
    assert firmware_diversion in target
    assert target.count("optional") >= 3
    assert 'parser.add_argument("--extra"' in read("grub/render-libertix-menu.py")
    assert "chmod -x /etc/grub.d/10_linux" not in target
    root_entry_pattern = "grep -Ec '^(menuentry|submenu) '"
    assert "/usr/local/lib/libertix/libertix-validate-grub" in target
    assert root_entry_pattern in validator
    assert root_entry_pattern in postinstall
    assert 'RemoteCheck(\n                "linux.grub_regeneration"' in postinstall
    assert "update-grub; grub-script-check /boot/grub/grub.cfg" in postinstall
    assert "dpkg-divert --listpackage" in postinstall
    assert postinstall.count("--id libertix-advanced") >= 2
    assert postinstall.count("--id libertix-shutdown") >= 2
    assert "submenu 'Advanced options' --class efi" not in postinstall
    assert "menuentry 'Shutdown' --class shutdown" not in postinstall


@pytest.mark.parametrize(
    ("system_lang", "expected"),
    [
        ("fr_FR.UTF-8", ["fr_FR.UTF-8 UTF-8", "en_US.UTF-8 UTF-8"]),
        ("en_US.UTF-8", ["en_US.UTF-8 UTF-8"]),
        ("es_ES.UTF-8", ["es_ES.UTF-8 UTF-8", "en_US.UTF-8 UTF-8"]),
    ],
)
def test_target_generates_only_the_selected_and_fallback_locales(
    system_lang: str,
    expected: list[str],
    tmp_path: Path,
) -> None:
    locale_gen_file = tmp_path / "locale.gen"
    command = r"""
set -eu
SYSTEM_LANG="$1"
locale_gen_file="$2"
{
    printf '%s UTF-8\n' "$SYSTEM_LANG"
    if [ "$SYSTEM_LANG" != "en_US.UTF-8" ]; then
        printf '%s UTF-8\n' "en_US.UTF-8"
    fi
} > "$locale_gen_file"
"""
    result = subprocess.run(
        ["bash", "-c", command, "locale-test", system_lang, str(locale_gen_file)],
        check=True,
        capture_output=True,
        text=True,
    )

    assert locale_gen_file.read_text(encoding="utf-8").splitlines() == expected
    assert result.stdout == ""
    target = read("assets/live/configure-target-main.sh")
    assert "> /etc/locale.gen" in target
    assert 'if [ "$SYSTEM_LANG" != "en_US.UTF-8" ]' in target
    assert 'if [ -d "$supported_directory" ]; then' in target
    assert 'mv "$supported_directory" "$supported_backup"' in target
    assert 'mv "$supported_backup" "$supported_directory"' in target
    assert "locale-gen || locale_status=$?" in target


def test_grub_kernel_update_keeps_all_advanced_entries_nested() -> None:
    renderer = runpy.run_path(str(ROOT / "grub/render-libertix-menu.py"))
    extract = renderer["extract_top_level_block"]
    lines = [
        "submenu 'Advanced options for Linux Mint' {",
        "\tmenuentry 'Linux Mint, with Linux new' {",
        "\t}",
        "\tmenuentry 'Linux Mint, with Linux new (recovery mode)' {",
        "\t}",
        "\tmenuentry 'Linux Mint, with Linux old' {",
        "\t}",
        "\tmenuentry 'Linux Mint, with Linux old (recovery mode)' {",
        "\t}",
        "}",
        "menuentry 'trailing sentinel' {",
        "}",
    ]

    assert extract(lines, "submenu ") == (0, 10)


def test_compatibility_preflight_forces_utf8_console_codepage() -> None:
    script = read("Scripts/libertix-compatibility-preflight.ps1")
    runner = read("Helpers/CompatibilityPreflightRunner.cs")
    assert 'chcp.com" 65001' in script
    assert "[Console]::OutputEncoding" in script
    assert "[Console]::InputEncoding" in script
    assert "StandardOutputEncoding = Encoding.UTF8" in runner
    assert "PowerShellJsonResult.ParseFinalObject" in runner
    assert "NormalizeUtf8Line" not in runner
    assert "Encoding.GetEncoding(1252).GetBytes(line)" not in runner


def test_compatibility_preflight_imports_the_central_installation_policy() -> None:
    preflight = read("Scripts/libertix-compatibility-preflight.ps1")

    assert '"modules\\Libertix.InstallationPolicy.psm1"' in preflight
    policy_import = "Import-Module -Name $policyModulePath -Force -ErrorAction Stop"
    geometry_import = "Import-Module -Name $geometryModule -Force -ErrorAction Stop"
    policy_read = "$installationPolicy = Get-LibertixInstallationPolicy"
    assert geometry_import in preflight
    assert policy_import in preflight
    assert preflight.index(geometry_import) < preflight.index(policy_import)
    assert preflight.index(policy_import) < preflight.index(policy_read)


def test_compatibility_runner_drains_async_output_before_parsing_final_fields() -> None:
    runner = read("Helpers/CompatibilityPreflightRunner.cs")
    timeout_wait = (
        "process.WaitForExit((int)WindowsProcessTimeouts.CompatibilityPreflight.TotalMilliseconds)"
    )
    timeout_position = runner.index(timeout_wait)
    drain_position = runner.index("process.WaitForExit();", timeout_position)
    diagnostics_position = runner.index("string diagnostics =", drain_position)

    assert timeout_position < drain_position < diagnostics_position


def test_storage_controller_inventory_has_a_bounded_fail_closed_timeout() -> None:
    script = read("Scripts/libertix-compatibility-preflight.ps1")
    helper = script.split("function Get-StorageControllerNames", 1)[1].split(
        "function Get-SecureBootDbCertificates", 1
    )[0]

    assert "$operationTimeoutSeconds = 15" in helper
    assert "-OperationTimeoutSec $operationTimeoutSeconds" in helper
    assert "-ErrorAction Stop" in helper
    assert "Stop-Compatibility `" in helper
    assert '"COMPAT_E_STORAGE_CONTROLLER_QUERY"' in helper
    assert "SilentlyContinue" not in helper


def test_compatibility_shrink_capacity_reserves_cloned_layout_alignment() -> None:
    script = read("Scripts/libertix-compatibility-preflight.ps1")

    assert '"modules\\Libertix.StorageGeometry.psm1"' in script
    assert "$alignmentPadding = Get-LibertixPartitionEndAlignmentPadding" in script
    assert "[long]$partition.Size - [long]$supportedSize.SizeMin - $alignmentPadding" in script
    assert '$firmware -eq "BIOS"' in script
    assert "$shrinkAvailable -= Get-LibertixPartitionAlignmentBytes" in script
    assert "$disk.PhysicalSectorSize % $disk.LogicalSectorSize -ne 0" in script


def test_resize_page_keeps_exact_free_space_for_capacity_policy() -> None:
    page = read("Pages/ResizeDisk.xaml.cs")
    size_policy = read("Installation/InstallationSizePolicy.cs")
    storage_policy = read("Scripts/modules/Libertix.StorageGeometry.psm1")

    assert "_initialFreeSpace =" in page
    assert "systemDrive.AvailableFreeSpace / 1024.0 / 1024.0 / 1024.0" in page
    assert "_initialFreeSpace = Math.Round" not in page
    assert "_installationState.Compatibility?.ShrinkAvailableBytes" in page
    assert "InstallationSizePolicy.AvailableLinuxSizeGiB(" in page
    assert "InstallationSizePolicy.RemainingWindowsFreeSpaceGiB(" in page
    assert "initialWindowsFreeGiB - installerIsoGiB - MinimumWindowsFreeSpaceGiB" in size_policy
    assert "InstallationPolicy.Current.Storage.TargetWindowsFreeSpaceGiB" in size_policy
    assert "InstallationPolicy.Current.Storage.WindowsFreeSpaceToleranceGiB" in size_policy
    assert "TargetWindowsFreeSpaceGiB - WindowsFreeSpaceToleranceGiB" in size_policy
    assert "targetWindowsFreeSpaceGiB" in storage_policy
    assert "windowsFreeSpaceToleranceGiB" in storage_policy
    assert "InstallationSizePolicy.MinimumWindowsFreeSpaceGiB" in page


def test_protected_account_hash_uses_a_posix_line_ending() -> None:
    plan = read("Pages/ApplyChanges.Plan.cs")

    assert 'WriteProtectedInstallerFile(passwordHashWindowsPath, passwordHash + "\\n")' in plan
    assert "passwordHash + Environment.NewLine" not in plan


def test_live_context_exports_the_validated_plan_for_target_configuration() -> None:
    context = read("assets/live/libertix-live-context.sh")
    target = read("assets/live/libertix-target-common.sh")

    assert 'INSTALLATION_PLAN_PATH="$plan_path"' in context
    assert "export INSTALLATION_PLAN_PATH INSTALLATION_STATE_PATH" in context
    assert 'install -m 0644 "$INSTALLATION_PLAN_PATH"' in target


def test_target_configuration_creates_the_first_boot_verifier_directory() -> None:
    target = read("assets/live/libertix-target-common.sh")
    directory_creation = "install -d -m 0755 /mnt/target/usr/local/lib/libertix"
    verifier_destination = "/mnt/target/usr/local/lib/libertix/libertix-first-boot-verify.py"

    assert directory_creation in target
    assert verifier_destination in target
    assert target.index(directory_creation) < target.index(verifier_destination)


def test_nvram_write_probe_opt_out_is_explicit_and_never_reported_as_passed() -> None:
    startup = read("Helpers/StartupOptions.cs")
    page = read("Pages/CompatibilityCheck.xaml.cs")
    runner = read("Helpers/CompatibilityPreflightRunner.cs")
    script = read("Scripts/libertix-compatibility-preflight.ps1")

    assert 'SkipNvramWriteProbeOption = "--skip-nvram-write-probe"' in startup
    assert "RuntimeOptions.SkipNvramWriteProbe" in page
    assert 'arguments += " -SkipNvramWriteProbe"' in runner
    assert "[switch]$SkipNvramWriteProbe" in script
    skipped_branch = script.split("if ($SkipNvramWriteProbe) {", 1)[1].split("} else {", 1)[0]
    assert "$nvramSkipped = $true" in skipped_branch
    assert "$nvramPassed = $true" not in skipped_branch
    assert "nvramProbeSkipped = [bool]$nvramSkipped" in script


def test_nvram_probe_tests_bootnext_without_a_vendor_variable() -> None:
    script = read("Scripts/libertix-compatibility-preflight.ps1")

    assert "LibertixCompatibilityProbe" not in script
    assert '$bootCurrent = Get-NvramVariable -Name "BootCurrent"' in script
    assert 'Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $bootCurrent.Bytes' in script
    assert '$bootNext = Get-NvramVariable -Name "BootNext"' in script
    assert 'Set-NvramVariable -Name "BootNext" -Guid $global -Bytes $null' in script


def test_force_uefi_diagnostic_uses_a_unique_remote_script_and_finally_cleanup() -> None:
    tool = read("auto_tests/tools/force_uefi_bootnext_failure.py")

    assert "uuid.uuid4().hex" in tool
    assert 'remote_os="windows"' in tool
    assert "finally:" in tool
    assert "force-uefi-bootnext-failure-{run_id}.ps1" in tool
    assert "if exist {remote_windows_script} exit /b 1" in tool
    assert 'step="test.force_bootnext.cleanup"' in tool
    assert "check=True" in tool


def test_boot_guardian_fault_fixture_is_owned_bounded_and_verified() -> None:
    fixture = read("auto_tests/app/scripts/test_boot_guardian_fault.ps1")
    preferred_fixture = read("auto_tests/app/scripts/test_boot_guardian_preferred_path_fault.ps1")
    automation = read("auto_tests/app/services/automation_postinstall.py")

    for action in (
        "plan-boot-order",
        "inject-boot-order",
        "verify-boot-order",
        "plan-preferred-bypass",
        "inject-preferred-bypass",
    ):
        assert f'"{action}"' in fixture
    assert '"The active guardian configuration differs from its permanent archive."' in fixture
    assert 'ExpectedPath "\\EFI\\Microsoft\\Boot\\bootmgfw.efi"' in fixture
    assert '-Name "BootOrder" `\n            -Value (ConvertTo-BootOrderBytes' in fixture
    assert '"Firmware did not retain the injected BootOrder fault."' in fixture
    assert "REPAIR: BootOrder changed from" in fixture
    assert 'Stop-Service -Name "LibertixBootGuardian"' in fixture
    assert "WaitForStatus" not in fixture
    assert "Win32_Service `\n                    -Filter \"Name='LibertixBootGuardian'\"" in fixture
    assert '"The boot guardian service did not stop within 15 seconds."' in fixture
    assert 'config={"action": "plan-boot-order"}' in automation
    assert 'config={"action": "inject-boot-order"}' in automation
    assert '"action": "verify-boot-order"' in automation
    for action in ("plan-loader", "inject-loader", "verify-loader"):
        assert f'"{action}"' in preferred_fixture
    assert "Copy-LibertixPreferredPathFileAtomic" in preferred_fixture
    assert "The permanent original Windows Boot Manager archive is missing." in preferred_fixture
    assert "unexpected-efi\\shimx64.efi-$originalHash.bin" in preferred_fixture
    assert 'config={"mode": "preferred-accept"}' in automation
    assert 'config={"mode": "preferred-reboot"}' in automation
    assert 'config={"action": "plan-loader"}' in automation
    assert 'config={"action": "inject-loader"}' in automation
    assert '"action": "verify-loader"' in automation


def test_boot_guardian_commands_do_not_depend_on_last_exit_code_scope() -> None:
    module = read("Scripts/modules/Libertix.BootGuardian.psm1")

    assert "function Invoke-LibertixBootGuardianCommand" in module
    assert "Start-Process `" in module
    assert "-Wait `" in module
    assert "-PassThru `" in module
    assert "$LASTEXITCODE" not in module


def test_compatibility_output_is_persisted_in_the_application_log() -> None:
    runner = read("Helpers/CompatibilityPreflightRunner.cs")

    assert 'ApplicationLogger.Write("COMPATIBILITY STDOUT: " + args.Data)' in runner
    assert 'ApplicationLogger.Write("COMPATIBILITY STDERR: " + args.Data)' in runner
    assert 'ApplicationLogger.WriteException("COMPATIBILITY: preflight failed.", ex)' in runner


def test_windows_manifest_declares_supported_platform_dpi_and_long_paths() -> None:
    root = ET.parse(ROOT / "app1.manifest").getroot()
    supported = root.find(".//{urn:schemas-microsoft-com:compatibility.v1}supportedOS")
    dpi_legacy = root.find(".//{http://schemas.microsoft.com/SMI/2005/WindowsSettings}dpiAware")
    dpi_current = root.find(
        ".//{http://schemas.microsoft.com/SMI/2016/WindowsSettings}dpiAwareness"
    )
    long_paths = root.find(
        ".//{http://schemas.microsoft.com/SMI/2016/WindowsSettings}longPathAware"
    )

    assert supported is not None
    assert supported.attrib["Id"] == "{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"
    assert dpi_legacy is not None and dpi_legacy.text == "true/pm"
    assert dpi_current is not None and dpi_current.text.startswith("PerMonitorV2")
    assert long_paths is not None and long_paths.text == "true"


def test_grub_decorations_use_guarded_desktop_bitmap_path() -> None:
    theme = read("assets/grub-theme/theme.txt")
    generator = read("assets/grub-theme/generate-theme.sh")
    assert 'desktop-image: "background.png"' in theme
    assert "+ image {" not in theme
    assert "background.png" in generator


def test_large_local_artifacts_do_not_use_tmpfs_paths() -> None:
    settings = read("auto_tests/app/config.py")
    validation = read("auto_tests/app/services/validation.py")
    builder = read("iso-tools/build-isos-docker.sh")
    verifier = read("docker/iso-builder/verify-built-iso.sh")
    bios_defaults = read("iso/config/defaults.env")
    uefi_defaults = read("iso-uefi/config/defaults.env")

    assert 'runtime_dir: Path = Path(__file__).resolve().parents[1] / "runtime"' in settings
    assert 'capture_dir: Path = Path(__file__).resolve().parents[1] / "runtime"' in settings
    assert 'archive_directory = s.runtime_dir / "source-archives"' in validation
    assert 'PurePosixPath(s.smb_root) / f".{archive.name}"' in validation
    assert "--tmpfs" not in builder
    assert '--volume "$WORK_VOLUME:/var/lib/libertix-work"' in builder
    assert 'verification_root="/var/lib/libertix-work/$mode/verification"' in verifier
    assert 'mktemp -d "$verification_root/run.XXXXXX"' in verifier
    assert "/var/lib/libertix-work/bios" in bios_defaults
    assert "/var/lib/libertix-work/uefi" in uefi_defaults


def test_iso_verification_covers_state_runtime_and_builds_are_serialized() -> None:
    builder = read("iso-tools/build-isos-docker.sh")
    verifier = read("docker/iso-builder/verify-built-iso.sh")

    assert "libertix-installation-state.py" in verifier
    assert "libertix_progress.py" in verifier
    assert 'LOCK_FILE="$LOCK_DIR/iso-build.lock"' in builder
    assert "flock -n 9" in builder
    assert "label=com.ekimia.libertix.iso-builder=true" in builder
    assert "label=com.ekimia.libertix.iso-workspace=$WORKSPACE_ID" in builder
    assert 'docker ps -q --filter "ancestor=$IMAGE_NAME"' not in builder


def test_uefi_rollback_proves_firmware_and_esp_cleanup() -> None:
    live = read("assets/live/libertix-uefi-adapter.sh")
    firmware = read("Scripts/uefi/Libertix.Uefi.Firmware.ps1")
    prepare = live.split("firmware_prepare_rollback_best_effort()", 1)[1].split(
        "uefi_partition_table_or_die()", 1
    )[0]
    cleanup = live.split("cleanup_final_uefi_bootloader_best_effort()", 1)[1].split(
        "set_linux_partition_type_or_die()", 1
    )[0]
    restore = live.split("firmware_restore_boot_state_best_effort()", 1)[1].split(
        "firmware_write_failure_marker_best_effort()", 1
    )[0]
    powershell_cleanup = firmware.split("function Get-ValidatedTemporaryFirmwareCleanupState", 1)[
        1
    ].split("function Set-NativeUefiBootOrderOnce", 1)[0]

    assert "cleanup_final_uefi_bootloader_best_effort || true" not in prepare
    assert 'efibootmgr -b "$bootnum" -B || return 1' in cleanup
    assert '[ ! -e "$esp_mount/EFI/Libertix" ] || return 1' in cleanup
    assert 'umount "$esp_mount" || return 1' in cleanup
    assert 'parted -s "$DISK" set "$esp_num" esp on 2>/dev/null || return 1' in restore
    assert "Temporary Libertix BCD firmware entries remain after cleanup" in powershell_cleanup
    assert "Get-ValidatedTemporaryFirmwareCleanupState" in powershell_cleanup
    assert "Test-BcdFirmwareEntryLoaderPath" in powershell_cleanup
    assert "Test-EfiLoadOptionLoaderPath" in powershell_cleanup
    assert "Assert-FirmwareBootNumberAbsent" in powershell_cleanup
    assert "Remove-BcdFirmwareEntriesByDescription" not in powershell_cleanup
    assert "Remove-NativeFirmwareEntriesByDescription" not in powershell_cleanup
    assert (
        "Temporary Libertix firmware entry Boot{0:X4} remains after cleanup" in powershell_cleanup
    )


def test_wpf_runtime_failure_paths_are_bounded_and_recoverable() -> None:
    app = read("App.xaml.cs")
    localization = read("Localization.cs")
    apply_page = read("Pages/ApplyChanges.xaml.cs")
    resize_page = read("Pages/ResizeDisk.xaml.cs")
    resize_xaml = read("Pages/ResizeDisk.xaml")

    assert '@"Global\\Libertix.Installation"' in app
    assert "_ownsSingleInstanceMutex = createdNew;" in app
    assert "if (_ownsSingleInstanceMutex)" in app
    assert "_singleInstanceMutex.Dispose();" in app.split("if (!createdNew)", 1)[1]
    assert '"Resources",' in localization
    assert '"Libertix.Translations.json"' in localization
    assert (
        "Application.Current.Resources.MergedDictionaries.Remove(_languageDictionary)"
        in localization
    )
    assert "return fallback;" in localization
    assert "Unloaded += ApplyChanges_Unloaded;" in apply_page
    assert "_installationCancellation.Dispose();" in apply_page
    assert "cleanmgr.exe" not in resize_page
    assert "OpenDiskCleanup" not in resize_page
    assert "OpenDiskCleanup" not in resize_xaml
    assert 'Message="{DynamicResource FreeUpSpace}"' in resize_xaml


def test_distribution_selection_reuses_compatibility_and_publishes_catalog_atomically() -> None:
    chooser = read("Pages/ChooseDistro.xaml.cs")
    chooser_xaml = read("Pages/ChooseDistro.xaml")
    catalog_loader = read("Installation/DistributionCatalogLoader.cs")

    assert "_partitionConfigValid = _installationState.Compatibility != null;" in chooser
    assert "CheckPartitionConfigurationAsync" not in chooser
    assert "DistributionCatalogLoader.LoadAsync(_filepool)" in chooser
    assert "ValidateCatalog(catalog);" in catalog_loader
    assert "return CreateDistributions(catalog, filepool);" in catalog_loader
    assert "var distributions = new List<DistroInfo>" in catalog_loader
    assert "distributions.Add(new DistroInfo" in catalog_loader
    assert "return distributions;" in catalog_loader
    catalog_loaded = chooser.index("DistributionCatalogLoader.LoadAsync(_filepool)")
    catalog_built = chooser.index(
        "new ObservableCollection<DistroInfo>(validatedDistros)", catalog_loaded
    )
    catalog_published = chooser.index("_distros = publishedDistros;", catalog_built)
    assert (
        chooser.index("DistrosListBox.ItemsSource = _distros;", catalog_published)
        > catalog_published
    )
    assert "_distros.Clear();" not in chooser
    assert "MessageBox.Show(" not in chooser
    assert "RetryCatalogButton_Click" in chooser
    assert 'AutomationProperties.AutomationId="DistroCatalogRetryButton"' in chooser_xaml
    assert "ClearSelection();" in chooser[catalog_loaded:catalog_published]
    assert "RestoreSelection(selectedDistroId);" in chooser[catalog_published:]


def test_dead_command_and_error_panel_action_plumbing_are_removed() -> None:
    project = read("Libertix.csproj")
    panel = read("Controls/ErrorPanel.xaml") + read("Controls/ErrorPanel.xaml.cs")

    assert not (ROOT / "Commands/RelayCommand.cs").exists()
    assert "RelayCommand.cs" not in project
    assert "ActionButtonText" not in panel
    assert "ActionCommand" not in panel


def test_navigation_falls_back_to_immediate_navigation_without_ui_content() -> None:
    navigation = read("Helpers/NavigationHelper.cs")

    assert navigation.count("NavigateWithAnimationCore(") == 3
    fallback = navigation.split("if (!(currentContent is UIElement currentPage))", 1)[1]
    assert fallback.index("navigate(newPage);") < fallback.index("var fadeOut")
    assert "if (!currentPage.IsHitTestVisible)" in navigation
    assert "currentPage.IsHitTestVisible = false;" in navigation
    assert "currentPage.IsHitTestVisible = true;" in navigation
    assert navigation.count("FillBehavior = FillBehavior.Stop") == 2
    completed = navigation.split("fadeOut.Completed +=", 1)[1]
    assert completed.index("BeginAnimation(UIElement.OpacityProperty, null)") < completed.index(
        "navigate(newPage)"
    )


def test_long_windows_native_checks_emit_structured_utf8_safe_summaries() -> None:
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")
    decoded_native = checks.split("function Invoke-NativeCommandDecoded", 1)[1].split(
        "function Invoke-NativeCheck", 1
    )[0]
    native_check = checks.split("function Invoke-NativeCheck", 1)[1].split(
        "$config = Get-Content", 1
    )[0]

    assert "ConvertFrom-NativeOutputBytes" in checks
    assert "Text.DecoderFallbackException" in checks
    assert "CurrentCulture.TextInfo.OEMCodePage" in checks
    assert "RedirectStandardOutput $stdoutPath" in decoded_native
    assert "RedirectStandardError $stderrPath" in decoded_native
    assert "Read-NativeOutputText -LiteralPath $stdoutPath" in decoded_native
    assert "Read-NativeOutputText -LiteralPath $stderrPath" in decoded_native
    assert "$result = Invoke-NativeCommandDecoded" in native_check
    assert "$diagnostic.Length -gt 2000" in native_check
    assert 'Write-Output "NATIVE_COMMAND=$FilePath EXIT_CODE=$($result.ExitCode)"' in native_check
    assert "@(& $FilePath @Arguments 2>&1)" not in native_check
    assert 'Invoke-NativeCommandDecoded -FilePath "reagentc.exe"' in checks
    assert 'Invoke-NativeCommandDecoded -FilePath "bcdedit.exe"' in checks
    assert "@(& reagentc.exe /info 2>&1)" not in checks
    assert "@(& bcdedit.exe /enum all 2>&1)" not in checks


def test_postinstall_winre_and_bios_boot_checks_are_locale_independent() -> None:
    module = read("Scripts/modules/Libertix.PostInstallVerification.psm1")
    checks = read("auto_tests/app/scripts/post_install_windows_check.ps1")

    windows_health = module.split("function Test-LibertixWindowsHealth", 1)[1].split(
        "function Test-LibertixWindowsBootConfiguration", 1
    )[0]
    assert "reagentc.exe /enable" in windows_health
    assert "reagentc.exe /info" not in windows_health
    assert "deshabilitado" not in windows_health

    product_boot = module.split("function Test-LibertixWindowsBootConfiguration", 1)[1].split(
        "function Test-LibertixWindowsTemporaryArtifacts", 1
    )[0]
    automation_boot = checks.split('"boot_partition"', 1)[1].split('"boot_configuration"', 1)[0]
    for boot_check in (product_boot, automation_boot):
        assert "Where-Object { $_.IsSystem }" in boot_check
        assert "Where-Object { $_.IsActive }" in boot_check
        assert boot_check.index("Where-Object { $_.IsSystem }") < boot_check.index(
            "Where-Object { $_.IsActive }"
        )

    recovery_check = checks.split('"recovery"', 1)[1].split('"bitlocker"', 1)[0]
    assert '-Arguments @("/enable")' in recovery_check
    assert '-Arguments @("/info")' not in recovery_check
    assert "deshabilitado" not in recovery_check


def test_boot_guardian_verification_handles_a_missing_service_privilege_value() -> None:
    module = read("Scripts/modules/Libertix.PostInstallVerification.psm1")
    helper = module.split("function Get-LibertixObjectPropertyValues", 1)[1].split("function ", 1)[
        0
    ]
    guardian_check = module.split("function Test-LibertixBootGuardian", 1)[1].split(
        "function Test-LibertixRecoveryArchive", 1
    )[0]

    assert "$InputObject.PSObject.Properties[$Name]" in helper
    assert "@($property.Value)" in helper
    assert '-Name "RequiredPrivileges"' in guardian_check
    assert '$requiredPrivileges -notcontains "SeSystemEnvironmentPrivilege"' in guardian_check
    assert "$serviceRegistry.RequiredPrivileges" not in guardian_check


def test_live_failure_and_cleanup_guards_cover_confirmed_audit_paths() -> None:
    runner = read("assets/live/libertix-runner-main.sh")
    live_context = read("assets/live/libertix-live-context.sh")
    install = read("assets/live/libertix-install-main.sh")
    runtime = read("assets/live/libertix-install-runtime-common.sh")

    assert "load_libertix_live_context_with_retry" in runner
    assert '_context_error_file="$LOG_DIR/context-load-error"' in runner
    assert 'load_libertix_live_context "$LIBERTIX_FIRMWARE_MODE" 2>&1' not in runner
    assert "Live installation context was not available after 30 attempts" in runner
    assert "terminal_hide_cursor" in runner
    assert "terminal_clear" not in runner
    assert "find_libertix_installation_plan() (" in live_context
    assert "trap cleanup_plan_probe EXIT" in live_context
    assert "load_libertix_live_context_with_retry()" in live_context
    retry = live_context.split("load_libertix_live_context_with_retry()", 1)[1].split(
        "durable_bios_mbr_backup_directory()", 1
    )[0]
    assert 'if load_libertix_live_context "$expected_firmware"' in retry
    assert 'STAGE_CATALOG="/usr/local/lib/libertix/libertix-stages.tsv"' in install
    assert "unknown installation stage requested:" in install
    assert "emit_install_result" in runtime
    marker = runtime.split("write_windows_recovery_marker_file_best_effort()", 1)[1]
    assert "(\n        umask 077" in marker


def test_rollback_uses_observed_partition_state_and_always_cleans_esp_mounts() -> None:
    rollback = read("assets/live/libertix-rollback-common.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")
    deletion = rollback.split("delete_transaction_partition_best_effort()", 1)[1].split(
        "restore_windows_partition_best_effort()", 1
    )[0]
    esp_probe = uefi.split("find_esp_partition()", 1)[1].split(
        "cleanup_final_uefi_bootloader_best_effort()", 1
    )[0]
    final_cleanup = uefi.split("cleanup_final_uefi_bootloader_best_effort()", 1)[1].split(
        "set_linux_partition_type_or_die()", 1
    )[0]

    assert "deleted=true" not in deletion
    assert "deleted=false" not in deletion
    assert "transaction partition $NEW_PART_NUM is still present" in deletion
    final_state_failure = deletion.split("transaction partition $NEW_PART_NUM is still present", 1)[
        1
    ]
    assert "return 1" in final_state_failure
    assert "find_esp_partition() (" in uefi
    assert "trap cleanup_esp_probe_mount EXIT HUP INT TERM" in esp_probe
    assert "cleanup_final_uefi_bootloader_best_effort() (" in uefi
    assert "trap cleanup_rollback_esp_mount EXIT" in final_cleanup


@pytest.mark.parametrize(
    ("language", "shutdown", "advanced"),
    [
        ("en", "Shutdown", "Advanced options"),
        ("fr", "Éteindre", "Options avancées"),
        ("es", "Apagar", "Opciones avanzadas"),
    ],
)
def test_grub_renderer_localizes_root_labels(
    tmp_path: Path,
    language: str,
    shutdown: str,
    advanced: str,
) -> None:
    plan = tmp_path / "installation-plan.json"
    plan.write_text(
        json.dumps(
            {
                "distribution": {"grubDisplayName": "Vendor Linux", "grubIcon": "vendor"},
                "locale": {"languageCode": language},
            }
        ),
        encoding="utf-8",
    )
    renderer = runpy.run_path(str(ROOT / "grub/render-libertix-menu.py"))

    _, _, labels = renderer["read_distribution_presentation"](plan)

    assert labels == {"shutdown": shutdown, "advanced": advanced}


def test_grub_contract_is_named_and_reports_specific_failures() -> None:
    validator = read("assets/live/libertix-validate-grub.sh")
    postinstall = read("auto_tests/app/services/automation_postinstall.py")

    assert "readonly expected_root_entries=4" in validator
    assert "EXPECTED_GRUB_ROOT_ENTRY_COUNT = 4" in postinstall
    assert "Generated GRUB configuration has invalid syntax" in validator
    assert "missing the distribution icon class" in validator
    assert "missing the distribution root entry" in validator
    assert "missing the Advanced options submenu" in validator
    assert "missing the Shutdown entry" in validator
    assert "root entries; expected $expected_root_entries" in validator


def test_aria2_connection_limit_comes_from_the_shared_policy() -> None:
    policy = json.loads(read("Scripts/config/Libertix.InstallationPolicy.json"))
    csharp_policy = read("Installation/InstallationPolicy.cs")
    apply_changes = read("Pages/ApplyChanges.xaml.cs")
    powershell_policy = read("Scripts/modules/Libertix.InstallationPolicy.psm1")
    uefi = read("Scripts/libertix-uefi-install.ps1")

    assert policy["download"]["aria2MaximumConnections"] == 5
    assert "InstallationDownloadPolicy Download" in csharp_policy
    assert "InstallationPolicy.Current.Download.Aria2MaximumConnections" in apply_changes
    assert "$policy.download.aria2MaximumConnections" in powershell_policy
    assert "$installationPolicy.download.aria2MaximumConnections" in uefi
    assert "[int]$Aria2Connections = 5" not in uefi
    assert uefi.index("$installationPolicy = Get-LibertixInstallationPolicy") < uefi.index(
        '"Libertix.InstallationPlan.psm1"'
    )


def test_iso_builder_can_finish_without_the_auto_test_filepool() -> None:
    builder = read("iso-tools/build-isos-docker.sh")

    assert "LIBERTIX_ISO_FILEPOOL_DIR" in builder
    assert 'if [ -d "$FILEPOOL_DIR" ]; then' in builder
    assert "filepool directory not present; publication skipped" in builder


@pytest.mark.parametrize(("partition_present", "expected_status"), [(True, 1), (False, 0)])
def test_rollback_partition_deletion_result_depends_on_final_table_state(
    partition_present: bool,
    expected_status: int,
) -> None:
    rollback = ROOT / "assets/live/libertix-rollback-common.sh"
    partition_line = "7:1s:2s:2s:ext4::;" if partition_present else ""
    command = r"""\
source "$1"
firmware_resolve_rollback_partition() { :; }
debug_disk_state() { :; }
parted() {
    printf '%s\n' 'BYT;' '/dev/fake:100s:unknown:512:512:msdos:Fake:;' "$PARTITION_LINE"
}
DISK=/dev/fake
NEW_PART=
NEW_PART_NUM=7
delete_transaction_partition_best_effort
"""

    result = subprocess.run(
        ["bash", "-c", command, "bash", str(rollback)],
        check=False,
        capture_output=True,
        text=True,
        env={"PATH": "/usr/bin:/bin", "PARTITION_LINE": partition_line},
    )

    assert result.returncode == expected_status
    if partition_present:
        assert "transaction partition 7 is still present" in result.stdout
