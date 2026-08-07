from __future__ import annotations

import importlib.util
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from types import ModuleType

import pytest
from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[2]
GIB = 1024**3


def test_legacy_project_compiles_every_application_source_file() -> None:
    project = ET.parse(ROOT / "Libertix.csproj")
    namespace = {"msbuild": "http://schemas.microsoft.com/developer/msbuild/2003"}
    included = {
        element.attrib["Include"].replace("\\", "/")
        for element in project.findall(".//msbuild:Compile", namespace)
        if "Include" in element.attrib
    }
    ignored_roots = {"auto_tests", "Libertix.Tests", "bin", "obj", ".work"}
    application_sources = {
        path.relative_to(ROOT).as_posix()
        for path in ROOT.rglob("*.cs")
        if path.relative_to(ROOT).parts[0] not in ignored_roots
    }

    assert application_sources == included


def load_live_module(relative_path: str, module_name: str) -> ModuleType:
    """Load a live helper exactly as the ISO executes it, without packaging it."""

    path = ROOT / relative_path
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load live helper: {path}")
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(path.parent))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.remove(str(path.parent))
    return module


@pytest.fixture(scope="module")
def plan_module() -> ModuleType:
    return load_live_module(
        "assets/live/libertix-installation-plan.py",
        "libertix_installation_plan_contract",
    )


@pytest.fixture(scope="module")
def state_module() -> ModuleType:
    return load_live_module(
        "assets/live/libertix-installation-state.py",
        "libertix_installation_state_contract",
    )


@pytest.fixture(scope="module")
def bcd_cleanup_module() -> ModuleType:
    return load_live_module(
        "assets/live/cleanup-bcd-main.py",
        "libertix_bcd_cleanup_contract",
    )


def make_plan(firmware: str, final_size_gib: int) -> dict[str, object]:
    """Build the smallest complete plan shared by BIOS and UEFI."""

    staging_size_gib = 8 if final_size_gib > 31 else final_size_gib
    is_bios = firmware == "bios"
    return {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "createdAtUtc": "2026-07-15T12:00:00Z",
        "firmware": firmware,
        "distribution": {
            "name": "Linux Mint",
            "installerIsoFileName": "mint.iso",
            "installerIsoUrl": "https://example.test/mint.iso",
            "installerIsoWindowsPath": "C:\\mint.iso",
            "installerIsoSha256": "b" * 64,
            "liveIsoUrl": "https://example.test/libertix.iso",
            "liveIsoSha256": "c" * 64,
        },
        "locale": {
            "languageCode": "fr",
            "systemLanguage": "fr_FR.UTF-8",
            "keyboardLayout": "fr",
            "keyboardVariant": "",
            "keyboardModel": "pc105",
            "timezone": "Europe/Paris",
        },
        "account": {
            "username": "oem",
            "passwordHashWindowsPath": ("C:\\ProgramData\\Libertix\\Recovery\\account-secret.env"),
            "computerName": "libertix-test",
        },
        "disk": {
            "number": 0,
            "uniqueId": "disk-0",
            "sizeBytes": 256 * GIB,
            "logicalSectorSizeBytes": 512,
            "partitionStyle": "MBR" if is_bios else "GPT",
            "systemDrive": "C:",
            "windows": {"number": 2, "offsetBytes": GIB, "sizeBytes": 200 * GIB},
            "boot": {"number": 1, "offsetBytes": 1024 * 1024, "sizeBytes": 100 * 1024**2},
            "recovery": {
                "number": 3,
                "offsetBytes": 240 * GIB,
                "sizeBytes": GIB,
            },
            "installer": {
                "number": 4,
                "offsetBytes": (201 - final_size_gib) * GIB,
                "finalSizeBytes": final_size_gib * GIB,
                "stagingSizeBytes": staging_size_gib * GIB,
            },
        },
        "features": {
            "shareWindowsFilesInLinux": True,
            "shareLinuxFilesInWindows": True,
            "windowsProfilesJsonBase64": "W10=",
        },
        "runtime": {
            "lowMemoryMode": False,
            "bootStrategy": "bios-grub4dos" if is_bios else "uefi-boot-next",
            "recoveryRootWindows": "C:\\ProgramData\\Libertix\\Recovery",
            "recoveryRunId": "d" * 32,
        },
    }


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
@pytest.mark.parametrize(
    ("final_size_gib", "staging_size_gib"),
    [(20, 20), (31, 31), (32, 8), (40, 8)],
)
def test_bios_and_uefi_use_the_same_size_policy(
    plan_module: ModuleType,
    firmware: str,
    final_size_gib: int,
    staging_size_gib: int,
) -> None:
    plan = make_plan(firmware, final_size_gib)

    validated = plan_module.validate_plan(plan, require_installer=True)
    exported = plan_module.shell_values(validated)

    assert exported["LINUX_SIZE_GB"] == str(final_size_gib)
    assert exported["LANGUAGE_CODE"] == "fr"
    assert exported["KEYBOARD_VARIANT"] == ""
    assert exported["WINDOWS_PARTITION_SIZE_BYTES"] == str(200 * GIB)
    assert exported["INSTALLER_FINAL_SIZE_BYTES"] == str(final_size_gib * GIB)
    assert exported["INSTALLER_STAGING_SIZE_BYTES"] == str(staging_size_gib * GIB)


@pytest.mark.parametrize(
    ("field_path", "invalid_value"),
    [
        (("distribution", "installerIsoFileName"), "folder/mint.iso"),
        (("distribution", "installerIsoWindowsPath"), "C:mint.iso"),
        (("account", "passwordHashWindowsPath"), "..\\account-secret.env"),
        (("disk", "systemDrive"), "c:"),
        (("features", "windowsProfilesJsonBase64"), ""),
        (("runtime", "recoveryRunId"), ""),
        (("locale", "languageCode"), "de"),
        (("locale", "keyboardLayout"), "fr;touch /tmp/unsafe"),
        (("locale", "keyboardVariant"), "intl;touch /tmp/unsafe"),
    ],
)
def test_shared_plan_rejects_ambiguous_or_unsafe_values(
    plan_module: ModuleType,
    field_path: tuple[str, str],
    invalid_value: str,
) -> None:
    plan = make_plan("uefi", 40)
    section, field = field_path
    plan[section][field] = invalid_value  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


def test_legacy_plan_without_keyboard_variant_uses_empty_variant(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    del plan["locale"]["keyboardVariant"]  # type: ignore[index]

    validated = plan_module.validate_plan(plan, require_installer=True)

    assert plan_module.shell_values(validated)["KEYBOARD_VARIANT"] == ""


def test_development_ssh_network_is_validated_and_exported(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    plan["development"] = {
        "enableSsh": True,
        "staticIpv4Address": "198.51.100.20",
        "staticIpv4PrefixLength": 23,
        "staticIpv4Gateway": "198.51.100.1",
        "dnsServers": ["9.9.9.9", "1.1.1.1"],
    }

    validated = plan_module.validate_plan(plan, require_installer=True)
    exported = plan_module.shell_values(validated)

    assert exported["DEVELOPMENT_SSH_ENABLED"] == "true"
    assert exported["DEVELOPMENT_STATIC_IPV4_ADDRESS"] == "198.51.100.20"
    assert exported["DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH"] == "23"
    assert exported["DEVELOPMENT_STATIC_IPV4_GATEWAY"] == "198.51.100.1"
    assert exported["DEVELOPMENT_DNS_SERVERS"] == "9.9.9.9;1.1.1.1"
    validate_schema_document("installation-plan.schema.json", plan)


def test_plan_without_development_access_exports_disabled_defaults(
    plan_module: ModuleType,
) -> None:
    exported = plan_module.shell_values(make_plan("bios", 20))

    assert exported["DEVELOPMENT_SSH_ENABLED"] == "false"
    assert exported["DEVELOPMENT_STATIC_IPV4_ADDRESS"] == ""


def test_live_plan_runtime_rejects_properties_outside_the_shared_schema(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    plan["unexpectedRuntimeField"] = True

    with pytest.raises(plan_module.PlanValidationError, match="schema validation failed"):
        plan_module.validate_plan(plan, require_installer=True)


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("enableSsh", False),
        ("staticIpv4Address", "198.51.100.0"),
        ("staticIpv4PrefixLength", 31),
        ("staticIpv4Gateway", "203.0.113.1"),
        ("dnsServers", ["1.1.1.1", "1.1.1.1"]),
        ("staticIpv4Address", "127.0.0.2"),
        ("staticIpv4Address", "169.254.10.2"),
        ("staticIpv4Address", "224.0.0.2"),
        ("staticIpv4Gateway", "127.0.0.1"),
    ],
)
def test_development_ssh_network_rejects_noncanonical_values(
    plan_module: ModuleType,
    field: str,
    value: object,
) -> None:
    plan = make_plan("uefi", 40)
    development = {
        "enableSsh": True,
        "staticIpv4Address": "198.51.100.20",
        "staticIpv4PrefixLength": 23,
        "staticIpv4Gateway": "198.51.100.1",
        "dnsServers": ["9.9.9.9", "1.1.1.1"],
    }
    development[field] = value
    plan["development"] = development

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


@pytest.mark.parametrize(
    ("final_size_bytes", "staging_size_bytes"),
    [
        (19 * GIB, 19 * GIB),
        (20 * GIB + 1, 20 * GIB),
        (31 * GIB, 8 * GIB),
        (32 * GIB, 32 * GIB),
        (40 * GIB, 9 * GIB),
    ],
)
def test_plan_rejects_noncanonical_staging_sizes(
    plan_module: ModuleType,
    final_size_bytes: int,
    staging_size_bytes: int,
) -> None:
    plan = make_plan("bios", 20)
    installer = plan["disk"]["installer"]  # type: ignore[index]
    installer["finalSizeBytes"] = final_size_bytes
    installer["stagingSizeBytes"] = staging_size_bytes

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


def test_plan_accepts_aligned_four_kn_partition_geometry(plan_module: ModuleType) -> None:
    plan = make_plan("uefi", 40)
    plan["disk"]["logicalSectorSizeBytes"] = 4096  # type: ignore[index]

    plan_module.validate_plan(plan, require_installer=True)
    validate_schema_document("installation-plan.schema.json", plan)


@pytest.mark.parametrize("logical_sector_size", [256, 1024, 8192])
def test_plan_rejects_unsupported_logical_sector_sizes(
    plan_module: ModuleType,
    logical_sector_size: int,
) -> None:
    plan = make_plan("uefi", 40)
    plan["disk"]["logicalSectorSizeBytes"] = logical_sector_size  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


def test_plan_rejects_partition_offsets_between_four_kn_sectors(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 40)
    disk = plan["disk"]  # type: ignore[assignment]
    disk["logicalSectorSizeBytes"] = 4096
    disk["windows"]["offsetBytes"] += 512

    with pytest.raises(plan_module.PlanValidationError, match="must align"):
        plan_module.validate_plan(plan, require_installer=True)


def test_plan_accepts_cloned_windows_geometry_with_preserved_gap(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 24)
    disk = plan["disk"]  # type: ignore[assignment]
    disk["windows"]["sizeBytes"] += 256 * 1024
    disk["installer"]["offsetBytes"] = (
        disk["windows"]["offsetBytes"]
        + disk["windows"]["sizeBytes"]
        - 256 * 1024
        - disk["installer"]["finalSizeBytes"]
    )

    plan_module.validate_plan(plan, require_installer=True)


def test_plan_rejects_installer_offset_not_derived_from_original_windows_geometry(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 24)
    plan["disk"]["installer"]["offsetBytes"] += 1024 * 1024  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError, match="aligned Windows shrink geometry"):
        plan_module.validate_plan(plan, require_installer=True)


def test_bios_plan_accepts_primary_partition_after_reserved_mbr_metadata(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("bios", 24)
    plan["disk"]["installer"]["offsetBytes"] -= 1024 * 1024  # type: ignore[index]

    plan_module.validate_plan(plan, require_installer=True)


def test_uefi_plan_rejects_bios_primary_partition_offset(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 24)
    plan["disk"]["installer"]["offsetBytes"] -= 1024 * 1024  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError, match="aligned Windows shrink geometry"):
        plan_module.validate_plan(plan, require_installer=True)


def test_plan_rejects_recovery_before_original_windows_end(
    plan_module: ModuleType,
) -> None:
    plan = make_plan("uefi", 24)
    plan["disk"]["recovery"]["offsetBytes"] = 190 * GIB  # type: ignore[index]

    with pytest.raises(plan_module.PlanValidationError):
        plan_module.validate_plan(plan, require_installer=True)


def test_failure_and_rollback_preserve_the_completed_step_ledger(
    state_module: ModuleType,
) -> None:
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 0,
        "status": "pending",
        "phase": "windows",
        "activeStep": None,
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }

    for step in (
        "windows.preflight-verified",
        "windows.artifacts-verified",
        "windows.recovery-armed",
        "windows.system-volume-shrunk",
    ):
        state_module.start_step(state, step)
        state_module.complete_step(state, step)
    state_module.start_step(state, "windows.installer-partition-created")
    state_module.fail(state, "TEST_FAILURE", "windows", "Injected failure")
    state_module.begin_rollback(state)

    with pytest.raises(state_module.StateTransitionError):
        state_module.compensate(state, "windows.installer-partition-created")

    state_module.compensate(state, "windows.system-volume-shrunk")
    state_module.compensate(state, "windows.recovery-armed")
    state_module.complete_rollback(state)

    assert state["status"] == "rolled-back"
    assert state["phase"] == "complete"
    assert state["completedSteps"] == [
        "windows.preflight-verified",
        "windows.artifacts-verified",
        "windows.recovery-armed",
        "windows.system-volume-shrunk",
    ]
    assert state["compensatedSteps"] == [
        "windows.system-volume-shrunk",
        "windows.recovery-armed",
    ]


def test_live_state_rejects_out_of_order_and_incomplete_success(
    state_module: ModuleType,
) -> None:
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 0,
        "status": "pending",
        "phase": "windows",
        "activeStep": None,
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }

    with pytest.raises(state_module.StateTransitionError, match="out of order"):
        state_module.start_step(state, "windows.recovery-armed")

    state_module.start_step(state, "windows.preflight-verified")
    state_module.complete_step(state, "windows.preflight-verified")
    with pytest.raises(state_module.StateTransitionError, match="final target verification"):
        state_module.complete_installation(state)


def test_live_state_runtime_rejects_properties_outside_the_shared_schema(
    state_module: ModuleType,
) -> None:
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 0,
        "status": "pending",
        "phase": "windows",
        "activeStep": None,
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
        "unexpectedRuntimeField": True,
    }

    with pytest.raises(state_module.StateTransitionError, match="schema validation failed"):
        state_module.validate_state(state)


def test_contract_implementations_share_the_same_policy_constants() -> None:
    csharp = (ROOT / "Installation/InstallationSizePolicy.cs").read_text(encoding="utf-8-sig")
    powershell = (ROOT / "Scripts/modules/Libertix.InstallationPlan.psm1").read_text(
        encoding="utf-8-sig"
    )
    python = (ROOT / "assets/live/libertix-installation-plan.py").read_text(encoding="utf-8-sig")

    assert "MinimumFinalSizeGiB = 20" in csharp
    assert "MaximumDirectFat32SizeGiB = 31" in csharp
    assert "LargeInstallationStagingSizeGiB = 8" in csharp
    assert "$script:MinimumFinalSizeGiB = 20" in powershell
    assert "$script:MaximumDirectFat32SizeGiB = 31" in powershell
    assert "$script:LargeInstallationStagingSizeGiB = 8" in powershell
    assert "MINIMUM_FINAL_SIZE_GIB = 20" in python
    assert "MAXIMUM_DIRECT_FAT32_SIZE_GIB = 31" in python
    assert "LARGE_INSTALLATION_STAGING_SIZE_GIB = 8" in python


@pytest.mark.parametrize(
    ("description", "path", "expected"),
    [
        ("Install Linux", r"\grldr.mbr", True),
        ("Install Linux", "/grldr.mbr", True),
        ("Libertix UEFI Installer", r"\EFI\BOOT\BOOTX64.EFI", True),
        ("Windows Boot Manager", r"\EFI\Microsoft\Boot\bootmgfw.efi", False),
        ("Firmware utility", r"\EFI\BOOT\BOOTX64.EFI", False),
        ("Install Linux", r"\EFI\BOOT\BOOTX64.EFI", False),
    ],
)
def test_bcd_cleanup_only_selects_owned_temporary_entries(
    bcd_cleanup_module: ModuleType,
    description: str,
    path: str,
    expected: bool,
) -> None:
    assert bcd_cleanup_module.is_libertix_temporary_entry(description, path) is expected


def test_firmware_wrappers_delegate_to_shared_implementations() -> None:
    runner_bios = (ROOT / "iso/live/libertix-runner.sh").read_text(encoding="utf-8-sig")
    runner_uefi = (ROOT / "iso-uefi/live/libertix-runner.sh").read_text(encoding="utf-8-sig")
    target_bios = (ROOT / "iso/target/configure-target.sh").read_text(encoding="utf-8-sig")
    target_uefi = (ROOT / "iso-uefi/target/configure-target.sh").read_text(encoding="utf-8-sig")

    assert "LIBERTIX_FIRMWARE_MODE=bios" in runner_bios
    assert "LIBERTIX_FIRMWARE_MODE=uefi" in runner_uefi
    assert "libertix-runner-main.sh" in runner_bios
    assert "libertix-runner-main.sh" in runner_uefi
    assert "LIBERTIX_FIRMWARE_MODE=bios" in target_bios
    assert "LIBERTIX_FIRMWARE_MODE=uefi" in target_uefi
    assert "configure-target-main.sh" in target_bios
    assert "configure-target-main.sh" in target_uefi


@pytest.mark.parametrize("firmware", ["iso", "iso-uefi"])
def test_grub_images_render_the_shared_menu_fragment(
    tmp_path: Path,
    firmware: str,
) -> None:
    renderer = load_live_module(
        "iso-tools/render-boot-config.py",
        f"libertix_boot_renderer_{firmware.replace('-', '_')}",
    )
    output = tmp_path / firmware / "grub.cfg"

    renderer.render(
        ROOT / "Scripts/config/Libertix.BootArguments.json",
        ROOT / firmware / "boot/grub.cfg",
        ROOT / "Scripts/config/Libertix.LiveGrubMenu.cfg.in",
        output,
    )

    rendered = output.read_text(encoding="utf-8")
    assert rendered.count('menuentry "Install Linux Mint (Automatic)"') == 1
    assert rendered.count('menuentry "Install (Verbose mode)"') == 1
    assert "@LIBERTIX_" not in rendered


def test_versioned_schemas_accept_documents_used_by_runtime_validators() -> None:
    plan = make_plan("uefi", 40)
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 0,
        "status": "pending",
        "phase": "windows",
        "activeStep": None,
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }

    validate_schema_document("installation-plan.schema.json", plan)
    validate_schema_document("installation-state.schema.json", state)


def test_windows_plan_models_and_powershell_property_sets_match_schema() -> None:
    schema = json.loads(
        (ROOT / "schemas/installation-plan.schema.json").read_text(encoding="utf-8")
    )
    expected = {
        "root": set(schema["properties"]),
        "distribution": set(schema["$defs"]["distribution"]["properties"]),
        "locale": set(schema["$defs"]["locale"]["properties"]),
        "account": set(schema["$defs"]["account"]["properties"]),
        "disk": set(schema["$defs"]["disk"]["properties"]),
        "partition": set(schema["$defs"]["partitionIdentity"]["properties"]),
        "installer": set(schema["$defs"]["installerPartition"]["properties"]),
        "features": set(schema["$defs"]["features"]["properties"]),
        "runtime": set(schema["$defs"]["runtime"]["properties"]),
        "development": set(schema["$defs"]["development"]["properties"]),
    }

    powershell = (ROOT / "Scripts/modules/Libertix.InstallationPlan.psm1").read_text(
        encoding="utf-8-sig"
    )
    property_table = powershell.split("$script:InstallationPlanPropertySets = [ordered]@{", 1)[
        1
    ].split("\n}", 1)[0]
    powershell_sets = {
        name: set(re.findall(r'"([A-Za-z][A-Za-z0-9]*)"', values))
        for name, values in re.findall(r"(?ms)^\s+(\w+)\s*=\s*@\((.*?)\)(?=\s*$)", property_table)
    }
    assert powershell_sets == expected

    csharp = (ROOT / "Installation/InstallationPlan.cs").read_text(encoding="utf-8")
    class_to_schema = {
        "InstallationPlan": "root",
        "InstallationDistribution": "distribution",
        "InstallationLocale": "locale",
        "InstallationAccount": "account",
        "InstallationDisk": "disk",
        "PartitionIdentity": "partition",
        "InstallerPartitionPlan": "installer",
        "InstallationFeatures": "features",
        "InstallationRuntime": "runtime",
        "InstallationDevelopmentOptions": "development",
    }
    for class_name, schema_name in class_to_schema.items():
        body = re.search(
            rf"(?ms)^\s*public sealed class {class_name}\s*\{{(.*?)^\s*\}}",
            csharp,
        )
        assert body is not None, class_name
        properties = set(re.findall(r'JsonPropertyName\("([^"]+)"\)', body.group(1)))
        assert properties == expected[schema_name], class_name


def test_persisted_runtime_names_match_across_language_boundaries() -> None:
    csharp = (ROOT / "Installation/RuntimeNames.cs").read_text(encoding="utf-8")
    names = dict(re.findall(r'public const string (\w+) = "([A-Za-z0-9_]+)";', csharp))
    assert names == {
        "InstallerVolumeLabel": "LIBERTIXEFI",
        "InstallationLogDirectory": "LibertixInstallLogs",
        "BiosRecoveryDirectory": "LibertixInstallRecovery",
        "BiosRecoveryTask": "LibertixInstallRecovery",
        "LinuxReadOnlyTask": "LibertixLinuxReadOnly",
    }

    recovery = (ROOT / "Scripts/libertix-recovery-guard.ps1").read_text(encoding="utf-8-sig")
    windows_share = (ROOT / "Scripts/libertix-configure-windows-share.ps1").read_text(
        encoding="utf-8-sig"
    )
    uefi = (ROOT / "Scripts/libertix-uefi-install.ps1").read_text(encoding="utf-8-sig")
    live_context = (ROOT / "assets/live/libertix-live-context.sh").read_text(encoding="utf-8-sig")
    live_logs = (ROOT / "assets/live/libertix-copy-logs.sh").read_text(encoding="utf-8-sig")

    assert f'$TaskName = "{names["BiosRecoveryTask"]}"' in recovery
    assert f'Join-Path $SystemDrive "{names["BiosRecoveryDirectory"]}"' in recovery
    assert f'Join-Path $SystemDrive "{names["InstallationLogDirectory"]}"' in recovery
    assert f'$script:LinuxReadOnlyTaskName = "{names["LinuxReadOnlyTask"]}"' in windows_share
    assert f'$InstallerLabel = "{names["InstallerVolumeLabel"]}"' in uefi
    assert names["InstallerVolumeLabel"] in live_context
    assert names["InstallationLogDirectory"] in live_logs


def test_windows_state_models_and_powershell_property_sets_match_schema() -> None:
    schema = json.loads(
        (ROOT / "schemas/installation-state.schema.json").read_text(encoding="utf-8")
    )
    expected = {
        "root": set(schema["properties"]),
        "progress": set(schema["$defs"]["progress"]["properties"]),
        "failure": set(schema["$defs"]["failure"]["properties"]),
    }

    powershell = (ROOT / "Scripts/modules/Libertix.InstallationState.psm1").read_text(
        encoding="utf-8-sig"
    )
    property_table = powershell.split("$script:InstallationStatePropertySets = [ordered]@{", 1)[
        1
    ].split("\n}", 1)[0]
    powershell_sets = {
        name: set(re.findall(r'"([A-Za-z][A-Za-z0-9]*)"', values))
        for name, values in re.findall(r"(?ms)^\s+(\w+)\s*=\s*@\((.*?)\)(?=\s*$)", property_table)
    }
    assert powershell_sets == expected

    csharp = (ROOT / "Installation/InstallationExecutionState.cs").read_text(encoding="utf-8")
    class_to_schema = {
        "InstallationExecutionState": "root",
        "InstallationProgress": "progress",
        "InstallationFailure": "failure",
    }
    for class_name, schema_name in class_to_schema.items():
        body = re.search(
            rf"(?ms)^\s*public sealed class {class_name}\s*\{{(.*?)^\s*\}}",
            csharp,
        )
        assert body is not None, class_name
        properties = set(re.findall(r'JsonPropertyName\("([^"]+)"\)', body.group(1)))
        assert properties == expected[schema_name], class_name


@pytest.mark.parametrize(
    "invalid_state",
    [
        {
            "status": "failed",
            "phase": "windows",
            "activeStep": None,
            "failure": None,
        },
        {
            "status": "succeeded",
            "phase": "complete",
            "activeStep": None,
            "failure": {
                "code": "stale",
                "message": "stale failure",
                "component": "windows",
            },
        },
        {
            "status": "rollback-running",
            "phase": "windows",
            "activeStep": None,
            "failure": {
                "code": "failure",
                "message": "failure",
                "component": "windows",
            },
        },
    ],
)
def test_state_schema_rejects_contradictory_lifecycle_fields(
    invalid_state: dict[str, object],
) -> None:
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 1,
        "status": "running",
        "phase": "windows",
        "activeStep": "windows.preflight-verified",
        "completedSteps": [],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }
    state.update(invalid_state)

    schema = json.loads(
        (ROOT / "schemas/installation-state.schema.json").read_text(encoding="utf-8")
    )
    validator = Draft202012Validator(schema, format_checker=FormatChecker())

    assert list(validator.iter_errors(state))


def validate_schema_document(schema_name: str, document: dict[str, object]) -> None:
    schema = json.loads((ROOT / "schemas" / schema_name).read_text(encoding="utf-8"))
    Draft202012Validator(schema, format_checker=FormatChecker()).validate(document)
