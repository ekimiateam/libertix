"""Synthetic complete worker results for campaign orchestration tests, not VM validation."""

from app.models import AutomationRequest, StepResult

# Keep the fixture independent of the production acceptance list.
LINUX_CHECKS = (
    "identity",
    "os_release",
    "kernel",
    "hostname",
    "locale",
    "keyboard",
    "timezone",
    "firmware",
    "root_filesystem",
    "root_uuid",
    "fstab",
    "user_home",
    "sudo_group",
    "ssh_service",
    "ssh_security",
    "development_profile",
    "static_ipv4",
    "gateway",
    "dns",
    "grub",
    "grub_regeneration",
    "boot_mode_files",
    "boot_artifacts",
    "running_kernel_artifacts",
    "initramfs_integrity",
    "windows_mount",
    "sharing_policy",
    "windows_profile_shortcuts",
    "desktop_stack",
    "first_boot_verification",
    "first_boot_cleanup",
    "system_resources",
    "failed_units",
    "time_sync",
    "package_dependencies",
    "package_database",
    "name_resolution",
)
WINDOWS_CHECKS = (
    "finalization",
    "identity",
    "firmware",
    "system_volume",
    "system_resources",
    "partition_layout",
    "partition_geometry",
    "boot_partition",
    "boot_configuration",
    "recovery",
    "bitlocker",
    "temporary_artifacts",
    "network",
    "locale",
    "ssh_service",
    "update_policy",
    "core_services",
    "hibernation",
    "ext4_driver",
    "ext4_readonly_mount",
    "linux_home",
    "linux_home_hash",
    "ext4_write_denied",
    "explorer_shortcut",
    "explorer_integration",
    "sharing_tasks",
    "cross_os_hash",
    "dism_check_health",
    "sfc_verify_only",
    "chkdsk_scan",
)


def successful_campaign_steps(request: AutomationRequest) -> list[StepResult]:
    vm = request.vms[0]
    steps = []

    def phase(name, **context):
        steps.append(
            StepResult(
                step=name, status="ok", message="Synthetic evidence", context={"vm": vm, **context}
            )
        )

    def check(name, platform):
        phase(f"automation.test.{platform}", test=name, exit_code=0)

    phase("automation.prepare_vm")
    phase("automation.deploy")
    if request.expected_compatibility_refusal:
        phase("automation.compatibility_refusal", error_code=request.expected_compatibility_refusal)
        phase("automation.compatibility_unchanged")
    else:
        phase("automation.reboot_requested")
        phase("automation.installed_boot_menu_seen")
        if request.first_boot == "windows":
            check("windows.waiting_for_linux", "windows")
            check("windows.linux_reboot", "windows")
        for name in (
            "ssh",
            "first_boot_verification_ready",
            "post_install_result_process",
            *LINUX_CHECKS,
        ):
            check(f"linux.{name}", "linux")
        if request.storage_fixture.redirect_documents:
            phase("automation.test.redirected_documents")
        if request.migrate_windows_preferences:
            phase("automation.test.preference_migration")
        check("sharing.linux_to_windows_100m", "linux")
        check("sharing.linux_home_marker", "linux")
        check("linux.windows_reboot", "linux")
        for name in ("ssh", *WINDOWS_CHECKS):
            check(f"windows.{name}", "windows")
        check("sharing.windows_artifact_cleanup", "artifact_cleanup")
        check("windows.linux_reboot", "windows")
        check("linux.return_after_windows", "linux")
        check("sharing.linux_artifact_cleanup", "artifact_cleanup")
        check("linux.final_windows_reboot", "linux")
        check("windows.final_state", "windows")
        for name in ("verify", "completed", "unassisted_boot", "after_reboot"):
            phase(f"automation.installed_linux_uninstall.{name}")
    if request.snapshot_mode == "secondary-disk":
        phase("automation.storage_fixture.preserved")
        phase("automation.storage_fixture.documents_preserved")
    phase("automation.vm_finished", vm_status="ok")
    return steps
