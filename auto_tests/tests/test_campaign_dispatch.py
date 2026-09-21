from __future__ import annotations

import pytest

from app.config import VMConfig
from app.errors import WorkflowError
from app.services.campaign_dispatch import (
    SCENARIO_MATRIX,
    ScenarioRequirements,
    ScenarioSpec,
    _expand_runs,
    _fleet_profiles,
    _resolve_specs,
    _resolve_worker_pool,
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


def _settings_with_vms(*vm_overrides: dict) -> object:
    from tests.test_core import settings

    # Settings requires distinct, allow-listed vmids across configured VMs; the
    # shared _vm() helper defaults every VM to the same vmid, so assign unique
    # ones here (settings()'s default allowed_proxmox_vmids is (500, 501, 502)).
    vms = tuple(
        _vm(**{"vmid": 500 + index, **overrides})
        for index, overrides in enumerate(vm_overrides)
    )
    return settings(vms=vms)


def test_fleet_profiles_returns_every_automation_enabled_profile_for_unconstrained_spec() -> None:
    fleet = (
        _vm(name="a", os="Windows 10 BIOS", firmware="bios"),
        _vm(name="b", os="Windows 10 UEFI", firmware="uefi"),
        _vm(name="c", os="Windows 10 UEFI", firmware="uefi", automation_enabled=False),
    )
    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    assert _fleet_profiles(spec, fleet) == {"Windows 10 BIOS", "Windows 10 UEFI"}


def test_resolve_specs_defaults_to_full_matrix() -> None:
    fleet = (
        _vm(name="a", os="Windows 10 BIOS", firmware="bios"),
        _vm(name="b", os="Windows 10 UEFI", firmware="uefi"),
        _vm(name="c", os="Windows 11 UEFI", firmware="uefi"),
    )
    resolved = _resolve_specs(SCENARIO_MATRIX, None, fleet)
    assert {spec.id for spec in resolved} == {
        "mint-windows-first", "mint-linux-first", "zorin-windows-first", "zorin-linux-first",
    }  # secondary scenario silently dropped: no fleet VM has secondary_disk_boot_order


def test_resolve_specs_rejects_unknown_scenario_id() -> None:
    fleet = (_vm(name="a"),)
    with pytest.raises(WorkflowError, match="Unknown"):
        _resolve_specs(SCENARIO_MATRIX, ["not-a-real-scenario"], fleet)


def test_resolve_specs_rejects_explicit_id_with_zero_fleet_wide_compatible_profiles() -> None:
    fleet = (_vm(name="a", os="Windows 10 UEFI", secondary_disk_boot_order=()),)
    with pytest.raises(WorkflowError, match="No VM"):
        _resolve_specs(SCENARIO_MATRIX, ["mint-secondary-install"], fleet)


def test_resolve_specs_raises_when_nothing_resolves() -> None:
    with pytest.raises(WorkflowError, match="No scenarios"):
        _resolve_specs((), None, (_vm(name="a"),))


def test_resolve_worker_pool_omitted_filter_uses_automation_enabled_only() -> None:
    configured = _settings_with_vms(
        {"name": "a", "automation_enabled": True},
        {"name": "b", "automation_enabled": False},
    )
    pool = _resolve_worker_pool(configured, None)
    assert [vm.name for vm in pool] == ["a"]


def test_resolve_worker_pool_explicit_filter_resolves_aliases_via_select_vms() -> None:
    configured = _settings_with_vms(
        {"name": "vm1", "os": "Windows 10 UEFI", "firmware": "uefi", "automation_enabled": True},
    )
    pool = _resolve_worker_pool(configured, ["win10-uefi"])
    assert [vm.name for vm in pool] == ["vm1"]


def test_resolve_worker_pool_rejects_explicitly_selected_disabled_vm() -> None:
    configured = _settings_with_vms({"name": "vm1", "automation_enabled": False})
    with pytest.raises(WorkflowError, match="automation-enabled"):
        _resolve_worker_pool(configured, ["vm1"])


def test_resolve_worker_pool_propagates_unknown_selector_error() -> None:
    configured = _settings_with_vms({"name": "vm1", "automation_enabled": True})
    with pytest.raises(WorkflowError, match="Unknown VM selector"):
        _resolve_worker_pool(configured, ["does-not-exist"])


def test_expand_runs_produces_one_run_per_profile_per_spec() -> None:
    fleet = (
        _vm(name="a", os="Windows 10 BIOS", firmware="bios"),
        _vm(name="b", os="Windows 10 UEFI", firmware="uefi"),
    )
    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    runs = _expand_runs([spec], fleet, list(fleet))
    assert {run.profile for run in runs} == {"Windows 10 BIOS", "Windows 10 UEFI"}
    assert all(run.run_id == f"x::{run.profile}" for run in runs)


def test_expand_runs_rejects_vm_filter_that_drops_required_coverage() -> None:
    fleet = (
        _vm(name="a", os="Windows 10 BIOS", firmware="bios"),
        _vm(name="b", os="Windows 10 UEFI", firmware="uefi"),
    )
    pool = [vm for vm in fleet if vm.name == "a"]  # filtered pool drops the UEFI profile
    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    with pytest.raises(WorkflowError, match="VM filter"):
        _expand_runs([spec], fleet, pool)


def test_expand_runs_two_vms_sharing_a_profile_still_produce_one_run() -> None:
    fleet = (
        _vm(name="a", os="Windows 11 UEFI", firmware="uefi"),
        _vm(name="b", os="Windows 11 UEFI", firmware="uefi"),
    )
    spec = ScenarioSpec(id="x", tags=(), requirements=ScenarioRequirements())
    runs = _expand_runs([spec], fleet, list(fleet))
    assert len(runs) == 1
