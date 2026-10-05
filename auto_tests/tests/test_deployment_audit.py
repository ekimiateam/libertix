"""Prove that the deployment audit detects each defect class it claims to detect.

Every test injects one defect into an in-memory copy of a real source file; the
repository files are never modified.
"""

from __future__ import annotations

import pytest

from tools import deployment_audit as audit

RESULT_SCRIPT = "Scripts/libertix-post-install-result.ps1"
PLAN_ENGINE = "Installation/InstallationEngine.Plan.cs"
VERIFICATION_MODULE = "Scripts/modules/Libertix.PostInstallVerification.psm1"


def run_with(monkeypatch: pytest.MonkeyPatch, relative: str, old: str, new: str):
    original_read = audit.read
    source = original_read(relative)
    assert old in source, f"the injected defect no longer matches {relative}"

    def patched_read(path: str) -> str:
        text = original_read(path)
        return text.replace(old, new, 1) if path == relative else text

    monkeypatch.setattr(audit, "read", patched_read)
    _, findings, _ = audit.run_audit()
    return {(finding.rule, finding.where.split(":")[0]) for finding in findings}, findings


def test_layouts_are_rebuilt_from_the_real_sources() -> None:
    # Findings about Libertix itself are reported by the program, not accepted here.
    layouts, _, _ = audit.run_audit()

    assert {"recover.ps1", "libertix-post-install-result.ps1", "libertix.atomicfile.psm1"} <= set(
        layouts["bios-recovery"].files
    )
    assert "payload/scripts/modules/libertix.atomicfile.psm1" in layouts["uefi-recovery"].files
    assert set(layouts["windows-share"].files) == {
        "mount-linux-readonly.ps1",
        "libertix.process.psm1",
        "libertix.windowsprofiles.psm1",
        "libertix.bootguardian.exe",
    }
    assert layouts["bios-recovery"].protected is True
    assert layouts["uefi-recovery"].protected is True
    assert layouts["windows-share"].protected is True


def test_a_module_looked_up_only_in_the_tree_layout_breaks_bios(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    rules, _ = run_with(
        monkeypatch,
        RESULT_SCRIPT,
        'Join-Path $PSScriptRoot "Libertix.AtomicFile.psm1"',
        'Join-Path $PSScriptRoot "modules\\Libertix.AtomicFile.psm1"',
    )

    assert ("missing-in-layout", RESULT_SCRIPT) in rules


def test_an_unprotected_recovery_folder_is_reported(monkeypatch: pytest.MonkeyPatch) -> None:
    rules, _ = run_with(
        monkeypatch,
        PLAN_ENGINE,
        "ProtectDirectoryForInstallerAndSystem(persistenceRoot);",
        "Directory.CreateDirectory(persistenceRoot);",
    )

    assert ("privileged-folder", "bios-recovery") in rules
    assert ("privileged-folder", "uefi-recovery") not in rules


def test_a_probe_into_an_unprotected_folder_is_an_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    run_with(
        monkeypatch,
        "Installation/InstallationEngine.Windows.cs",
        "ProtectDirectoryForInstallerAndSystem(WindowsShareRoot, readableByUsers: true);",
        "Directory.CreateDirectory(WindowsShareRoot);",
    )
    rules, findings = run_with(
        monkeypatch,
        "Scripts/libertix-configure-windows-share.ps1",
        'Join-Path $PSScriptRoot "Libertix.Process.psm1"',
        '@((Join-Path $PSScriptRoot "modules\\Libertix.Process.psm1"), '
        '(Join-Path $PSScriptRoot "Libertix.Process.psm1"))',
    )

    assert ("probe-in-writable-folder", "Scripts/libertix-configure-windows-share.ps1") in rules
    assert any("modules\\Libertix.Process.psm1" in finding.message for finding in findings)


@pytest.mark.parametrize(
    "statement",
    [
        "Directory.SetAccessControl(path, DirectorySecurity(readableByUsers));",
        "security.SetAccessRuleProtection(true, false);",
        "security.SetOwner(new SecurityIdentifier("
        "WellKnownSidType.BuiltinAdministratorsSid, null));",
        "RequireTree(path, administrator);",
    ],
)
def test_missing_acl_enforcement_stops_the_audit(monkeypatch, statement):
    with pytest.raises(audit.AuditStructureError):
        run_with(monkeypatch, "Helpers/ProtectedFiles.cs", statement, "// " + statement)


def test_a_removed_guard_invalidates_its_documented_exception(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    rules, _ = run_with(
        monkeypatch,
        VERIFICATION_MODULE,
        'if ([string]$Plan.firmware -ne "uefi") {\n        return "not-required"\n    }',
        "",
    )

    assert ("unguarded-exception", VERIFICATION_MODULE) in rules


def test_an_unexplained_dynamic_reference_is_an_error(monkeypatch: pytest.MonkeyPatch) -> None:
    rules, _ = run_with(
        monkeypatch,
        RESULT_SCRIPT,
        'Join-Path $PSScriptRoot "Libertix.AtomicFile.psm1"',
        "Join-Path $PSScriptRoot $moduleFile",
    )

    assert ("dynamic-reference", RESULT_SCRIPT) in rules


def test_an_undeclared_entry_point_is_an_error(monkeypatch: pytest.MonkeyPatch) -> None:
    entries = {name: list(values) for name, values in audit.ENTRY_POINTS.items()}
    entries["application"] = [
        entry for entry in entries["application"] if "disk-image" not in entry[0]
    ]
    monkeypatch.setattr(audit, "ENTRY_POINTS", entries)

    _, findings, _ = audit.run_audit()

    assert ("undeclared-entry", "Scripts/libertix-disk-image.ps1") in {
        (finding.rule, finding.where) for finding in findings
    }


def test_a_required_file_that_is_never_copied_is_reported(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    rules, _ = run_with(
        monkeypatch,
        "Installation/InstallationEngine.Windows.cs",
        '"Libertix.BiosMbr.psm1",',
        "",
    )

    assert ("required-not-deployed", "Helpers/InstalledLinuxRecovery.cs") in rules


def test_an_unknown_source_shape_stops_the_audit(monkeypatch: pytest.MonkeyPatch) -> None:
    original_read = audit.read
    monkeypatch.setattr(
        audit,
        "read",
        lambda path: (
            original_read(path).replace("BiosRecoveryModules", "BiosModules")
            if path == "Installation/InstallationEngine.Windows.cs"
            else original_read(path)
        ),
    )

    with pytest.raises(audit.AuditStructureError):
        audit.run_audit()
