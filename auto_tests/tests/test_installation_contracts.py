from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

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
