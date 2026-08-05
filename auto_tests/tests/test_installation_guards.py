from __future__ import annotations

import hashlib
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


def test_live_boot_mode_function_is_fail_closed(
    run_shell_function: Callable[..., subprocess.CompletedProcess[str]],
) -> None:
    library = ROOT / "assets/live/libertix-install-platform-common.sh"

    accepted_low_memory = run_shell_function(
        library,
        "validate_live_boot_mode",
        "true",
        "boot=live findiso=/libertix-live.iso quiet",
    )
    rejected_low_memory = run_shell_function(
        library,
        "validate_live_boot_mode",
        "true",
        "boot=live toram quiet",
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
    ("disk", "number", "expected"),
    [
        ("/dev/sda", "3", "/dev/sda3"),
        ("/dev/nvme0n1", "4", "/dev/nvme0n1p4"),
        ("/dev/mmcblk0", "2", "/dev/mmcblk0p2"),
    ],
)
def test_shared_storage_builds_partition_paths_for_supported_device_names(
    run_shell_function: Callable[..., subprocess.CompletedProcess[str]],
    disk: str,
    number: str,
    expected: str,
) -> None:
    library = ROOT / "assets/live/libertix-storage-common.sh"

    result = run_shell_function(library, "partition_path", disk, number)

    assert result.returncode == 0
    assert result.stdout.strip() == expected


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


def test_detached_partition_check_does_not_query_the_dev_mount() -> None:
    runtime = (ROOT / "assets/live/libertix-install-runtime-common.sh").read_text(encoding="utf-8")
    detached_check = runtime.split("assert_not_mounted_or_open() {", 1)[1].split(
        "mount_ntfs_rw_or_die() {", 1
    )[0]

    assert 'fuser "$partition"' in detached_check
    assert 'fuser -m "$partition"' not in detached_check


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
    assert 'parted -s "$DISK" rm "$extended_number"' in bios_cleanup
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
    assert '"$((original_end_sector - 1))s"' in rollback
    assert 'resize_end="100%"' not in rollback


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
    assert "$candidateOffsets" in bios_guard
    assert "[int64]$partition.Offset -notin $candidateOffsets" in bios_guard
    assert "[int]$partition.MbrType -in @(5, 15, 133)" in bios_guard
    assert "$isRawTransaction" in bios_guard
    assert "[int64]$partitionSizeTolerance = 1MB" in bios_guard
    assert "[int64]$minBytes" in bios_guard
    assert "[int64]$stagingMinBytes" in bios_guard
    assert "[Math]::Max" not in bios_guard


def test_final_verification_counts_mbr_slots_instead_of_lsblk_children() -> None:
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    assert 'primary_slot_count="$(mbr_primary_slot_count "$DISK")"' in bios
    assert 'primary_slot_count="$(mbr_primary_slot_count "$DISK")"' in uefi
    assert "final verify: MBR partition count is" not in bios
    assert "final verify: MBR partition count is" not in uefi


def test_success_retires_stale_uefi_transaction_state_after_final_verification() -> None:
    installer = read("assets/live/libertix-install-main.sh")
    bios = read("assets/live/libertix-bios-adapter.sh")
    uefi = read("assets/live/libertix-uefi-adapter.sh")

    verify_position = installer.index("final_verify_or_die")
    finalize_position = installer.index("firmware_finalize_success_best_effort", verify_position)
    success_position = installer.index("append_install_result true", finalize_position)

    assert verify_position < finalize_position < success_position
    assert "firmware_finalize_success_best_effort()" in bios
    assert "uefi-transaction.json" in uefi
    assert 'mount -t ntfs-3g -o rw "$WINDOWS_PART" "$mountpoint"' in uefi
    assert 'rm -f -- "$transaction_state"' in uefi


def test_low_memory_mode_reaches_bios_and_uefi_configuration() -> None:
    apply_changes = read_apply_changes()
    uefi = read("Scripts/libertix-uefi-install.ps1")
    installer = read("assets/live/libertix-install-main.sh")
    assert ". /usr/local/lib/libertix/libertix-install-platform-common.sh" in installer
    assert "libertix-install-main.sh" in read("iso/live/install-mint.sh")
    assert "libertix-install-main.sh" in read("iso-uefi/live/install-mint.sh")

    assert "ConfigureBiosLowMemoryBootAsync" in apply_changes
    assert "LowMemoryMode =" in apply_changes
    assert "compatibility.LowMemoryMode" in apply_changes
    assert "$LowMemoryMode" in uefi
    assert "findiso=/libertix-live.iso" in read("Scripts/uefi/Libertix.Uefi.Staging.ps1")


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
    unknown_label = run_localized_stage_function("libertix_stage_label", "custom-stage")

    assert label.returncode == 0
    assert label.stdout.strip() == "Extracting Mint"
    assert percent.returncode == 0
    assert percent.stdout.strip() == "64"
    assert unknown_label.stdout.strip() == "custom-stage"


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


def test_uefi_fallback_publishes_recovery_phase_atomically() -> None:
    fallback = read("Pages/UefiBootFallback.xaml.cs")

    save_state = fallback.split("private void SaveState()", 1)[1].split(
        "private static string QuoteArgument", 1
    )[0]
    assert "AtomicJsonFile.Write(_statePath" in save_state
    assert "File.WriteAllText" not in save_state


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
    assert 'alignment_tolerance_bytes="${3:-1048576}"' in storage


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
    assert "excludedProfiles.Contains(profileName)" in apply_changes


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
    assert (
        '$shellApplication.Namespace($junctionPath).Self.InvokeVerb("pintohome")' in windows_share
    )
    assert "Refusing to replace a non-junction path" in windows_share
    assert "Get-CimInstance Win32_UserProfile" in windows_share
    assert "Install-ExplorerShortcuts" in windows_share
    assert "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Run" in windows_share
    assert '& $launchCtl start "ext4-mount"' in windows_share
    assert "SECURITY ERROR: the Linux volume accepted a write despite --ro" in windows_share
    assert "Set-Service -Name ExtFsWatcher -StartupType Disabled" in windows_share


def test_installed_keyboard_layout_is_applied_once_after_cinnamon_starts() -> None:
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
    assert 'marker_path="$marker_directory/keyboard-initialized"' in first_session


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


def test_windows_installation_can_be_cancelled_with_verified_rollback() -> None:
    xaml = read("Pages/ApplyChanges.xaml")
    cancellation = read("Pages/ApplyChanges.Cancellation.cs")
    apply_changes = read_apply_changes()

    assert 'x:Name="CancelInstallationButton"' in xaml
    assert 'Click="CancelInstallationButton_Click"' in xaml
    assert "_installationCancellation.Cancel()" in cancellation
    assert 'Arguments = $"/PID {processId} /T /F"' in cancellation
    assert "FailBiosPreparationAndRollbackAsync" in cancellation
    assert '"ApplyChangesCancelledRestored"' in cancellation
    assert '"Installation cancelled. Windows has been restored."' in cancellation
    assert "QuoteArgument(scriptPath)} -Revert" in cancellation
    assert "observeCancellation: false" in cancellation
    assert "catch (OperationCanceledException)" in apply_changes


def test_uefi_cancellation_does_not_claim_bitlocker_was_restored_when_it_changed() -> None:
    cancellation = read("Pages/ApplyChanges.Cancellation.cs")
    system = read("Pages/ApplyChanges.System.cs")
    storage = read("Installation/StoragePreflightInfo.cs")

    for field in (
        "BitLockerConversionStatus",
        "BitLockerEncryptionPercentage",
        "BitLockerProtectionStatus",
    ):
        assert field in storage
        assert field in system
        assert field in cancellation
    assert "BitLockerMatchesPreflightStateAfterCancellationAsync" in cancellation
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
    assert "forceScrollToEnd || IsAutoScrollEnabled(output)" in append
    assert "SetAutoScrollEnabled(output, IsAtBottom(output))" in append
    assert "output.ScrollToEnd()" in append
    assert "output.ScrollToVerticalOffset(previousOffset)" in append


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
    assert bios.count("bios_partition_table_or_die >/dev/null") == 2
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

    assert 'Path.Combine(WindowsSystemDrive, "LibertixInstallLogs")' in cancellation
    assert "AppendPersistentLog(line);" in apply_changes


def test_filepool_defaults_to_production_and_supports_an_explicit_override() -> None:
    filepool = read("Helpers/FilepoolConfig.cs")
    startup = read("Helpers/StartupOptions.cs")
    app = read("App.xaml.cs")
    launch = read("auto_tests/app/scripts/launch_libertix_elevated.ps1")

    assert 'ProductionBaseUrl = "https://ekimia.fr/libertix"' in filepool
    assert 'FilepoolOption = "--filepool-base-url"' in startup
    assert 'DevelopmentSshStaticIpOption = "--dev-ssh-static-ip"' in startup
    assert 'DevelopmentSshPrefixLengthOption = "--dev-ssh-prefix-length"' in startup
    assert 'DevelopmentSshGatewayOption = "--dev-ssh-gateway"' in startup
    assert 'DevelopmentSshDnsOption = "--dev-ssh-dns"' in startup
    assert "FilepoolConfig.TryUseOverride(options.FilepoolBaseUrlOverride" in app
    assert '--filepool-base-url "{1}"' in launch
    assert '--dev-ssh-static-ip "{0}"' in launch
    assert '--dev-ssh-prefix-length "{0}"' in launch
    assert '--dev-ssh-gateway "{0}"' in launch
    assert '--dev-ssh-dns "{0}"' in launch


def test_development_ssh_is_installed_only_from_the_explicit_plan_flag() -> None:
    target = read("assets/live/configure-development-access.sh")
    first_boot = read("assets/live/libertix-development-ssh-first-boot.sh")
    unit = read("assets/live/libertix-development-ssh.service")
    automation = read("auto_tests/app/services/automation.py")
    validation = read("auto_tests/app/services/validation.py")

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
    assert "PasswordAuthentication yes" in first_boot
    assert "PermitRootLogin no" in first_boot
    assert "AllowUsers $username" in first_boot
    assert first_boot.index("install -d -m 0755 /run/sshd") < first_boot.index("/usr/sbin/sshd -t")
    assert "After=network-online.target" in unit
    assert '"development_static_ipv4": vm.host' in automation
    assert '"development_static_ipv4": vm.host' in validation
    assert '"development_dns_servers": list(self.settings.development_dns_servers)' in automation
    assert '"development_dns_servers": list(self.settings.development_dns_servers)' in validation


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

    assert "if (-not $Revert)" in validation
    assert "FilepoolBaseUrl is required" in validation
    assert "if (-not $Revert)" in downloads
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
        assert "[IO.File]::Replace($temporaryPath, $fullPath, $backupPath)" in atomic_writer
        assert "[IO.File]::Replace($temporaryPath, $fullPath, $null)" not in atomic_writer
        assert "[IO.File]::Delete($backupPath)" in atomic_writer


def test_uefi_installer_partition_paths_use_available_drive_letters() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    create_or_reuse = script.split("function New-OrReuseInstallerPartition", 1)[1].split(
        "function Get-ReusablePreparedInstallerPartition", 1
    )[0]
    prepared_reuse = script.split("function Get-ReusablePreparedInstallerPartition", 1)[1].split(
        "function Install-LibertixIsoToPartition", 1
    )[0]

    assert "$existingDriveLetter = Get-FreeDriveLetter" in create_or_reuse
    assert "-NewDriveLetter $existingDriveLetter" in create_or_reuse
    assert "-AssignDriveLetter" in create_or_reuse
    assert "$createdDriveLetter = [string]$newPartition.DriveLetter" in create_or_reuse
    assert "-DriveLetter $createdDriveLetter" in create_or_reuse
    assert 'Test-Path "${createdDriveLetter}:\\"' in create_or_reuse
    assert "Get-LibertixInstallerPartition -DriveLetter $createdDriveLetter" in create_or_reuse
    assert 'Drive = "${createdDriveLetter}:"' in create_or_reuse
    assert "-DriveLetter $InstallerLetter" not in create_or_reuse

    assert "$preparedDriveLetter = Get-FreeDriveLetter" in prepared_reuse
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
    assert "$requiredFreeBytes = $shrinkBytes + $minimumFreeBytes" in create_or_reuse
    assert "$freeSpaceAccountingToleranceBytes = 16MB" in create_or_reuse
    assert "Get-Volume -DriveLetter $SystemDriveLetter" in create_or_reuse
    assert "$shrinkGeometry = Get-LibertixAlignedShrinkGeometry" in create_or_reuse
    assert "$shrinkBytes = [int64]$shrinkGeometry.ShrinkBytes" in create_or_reuse
    assert "-Size $stagingBytes" in create_or_reuse


def test_bios_large_linux_partition_uses_fat32_staging_and_full_reservation() -> None:
    apply_changes = read("Pages/ApplyChanges.Bios.cs")
    partitioning = apply_changes.split("private async Task ExecutePartitioningAsync", 1)[1].split(
        "private async Task FailBiosPreparationAndRollbackAsync", 1
    )[0]

    assert "InstallationSizePolicy.FromRequestedGigabytes" in apply_changes
    assert "installationSizes.StagingSizeMiB" in partitioning
    assert "ShrinkWindowsPartitionAsync(requestedLinuxMB)" in partitioning
    assert "CreateFat32PartitionSimpleAsync(biosStagingMB)" in partitioning
    assert "the live will expand it" in partitioning


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
    assert "$containedPartitions.Count -ne 0" in helper
    assert "Remove-Partition -InputObject $container" in helper
    assert "The empty transaction MBR extended container still exists after removal" in helper
    recovery_offset_read = (
        'Read-EnvValue `\n        -Path $Pending `\n        -Name "RECOVERY_PARTITION_OFFSET_BYTES"'
    )
    assert recovery_offset_read in recovery

    remove_transaction = rollback.index(
        "Remove-Partition -DiskNumber $diskNumber -PartitionNumber $number"
    )
    remove_container = rollback.index("Remove-EmptyTransactionExtendedContainer")
    wait_for_capacity = rollback.index("Wait-SystemDriveResizeCapacity")
    resize_windows = rollback.index("Resize-Partition -DriveLetter $SystemDriveLetter")
    assert remove_transaction < remove_container < wait_for_capacity < resize_windows


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

    assert "$shrinkGeometry = Get-LibertixAlignedShrinkGeometry" in create_or_reuse
    assert "$shrinkBytes = [int64]$shrinkGeometry.ShrinkBytes" in create_or_reuse
    hibernation_position = create_or_reuse.index("Set-HibernateEnabled -Enabled $false")
    free_space_position = create_or_reuse.index(
        "$systemVolume = Get-Volume -DriveLetter $SystemDriveLetter"
    )
    assert hibernation_position < free_space_position
    assert "-Size ($systemPartition.Size - $shrinkBytes)" in create_or_reuse
    assert "Windows partition geometry does not match the aligned shrink target" in create_or_reuse
    assert "-Size $stagingBytes" in create_or_reuse
    assert "-Offset $installerOffsetBytes" in create_or_reuse
    assert "-Alignment ([int64]$shrinkGeometry.AlignmentBytes)" in create_or_reuse


def test_bios_storage_uses_the_same_alignment_geometry_as_uefi() -> None:
    script = read("Scripts/libertix-bios-storage.ps1")

    assert '"modules\\Libertix.StorageGeometry.psm1"' in script
    assert "Get-LibertixPartitionEndAlignmentPadding" in script
    assert "$maximumAllocationBytes" in script
    assert "[int64]$maximumAllocationBytes" in script
    assert "[Math]::Max" not in script
    assert "$allocationWithMbrMetadata = $SizeBytes + $partitionAlignmentBytes" in script
    assert "$shrinkGeometry = Get-LibertixAlignedShrinkGeometry" in script
    assert "-Offset $containerOffsetBytes" in script
    assert "-Alignment $partitionAlignmentBytes" in script


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
    assert "Start-RobustDownload -Url $downloadUrl" in download


def test_bios_iso_output_name_matches_the_filepool_contract() -> None:
    defaults = read("iso/config/defaults.env")
    docker_builder = read("docker/iso-builder/build-isos.sh")
    workflow = read(".github/workflows/ci.yml")
    distros = read("auto_tests/app/filepool/distros.json")

    expected_name = "libertix-installer-bios.iso"
    assert f'OUTPUT_ISO="{expected_name}"' in defaults
    assert f"/workspace/{expected_name}" in docker_builder
    assert expected_name in workflow
    assert f'"isoUrl": "{expected_name}"' in distros
    assert "libertix-installer.iso" not in defaults
    assert "/workspace/libertix-installer.iso" not in docker_builder


def test_iso_build_defaults_do_not_embed_account_or_locale_fallbacks() -> None:
    for relative_path in ("iso/config/defaults.env", "iso-uefi/config/defaults.env"):
        defaults = read(relative_path)
        assert "USERNAME=" not in defaults
        assert "PASSWORD_HASH=" not in defaults
        assert "LANGUAGE_CODE=" not in defaults
        assert "KEYBOARD_LAYOUT=" not in defaults


def test_wpf_and_automation_require_the_same_minimum_password_length() -> None:
    account_page = (ROOT / "Pages" / "AccountCreation.xaml.cs").read_text(encoding="utf-8-sig")
    api_models = (ROOT / "auto_tests" / "app" / "models.py").read_text(encoding="utf-8")

    assert "PasswordBox.Password.Length < 8" in account_page
    assert "linux_password: str = Field(min_length=8" in api_models


def test_uefi_bits_fallback_times_out_and_cleans_an_incomplete_job() -> None:
    script = read("Scripts/uefi/Libertix.Uefi.Downloads.ps1")
    bits = script.split("function Start-BitsDownload", 1)[1].split("function Get-Aria2Exe", 1)[0]
    robust = script.split("function Start-RobustDownload", 1)[1].split(
        "function Set-MintIsoOnWindows", 1
    )[0]

    assert "NoProgressTimeoutSeconds = 120" in bits
    assert '"Connecting", "Transferring", "TransientError"' in bits
    assert "$idleSeconds -ge $NoProgressTimeoutSeconds" in bits
    assert "BITS transfer made no progress" in bits
    assert "if (-not $completed)" in bits
    assert "Remove-BitsTransfer -BitsJob $remainingJob" in bits
    assert "BITS completed but the downloaded file is missing" in bits
    assert "Invoke-WebRequest" in robust
    assert "-TimeoutSec 120" in robust


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
    build = read("iso/build.sh")

    assert "journalctl -b --no-pager" in helper
    assert 'dmesg > "$LOG_DIR/dmesg.log"' in helper
    assert "cp -f /var/log/Xorg.*.log" in helper
    assert 'umount "$target"' in helper
    assert 'mount -t ntfs-3g -o rw "$win" "$target"' in helper
    assert 'cp -a "$LOG_DIR/." "$log_dir/"' in helper
    assert "sha256sum > SHA256SUMS" in helper
    assert "trap cleanup_mount EXIT" in helper
    assert 'mount -t ntfs-3g -o ro "$win" "$target"' in helper

    runner = read("assets/live/libertix-runner-main.sh")
    assert "/usr/local/sbin/libertix-copy-logs" in runner
    assert "libertix-copy-logs.sh" in build
    assert 'LOG_COPY_STATUS="success"' in runner


def test_grub_submenu_entries_always_have_a_transparent_icon_class() -> None:
    renderer = read("grub/render-libertix-menu.py")
    assert "add_invisible_icon_class" in renderer
    assert "--class find.none" in renderer
    assert (ROOT / "assets/grub-theme/icons/find.none.png").is_file()


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
    assert "NormalizeUtf8Line" in runner
    assert "Encoding.GetEncoding(1252).GetBytes(line)" in runner


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

    assert "_initialFreeSpace =" in page
    assert "systemDrive.AvailableFreeSpace / 1024.0 / 1024.0 / 1024.0" in page
    assert "_initialFreeSpace = Math.Round" not in page
    assert "_installationState.Compatibility?.ShrinkAvailableBytes" in page
    available_linux_size = (
        "Math.Min(\n"
        "            _initialFreeSpace - MinimumWindowsFree,\n"
        "            _shrinkAvailableSpace)"
    )
    assert available_linux_size in page


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
    assert 'Write-Result "NVRAM_PROBE_SKIPPED"' in script


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
