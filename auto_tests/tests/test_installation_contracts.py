from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType

import pytest
from jsonschema import Draft202012Validator, FormatChecker

ROOT = Path(__file__).resolve().parents[2]
GIB = 1024**3


def load_live_module(relative_path: str, module_name: str) -> ModuleType:
    """Load a live helper exactly as the ISO executes it, without packaging it."""

    path = ROOT / relative_path
    spec = importlib.util.spec_from_file_location(module_name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load live helper: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
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
            "passwordHash": "$6$salt$hash",
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
                "offsetBytes": 220 * GIB,
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
    assert exported["INSTALLER_FINAL_SIZE_BYTES"] == str(final_size_gib * GIB)
    assert exported["INSTALLER_STAGING_SIZE_BYTES"] == str(staging_size_gib * GIB)


@pytest.mark.parametrize(
    ("field_path", "invalid_value"),
    [
        (("distribution", "installerIsoFileName"), "folder/mint.iso"),
        (("distribution", "installerIsoWindowsPath"), "C:mint.iso"),
        (("account", "passwordHash"), "$6$salt\nvalue"),
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
        "staticIpv4Address": "192.168.1.241",
        "staticIpv4PrefixLength": 24,
        "staticIpv4Gateway": "192.168.1.1",
        "dnsServers": ["8.8.8.8", "1.1.1.1"],
    }

    validated = plan_module.validate_plan(plan, require_installer=True)
    exported = plan_module.shell_values(validated)

    assert exported["DEVELOPMENT_SSH_ENABLED"] == "true"
    assert exported["DEVELOPMENT_STATIC_IPV4_ADDRESS"] == "192.168.1.241"
    assert exported["DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH"] == "24"
    assert exported["DEVELOPMENT_STATIC_IPV4_GATEWAY"] == "192.168.1.1"
    assert exported["DEVELOPMENT_DNS_PRIMARY"] == "8.8.8.8"
    assert exported["DEVELOPMENT_DNS_SECONDARY"] == "1.1.1.1"
    validate_schema_document("installation-plan.schema.json", plan)


def test_plan_without_development_access_exports_disabled_defaults(
    plan_module: ModuleType,
) -> None:
    exported = plan_module.shell_values(make_plan("bios", 20))

    assert exported["DEVELOPMENT_SSH_ENABLED"] == "false"
    assert exported["DEVELOPMENT_STATIC_IPV4_ADDRESS"] == ""


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("enableSsh", False),
        ("staticIpv4Address", "192.168.2.241"),
        ("staticIpv4PrefixLength", 16),
        ("staticIpv4Gateway", "192.168.1.254"),
        ("dnsServers", ["1.1.1.1", "8.8.8.8"]),
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
        "staticIpv4Address": "192.168.1.241",
        "staticIpv4PrefixLength": 24,
        "staticIpv4Gateway": "192.168.1.1",
        "dnsServers": ["8.8.8.8", "1.1.1.1"],
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

    state_module.start_step(state, "windows.system-volume-shrunk")
    state_module.complete_step(state, "windows.system-volume-shrunk")
    state_module.start_step(state, "windows.installer-partition-created")
    state_module.fail(state, "TEST_FAILURE", "windows", "Injected failure")
    state_module.begin_rollback(state)

    with pytest.raises(state_module.StateTransitionError):
        state_module.compensate(state, "windows.installer-partition-created")

    state_module.compensate(state, "windows.system-volume-shrunk")
    state_module.complete_rollback(state)

    assert state["status"] == "rolled-back"
    assert state["phase"] == "complete"
    assert state["completedSteps"] == ["windows.system-volume-shrunk"]
    assert state["compensatedSteps"] == ["windows.system-volume-shrunk"]


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
