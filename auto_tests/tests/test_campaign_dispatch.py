from __future__ import annotations

from app.config import VMConfig
from app.services.campaign_dispatch import (
    SCENARIO_MATRIX,
    ScenarioRequirements,
    ScenarioSpec,
    _vm_compatible,
)


def _vm(**overrides: object) -> VMConfig:
    values = {
        "name": "vm1",
        "host": "192.0.2.10",
        "os": "Windows 10 UEFI",
        "vnc": "192.0.2.10:5900",
        "screen_width": 1280,
        "screen_height": 800,
        "vmid": 500,
        "firmware": "uefi",
        "automation_enabled": True,
    }
    values.update(overrides)
    return VMConfig(**values)


def test_vm_compatible_requires_matching_firmware_when_constrained() -> None:
    bios_requirement = ScenarioRequirements(firmware="bios")
    assert not _vm_compatible(_vm(firmware="uefi"), bios_requirement)
    assert _vm_compatible(_vm(firmware="bios"), bios_requirement)


def test_vm_compatible_requires_secondary_disk_when_constrained() -> None:
    requirement = ScenarioRequirements(requires_secondary_disk=True)
    assert not _vm_compatible(_vm(secondary_disk_boot_order=()), requirement)
    assert _vm_compatible(_vm(secondary_disk_boot_order=("scsi1",)), requirement)


def test_vm_compatible_with_no_requirements_accepts_any_vm() -> None:
    assert _vm_compatible(_vm(firmware="bios"), ScenarioRequirements())
    assert _vm_compatible(_vm(firmware="uefi"), ScenarioRequirements())


def test_starter_matrix_preserves_four_nominal_scenarios_with_verify_uninstall() -> None:
    nominal = [spec for spec in SCENARIO_MATRIX if "nominal" in spec.tags]
    assert len(nominal) == 4
    assert {(spec.distribution, spec.first_boot) for spec in nominal} == {
        ("mint", "windows"), ("mint", "linux"), ("zorin", "windows"), ("zorin", "linux"),
    }
    assert all(spec.verify_uninstall for spec in nominal)
    assert all(spec.requirements == ScenarioRequirements() for spec in nominal)


def test_starter_matrix_secondary_scenario_is_a_real_secondary_install() -> None:
    secondary = next(spec for spec in SCENARIO_MATRIX if "secondary-disk" in spec.tags)
    assert secondary.requirements.requires_secondary_disk is True
    assert secondary.snapshot_mode == "secondary-disk"
    assert secondary.installation_target == "secondary"
    assert secondary.verify_uninstall is True


def test_scenario_spec_storage_fixture_defaults_to_concrete_instance() -> None:
    from app.storage_fixtures import StorageFixtureRequest

    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    assert isinstance(spec.storage_fixture, StorageFixtureRequest)
