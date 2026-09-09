from copy import deepcopy
from types import SimpleNamespace

import pytest
from pydantic import SecretStr

from app.errors import WorkflowError
from app.services import windows_lab_login as login


@pytest.fixture
def lab(monkeypatch, tmp_path):
    calls = []
    vm = SimpleNamespace(
        vmid=501,
        name="uefi",
        username="admin",
        vnc="test:1",
        vnc_keyboard_layout="fr",
        secondary_disk_boot_order=("sata0", "sata1"),
        automation_enabled=True,
    )
    client = SimpleNamespace(
        keyPress=lambda key: calls.append(("key", key)),
        disconnect=lambda: calls.append(("disconnect",)),
    )
    service = SimpleNamespace(
        settings=SimpleNamespace(
            allowed_proxmox_vmids=(501,), windows_ssh_password=SecretStr("lab-only-secret")
        ),
        _capture_dir=tmp_path,
        vnc=SimpleNamespace(
            capture=lambda *_: calls.append(("capture",)), connect=lambda _: client
        ),
        _type_text=lambda _, value, layout: calls.append(("password", value, layout)),
    )
    monkeypatch.setattr(login.time, "sleep", lambda _: None)
    state = {
        "explorers": [],
        "logonProcesses": [{"id": 123, "session": 1}],
        "lastUser": ".\\admin",
        "passwordProvider": True,
        "automaticLogon": False,
        "keyboard": "0000040c",
    }
    return service, vm, calls, state


def test_skips_keyboard_when_expected_desktop_is_already_present(lab, monkeypatch):
    service, vm, calls, state = lab
    state["explorers"] = [{"user": "admin", "session": 1}]
    monkeypatch.setattr(login, "_read_state", lambda *_: state)
    login.ensure_secondary_windows_session(service, None, "lab", vm)
    assert calls == []


def test_rechecks_password_provider_then_submits_once_and_proves_desktop(lab, monkeypatch):
    service, vm, calls, state = lab
    ready = deepcopy(state)
    ready["explorers"] = [{"user": "admin", "session": 1}]
    states = iter([state, state, ready])
    monkeypatch.setattr(login, "_read_state", lambda *_: next(states))
    login.ensure_secondary_windows_session(service, None, "lab", vm)
    assert calls == [
        ("capture",),
        ("key", "ctrl-alt-delete"),
        ("key", "ctrl-a"),
        ("password", "lab-only-secret", "fr"),
        ("key", "enter"),
        ("disconnect",),
    ]


@pytest.mark.parametrize(
    "field,value",
    [
        ("lastUser", ".\\other"),
        ("lastUser", "DOMAIN\\admin"),
        ("passwordProvider", False),
        ("automaticLogon", True),
        ("keyboard", "00000409"),
        ("logonProcesses", [{"id": 123, "session": 0}]),
        ("logonProcesses", [{"id": 123, "session": 1}, {"id": 124, "session": 2}]),
        ("explorers", [{"user": "other", "session": 1}]),
    ],
)
def test_refuses_unproven_logon_before_any_keyboard_input(lab, monkeypatch, field, value):
    service, vm, calls, state = lab
    state[field] = value
    monkeypatch.setattr(login, "_read_state", lambda *_: state)
    with pytest.raises(WorkflowError):
        login.ensure_secondary_windows_session(service, None, "lab", vm)
    assert calls == []


def test_does_not_type_when_logon_identity_changes_after_secure_attention(lab, monkeypatch):
    service, vm, calls, state = lab
    changed = deepcopy(state)
    changed["logonProcesses"][0]["id"] = 456
    states = iter([state, changed])
    monkeypatch.setattr(login, "_read_state", lambda *_: next(states))
    with pytest.raises(WorkflowError, match="changed before password"):
        login.ensure_secondary_windows_session(service, None, "lab", vm)
    assert calls == [("capture",), ("key", "ctrl-alt-delete"), ("disconnect",)]


def test_failure_is_bounded_and_does_not_repeat_password_submission(lab, monkeypatch):
    service, vm, calls, state = lab
    ticks = iter(range(100))
    monkeypatch.setattr(login.time, "monotonic", lambda: next(ticks))
    monkeypatch.setattr(login, "LOGIN_TIMEOUT_SECONDS", 4)
    monkeypatch.setattr(login, "_read_state", lambda *_: state)
    with pytest.raises(WorkflowError, match="One login attempt") as caught:
        login.ensure_secondary_windows_session(service, None, "lab", vm)
    assert sum(call[0] == "password" for call in calls) == 1
    assert sum(call == ("key", "enter") for call in calls) == 1
    assert calls[-1] == ("capture",)
    assert "lab-only-secret" not in str(caught.value)
    assert caught.value.details == {"vm": "uefi", "vmid": 501}


def test_does_not_apply_to_an_unconfigured_snapshot_workflow(lab):
    service, vm, calls, _ = lab
    vm.secondary_disk_boot_order = ()
    with pytest.raises(WorkflowError, match="authorized secondary-disk"):
        login.ensure_secondary_windows_session(service, None, "lab", vm)
    assert calls == []
