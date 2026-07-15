from __future__ import annotations

import hashlib
import runpy
import subprocess
import xml.etree.ElementTree as ET
from collections.abc import Callable
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def read(relative: str) -> str:
    return (ROOT / relative).read_text(encoding="utf-8-sig")


def read_apply_changes() -> str:
    """Read the complete ApplyChanges partial class as one reviewable source."""

    return "\n".join(
        read(path)
        for path in (
            "Pages/ApplyChanges.xaml.cs",
            "Pages/ApplyChanges.Cancellation.cs",
            "Pages/ApplyChanges.Downloads.cs",
            "Pages/ApplyChanges.System.cs",
            "Pages/ApplyChanges.Types.cs",
        )
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


def test_low_memory_mode_reaches_bios_and_uefi_configuration() -> None:
    apply_changes = read_apply_changes()
    uefi = read("Scripts/libertix-uefi-install.ps1")
    for installer in (read("iso/live/install-mint.sh"), read("iso-uefi/live/install-mint.sh")):
        assert ". /usr/local/lib/libertix/libertix-install-platform-common.sh" in installer

    assert "ConfigureBiosLowMemoryBootAsync" in apply_changes
    assert "LowMemoryMode = lowMemoryMode" in apply_changes
    assert "$LowMemoryMode" in uefi
    assert "findiso=/libertix-live.iso" in uefi


def test_runner_stage_functions_return_stable_labels_and_percentages(
    run_shell_function: Callable[..., subprocess.CompletedProcess[str]],
) -> None:
    library = ROOT / "assets/live/libertix-runner-stage-common.sh"

    label = run_shell_function(library, "libertix_stage_label", "120-unsquashfs")
    percent = run_shell_function(library, "libertix_stage_percent", "120-unsquashfs")
    unknown_label = run_shell_function(library, "libertix_stage_label", "custom-stage")

    assert label.returncode == 0
    assert label.stdout.strip() == "Extraction de Mint"
    assert percent.returncode == 0
    assert percent.stdout.strip() == "64"
    assert unknown_label.stdout.strip() == "custom-stage"


def test_uefi_copy_preserves_live_boot_case_sensitive_names() -> None:
    uefi = read("Scripts/libertix-uefi-install.ps1")

    assert '$actualLiveDirectories[0].Name -cne "live"' in uefi
    assert "Live directory name case normalization failed" in uefi
    assert '"live\\filesystem.squashfs"' in uefi
    assert "$actual[0].Name -cne $expectedName" in uefi
    assert "Live file name case normalization failed" in uefi


def test_uefi_firmware_fallback_reuses_verified_prepared_installer() -> None:
    fallback = read("Pages/UefiBootFallback.xaml.cs")
    uefi = read("Scripts/libertix-uefi-install.ps1")
    transaction_module = read("Scripts/modules/Libertix.Transaction.psm1")

    assert "-BootStrategy FirmwareBootOrder -ReusePreparedInstaller" in fallback
    fallback_command = fallback.split("-BootStrategy FirmwareBootOrder", 1)[0].rsplit(
        "powershell,", 1
    )[1]
    assert "-Force" not in fallback_command

    assert "function Save-PreparedInstallerManifest" in uefi
    assert "function Assert-PreparedInstallerManifest" in uefi
    assert '"live\\filesystem.squashfs"' in transaction_module
    assert '"live\\initrd.img"' in transaction_module
    assert '"live\\vmlinuz"' in transaction_module
    assert '"EFI\\BOOT\\BOOTX64.EFI"' in transaction_module
    assert "Prepared installer SHA256 manifest verified" in uefi
    assert "Temporary ESP loader SHA256 verified" in uefi

    reuse_path = uefi.split("try {\n    if ($ReusePreparedInstaller)", 1)[1].split(
        "    Test-LibertixLiveConfig\n    Test-LibertixSecureBootCompatibility", 1
    )[0]
    assert "Get-ReusablePreparedInstallerPartition" in reuse_path
    assert "Assert-PreparedInstallerManifest" in reuse_path
    assert "Set-LibertixUefiBootEntry" in reuse_path
    assert "-ReusePreparedInstaller" in reuse_path
    assert "Install-LibertixIsoToPartition" not in reuse_path
    assert "Start-RobustDownload" not in reuse_path
    assert "FALLBACK_REUSED_PREPARED_INSTALLER=true" in reuse_path

    boot_setup = uefi.split("function Set-LibertixUefiBootEntry", 1)[1]
    assert "Remove-LibertixTemporaryFirmwareEntries" in boot_setup
    assert 'Remove-FirmwareVariable -Name "BootNext"' in boot_setup
    assert "Firmware BootOrder fallback verified" in boot_setup


def test_bios_copy_preserves_live_boot_case_sensitive_names() -> None:
    apply_changes = read_apply_changes()

    assert "NormalizeLiveBootNames(destDir)" in apply_changes
    assert "StringComparison.OrdinalIgnoreCase" in apply_changes
    assert '"filesystem.squashfs", "initrd.img", "vmlinuz"' in apply_changes
    assert "Live directory name case normalization failed" in apply_changes


def test_live_manifest_survives_detached_toram_medium_and_fat_name_case() -> None:
    apply_changes = read_apply_changes()
    assert 'NormalizeRootFileNameCase(@"Z:\\", "config.txt")' in apply_changes

    for installer in (read("iso/live/install-mint.sh"), read("iso-uefi/live/install-mint.sh")):
        assert "find /run/live /lib/live /cdrom -maxdepth 6 -iname config.txt" in installer
        assert (
            'mounted_config=$(find "$config_mount" -maxdepth 1 -type f -iname config.txt'
            in installer
        )
        assert (
            "Prerequisite timeout: disk_ready=$disk_ready config_ready=$config_ready" in installer
        )


def test_sharing_options_reach_both_live_installers() -> None:
    apply_changes = read_apply_changes()
    for installer in (read("iso/live/install-mint.sh"), read("iso-uefi/live/install-mint.sh")):
        assert "SHARE_WINDOWS_FILES_IN_LINUX" in installer
        assert "SHARE_LINUX_FILES_IN_WINDOWS" in installer
        assert "WINDOWS_PROFILES_JSON_BASE64" in installer

    assert "ShareWindowsFilesInLinux" in apply_changes
    assert "ShareLinuxFilesInWindows" in apply_changes
    assert "WindowsProfilesJsonBase64" in apply_changes
    assert '"Default"' in apply_changes
    assert '"Default User"' in apply_changes
    assert "excludedProfiles.Contains(profileName)" in apply_changes


def test_mint_shortcuts_and_windows_mount_are_read_only_by_contract() -> None:
    for target in (
        read("iso/target/configure-target.sh"),
        read("iso-uefi/target/configure-target.sh"),
    ):
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


def test_ext4_setup_payload_matches_pinned_release_hash() -> None:
    setup = ROOT / "auto_tests/app/filepool/ext4-win-driver.exe"
    assert setup.is_file()
    assert hashlib.sha256(setup.read_bytes()).hexdigest() == (
        "967a001e6bd80de0af44b085c73097a96ea4ab0f5dd4d766cca4959231891031"
    )


def test_live_gui_uses_the_proven_direct_xorg_path() -> None:
    rootfs = read("iso-uefi/live/setup-live-rootfs.sh")
    for variant in ("iso", "iso-uefi"):
        runner = read(f"{variant}/live/libertix-runner.sh")

        assert "xinit" not in runner
        assert " xinit " not in rootfs
        assert '"$x_server" "$GUI_DISPLAY" "vt$GUI_VT"' in runner
        assert "-ac -noreset" in runner
        assert "XAUTHORITY=/dev/null /usr/local/sbin/libertix-gui" in runner


def test_live_gui_sets_a_visible_pointer_on_both_boot_paths() -> None:
    gui = read("iso-uefi/live/libertix-gui.py")

    assert 'cursor="left_ptr"' in gui
    for variant in ("iso", "iso-uefi"):
        runner = read(f"{variant}/live/libertix-runner.sh")
        assert "xsetroot -cursor_name left_ptr" in runner


def test_live_reboot_is_only_offered_after_verified_rollback() -> None:
    gui = read("iso-uefi/live/libertix-gui.py")
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
    assert "QuoteArgument(scriptPath)} -Revert" in cancellation
    assert "observeCancellation: false" in cancellation
    assert "catch (OperationCanceledException)" in apply_changes


def test_uefi_cancellation_does_not_claim_bitlocker_was_restored_when_it_changed() -> None:
    cancellation = read("Pages/ApplyChanges.Cancellation.cs")
    system = read("Pages/ApplyChanges.System.cs")
    types = read("Pages/ApplyChanges.Types.cs")

    for field in (
        "BitLockerConversionStatus",
        "BitLockerEncryptionPercentage",
        "BitLockerProtectionStatus",
    ):
        assert field in types
        assert field in system
        assert field in cancellation
    assert "BitLockerMatchesPreflightStateAfterCancellationAsync" in cancellation
    assert "BitLocker did not " in cancellation
    assert "return to its initial state." in cancellation
    assert "BitLocker doit être réactivé dans Windows" in cancellation


def test_windows_close_behavior_uses_tray_while_installation_runs() -> None:
    main = read("MainWindow.xaml.cs")
    state = read("Models/InstallationState.cs")
    tray = read("Helpers/TrayIconController.cs")

    assert "if (_installationState.IsInstallationRunning)" in main
    assert "HideInTrayDuringInstallation();" in main
    assert "MessageBoxButton.YesNo" in main
    assert "InstallationRunningChanged" in main
    assert "RestoreFromTray();" in main
    assert "ShowBalloonTip" in tray
    assert "Resources/Images/Icon.ico" in tray
    assert "SystemIcons.Application.Clone()" in tray
    assert "SetInstallationRunning" in state


def test_installation_log_controls_preserve_manual_scroll_and_button_layout() -> None:
    xaml = read("Pages/ApplyChanges.xaml")
    apply_changes = read("Pages/ApplyChanges.xaml.cs")

    expand = xaml.split('x:Name="ExpandLogsButton"', 1)[1].split("/>", 1)[0]
    cancel = xaml.split('x:Name="CancelInstallationButton"', 1)[1].split("/>", 1)[0]
    append = apply_changes.split("private static void AppendLogLine", 1)[1].split(
        "private void ExpandLogsButton_Click", 1
    )[0]

    assert 'Height="50"' in expand
    assert 'HorizontalAlignment="Right"' in cancel
    assert "bool wasAtBottom" in append
    assert "double previousOffset" in append
    assert "DispatcherPriority.Background" in append
    assert "output.ScrollToEnd()" in append
    assert "output.ScrollToVerticalOffset(previousOffset)" in append


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

    assert 'string logRoot = @"C:\\LibertixInstallLogs"' in cancellation
    assert "AppendPersistentLog(line);" in apply_changes


def test_uefi_early_revert_does_not_require_absent_transaction_state() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
    revert = script.split("function Invoke-Revert", 1)[1].split(
        "function New-OrReuseInstallerPartition", 1
    )[0]

    assert "Remove-LibertixInstallerPartitionIfPresent" in revert
    assert "No transaction state found; C: was not resized by this run." in revert
    assert "Cannot restore C: without the saved transaction state." not in revert


def test_uefi_revert_does_not_require_download_configuration() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
    validation = script.split("# Networking defaults", 1)[0].rsplit(
        "# A rollback only consumes", 1
    )[1]
    downloads = script.split("# Downloads", 1)[1].split("# Defaults", 1)[0]

    assert "if (-not $Revert)" in validation
    assert "FilepoolBaseUrl is required" in validation
    assert "if (-not $Revert)" in downloads
    assert "New-LibertixDownloadUrls" in downloads


def test_uefi_installer_partition_paths_use_available_drive_letters() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
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
    assert "Ensure-VolumeNotEncrypted -DriveLetter $createdDriveLetter" in create_or_reuse
    assert 'Drive = "${createdDriveLetter}:"' in create_or_reuse
    assert "-DriveLetter $InstallerLetter" not in create_or_reuse

    assert "$preparedDriveLetter = Get-FreeDriveLetter" in prepared_reuse
    assert "-NewDriveLetter $preparedDriveLetter" in prepared_reuse
    assert "-NewDriveLetter $InstallerLetter" not in prepared_reuse


def test_uefi_dismount_closes_only_explorer_windows_on_temporary_drive() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
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
    assert "Close-ExplorerWindowsForDrive -Letter $Letter" in dismount


def test_uefi_large_linux_partition_uses_fat32_staging_and_full_reservation() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
    create_or_reuse = script.split("function New-OrReuseInstallerPartition", 1)[1].split(
        "function Get-ReusablePreparedInstallerPartition", 1
    )[0]

    assert "$requestedBytes = $requestedSizeMB * 1MB" in create_or_reuse
    assert "$stagingSizeGB = if ($SizeGB -gt 31) { 8 } else { $SizeGB }" in create_or_reuse
    assert "$need = $requestedBytes + $minFree" in create_or_reuse
    assert "$shrinkBytes = $requestedBytes" in create_or_reuse
    assert "-Size $stagingBytes" in create_or_reuse


def test_uefi_raw_staging_partition_is_owned_before_fat32_format() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
    create_or_reuse = script.split("function New-OrReuseInstallerPartition", 1)[1].split(
        "function Get-ReusablePreparedInstallerPartition", 1
    )[0]

    create_position = create_or_reuse.index("$newPartition = New-Partition")
    save_position = create_or_reuse.index(
        "Save-TransactionPartitionState -Partition $newPartition", create_position
    )
    format_position = create_or_reuse.index("\n    Format-Volume `", create_position)

    assert create_position < save_position < format_position


def test_uefi_low_memory_boot_files_are_writable_and_revert_removes_iso() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
    install = script.split("function Install-LibertixIsoToPartition", 1)[1].split(
        "function Set-LibertixUefiBootEntry", 1
    )[0]
    revert = script.split("function Invoke-Revert", 1)[1].split(
        "function New-OrReuseInstallerPartition", 1
    )[0]

    attributes_position = install.index("attrib -R -S -H $bootConfig.FullName")
    write_position = install.index(
        "Set-Content -LiteralPath $bootConfig.FullName", attributes_position
    )

    assert attributes_position < write_position
    assert "$LowMemoryMode -and (Test-Path -LiteralPath $LowMemoryIsoPath" in revert
    assert "Remove-Item -LiteralPath $LowMemoryIsoPath -Force" in revert


def test_uefi_live_expands_fat32_staging_before_ext4_format() -> None:
    installer = read("iso-uefi/live/install-mint.sh")
    reuse = installer.split('if [ -n "$LIVE_PART" ]', 1)[1].split(
        'elif [ "$PART_TABLE" = "msdos" ]', 1
    )[0]

    assert "desired_partition_bytes=$((LINUX_SIZE_GB * 1024 * 1024 * 1024))" in reuse
    assert (
        "recovery_start_sector=$((RECOVERY_PARTITION_OFFSET_BYTES / logical_sector_bytes))" in reuse
    )
    assert 'run_logged parted -s "$DISK" unit s resizepart' in reuse
    assert 'expanded_partition_bytes=$(blockdev --getsize64 "$NEW_PART"' in reuse
    assert '"$expanded_partition_bytes" -eq "$desired_partition_bytes"' in reuse
    assert reuse.index("resizepart") < installer.index('run_logged wipefs -a "$NEW_PART"')


def test_uefi_iso_download_uses_the_canonical_url_without_cache_busting() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
    download = script.split("function Install-LibertixIsoToPartition", 1)[1].split(
        "function Set-LibertixUefiBootEntry", 1
    )[0]

    assert "$downloadUrl = $InstallerIsoUrl" in download
    assert "cacheBust" not in download
    assert "Start-RobustDownload -Url $downloadUrl" in download


def test_uefi_bits_fallback_times_out_and_cleans_an_incomplete_job() -> None:
    script = read("Scripts/libertix-uefi-install.ps1")
    bits = script.split("function Start-BitsDownload", 1)[1].split("function Get-Aria2Exe", 1)[0]
    robust = script.split("function Start-RobustDownload", 1)[1].split(
        "function Ensure-MintIsoOnWindows", 1
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
    rootfs = read("iso-uefi/live/setup-live-rootfs.sh")
    for variant in ("iso", "iso-uefi"):
        runner = read(f"{variant}/live/libertix-runner.sh")

        assert "write_tty1_screen" in runner
        assert "cmp -s" in runner
        assert "perl -pe 's/\\n/\\033[K\\r\\n/g'" in runner
        assert "printf '\\033c'" not in runner
        assert "dmesg -n 1" in runner
        assert "prepare_terminal_ui" in runner
        assert "getty@tty1.service" in rootfs
        assert "ln -sf /dev/null" in rootfs


def test_live_rootfs_masks_unused_serial_login_prompt() -> None:
    rootfs = read("iso-uefi/live/setup-live-rootfs.sh")

    assert "ln -sf /dev/null /etc/systemd/system/serial-getty@ttyS0.service" in rootfs


def test_developer_terminal_is_verbose_and_initialized_only_once() -> None:
    for variant in ("iso", "iso-uefi"):
        runner = read(f"{variant}/live/libertix-runner.sh")

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
    assert 'mount -o remount,rw "$target"' in helper
    assert 'cp -a "$LOG_DIR/." "$log_dir/"' in helper
    assert "sha256sum > SHA256SUMS" in helper
    assert "trap cleanup_mount EXIT" in helper
    assert 'mount -o remount,ro "$target"' in helper

    for variant in ("iso", "iso-uefi"):
        runner = read(f"{variant}/live/libertix-runner.sh")
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
