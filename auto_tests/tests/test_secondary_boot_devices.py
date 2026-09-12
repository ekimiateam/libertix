from copy import deepcopy
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

from app.clients.proxmox import ProxmoxClient
from app.config import VMConfig
from app.errors import WorkflowError
from app.services.automation import AutomationService
from app.services.common import ResultBuilder

from .test_core import settings


def test_boot_override_defaults_to_no_mutation():
    s = settings()
    service = AutomationService(s)
    service._proxmox = lambda: pytest.fail("No configured override must not access Proxmox")
    service._prepare_secondary_boot_devices(ResultBuilder("automation"), s.vms, {})


@pytest.mark.parametrize("order", [("sata0", "sata0"), ("sata1;net0",), ("disk1",)])
def test_boot_override_validates_device_names(order):
    vm = settings().vms[0].model_dump()
    vm["secondary_disk_boot_order"] = order
    with pytest.raises(ValidationError):
        VMConfig.model_validate(vm)


@pytest.mark.parametrize("fault", ["", "missing-device", "attachment-changed", "wrong-order"])
def test_boot_update_uses_digest_and_verifies_only_boot_changed(fault):
    p = object.__new__(ProxmoxClient)
    cfg = {
        "boot": "order=sata0",
        "sata0": "disk-a",
        "sata1": "disk-b",
        "net0": "nic",
        "digest": "old",
    }
    if fault == "missing-device":
        cfg.pop("sata1")
    requests = []

    def request(method, path, *, step, data=None):
        requests.append((method, path, data))
        if method == "PUT":
            assert data == {"boot": "order=sata0;sata1;net0", "digest": "old"}
            cfg.update(data)
            cfg["digest"] = "new"
            if fault == "attachment-changed":
                cfg["sata1"] = "other-disk"
            if fault == "wrong-order":
                cfg["boot"] = "order=net0"
        return deepcopy(cfg)

    p._request = request
    if fault:
        with pytest.raises(WorkflowError):
            p.configure_test_boot_order("lab", 500, ("sata0", "sata1", "net0"))
    else:
        p.configure_test_boot_order("lab", 500, ("sata0", "sata1", "net0"))
    assert [r[0] for r in requests] == (
        ["GET"] if fault == "missing-device" else ["GET", "PUT", "GET"]
    )


def test_boot_override_cold_starts_before_network_probe(monkeypatch):
    s = settings()
    vm = s.vms[0].model_copy(update={"secondary_disk_boot_order": ("sata0", "sata1", "net0")})
    service = AutomationService(s)
    calls = []

    class FakeProxmox:
        def __enter__(self):
            return self

        def __exit__(self, *_args):
            pass

        def locate_vm(self, vmid):
            return "lab"

        def configure_test_boot_order(self, node, vmid, devices):
            calls.append("configure")

        def shutdown_vm(self, node, vmid):
            calls.append("shutdown")

        def start_vm(self, node, vmid):
            calls.append("start")

        def wait_for_vm_status(self, *args, **kwargs):
            calls.append("running")

    monkeypatch.setattr(service, "_proxmox", FakeProxmox)
    monkeypatch.setattr(
        "app.services.automation.ensure_secondary_windows_session",
        lambda *args: calls.append("login"),
    )
    monkeypatch.setattr(
        service.preflight, "configure_windows_guest_network", lambda *args: calls.append("network")
    )
    result = ResultBuilder("automation")
    service._prepare_secondary_boot_devices(result, [vm], {vm.name: SimpleNamespace()})
    assert calls == ["configure", "shutdown", "start", "running", "login", "network"]
    assert result.steps[-1].step == "automation.secondary_boot_devices"


def test_shutdown_never_forces_a_stop_on_failure():
    p = object.__new__(ProxmoxClient)

    def request(method, path, *, step, data):
        assert data == {"timeout": 180, "forceStop": 0}
        return "UPID:test"

    p._request = request
    p._wait_task = lambda *args, **kwargs: (_ for _ in ()).throw(
        WorkflowError("shutdown", "failed")
    )
    p.wait_for_vm_status = lambda *args, **kwargs: pytest.fail("Must stop on shutdown failure")
    with pytest.raises(WorkflowError):
        p.shutdown_vm("lab", 500)


@pytest.mark.parametrize(
    "snapshot,target,expected",
    [
        (False, "windows", False),
        (True, "windows", False),
        (True, "secondary", True),
    ],
)
def test_boot_override_requires_explicit_secondary_allocation(
    monkeypatch, tmp_path, snapshot, target, expected
):
    service = AutomationService(settings())
    calls = []
    monkeypatch.setattr(service, "_restore_clean_snapshots", lambda *args: None)
    monkeypatch.setattr(service, "_prepare_windows_test_vm", lambda *args: None)
    monkeypatch.setattr(
        service, "_prepare_secondary_boot_devices", lambda *args: calls.append("boot")
    )

    def stop_before_build(*args, **kwargs):
        raise WorkflowError("test.stop", "No build or installation is allowed in this test")

    monkeypatch.setattr(service.validation, "prepare_server", stop_before_build)
    result = service.run(
        ["vm1"],
        linux_username="test",
        linux_password="test-password",
        linux_size_gib=20,
        monitor_iso=True,
        secondary_snapshot=snapshot,
        installation_target=target,
        run_workspace=tmp_path,
    )
    assert result.steps[-1].step == "test.stop"
    assert calls == (["boot"] if expected else [])
