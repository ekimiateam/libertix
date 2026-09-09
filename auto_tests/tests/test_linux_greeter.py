import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

from app.clients.ssh import CommandResult
from app.errors import WorkflowError
from app.services.automation import AutomationService
from app.services.common import ResultBuilder

from .test_core import settings


@pytest.mark.parametrize("failed_capture", [False, True])
@pytest.mark.parametrize("focus_missing", [False, True])
@pytest.mark.parametrize("locked", [False, True])
def test_gdm_selects_proven_account_and_submits_before_capture(
    monkeypatch, failed_capture, focus_missing, locked
):
    service = AutomationService(settings())
    vm = service.settings.vms[0]
    events = []
    responses = iter(
        [
            CommandResult("LIBERTIX_GDM_LOCKED" if locked else "LIBERTIX_GDM_GREETER_READY", "", 0),
            CommandResult("1000", "", 0),
            CommandResult('ao 1 "/org/freedesktop/Accounts/User1000"\ns "test"\nb false\n', "", 0),
            CommandResult("LIBERTIX_DESKTOP_READY", "", 0),
        ]
    )
    ssh = SimpleNamespace(run=lambda *_a, **_k: next(responses))
    client = SimpleNamespace(
        keyPress=lambda key: events.append(key),
        keyDown=lambda key: events.append("down:" + key),
        keyUp=lambda key: events.append("up:" + key),
        disconnect=lambda: events.append("disconnect"),
    )
    monkeypatch.setattr("app.services.automation_postinstall.time.sleep", lambda _: None)
    monkeypatch.setattr(service.vnc, "connect", lambda _: client)
    monkeypatch.setattr(service, "_type_text", lambda *_: events.append("password"))
    monkeypatch.setattr(service, "_capture_with_name", lambda *_: Path("desktop.png"))
    states = iter(([True] if not locked else []) + ([False, True] if focus_missing else [True]))
    monkeypatch.setattr(service, "_wait_for_gdm_password_worker", lambda *_a, **_k: next(states))

    def capture(_client, _vm, label, _result):
        events.append(label)
        if label.endswith("submitted") and failed_capture:
            raise WorkflowError(
                "automation.capture", "Missing capture", details={"phase": "submitted"}
            )
        return Path(label + ".png")

    monkeypatch.setattr(service, "_capture_from_client", capture)
    result = ResultBuilder("automation")
    service._prepare_linux_graphical_session(ssh, vm, result, "test", "fixture-password")
    if not locked:
        assert events[:4] == ["post-install-linux-login-01-ready", "esc", "home", "enter"]
        assert ("tab" in events) == focus_missing
    else:
        assert "esc" not in events
        assert "tab" not in events
    password_index = events.index("password")
    assert events[password_index + 1 : password_index + 3] == [
        "enter",
        "post-install-linux-login-01-submitted",
    ]
    assert events.count("password") == 1
    assert result.steps[-1].step == "automation.linux_graphical_session"
    if failed_capture:
        assert result.steps[0].context["capture_details"] == {"phase": "submitted"}


@pytest.mark.parametrize(
    "uid,inventory",
    [
        ("0", ""),
        ("bad", ""),
        (
            "1000",
            'ao 2 "/org/freedesktop/Accounts/User1000" "/org/freedesktop/Accounts/User1001"'
            '\ns "test"\nb false',
        ),
        ("1000", 'ao 1 "/org/freedesktop/Accounts/User1000"\ns "other"\nb false'),
        ("1000", 'ao 1 "/org/freedesktop/Accounts/User1000"\ns "test"\nb true'),
        ("1000", 'ao 1 "unterminated'),
    ],
)
def test_gdm_rejects_unknown_or_ambiguous_account_before_keyboard(monkeypatch, uid, inventory):
    service = AutomationService(settings())
    responses = iter(
        [
            CommandResult("LIBERTIX_GDM_GREETER_READY", "", 0),
            CommandResult(uid, "", 0),
            CommandResult(inventory, "", 0),
        ]
    )
    ssh = SimpleNamespace(run=lambda *_a, **_k: next(responses))
    monkeypatch.setattr(service.vnc, "connect", lambda _: pytest.fail("No keyboard input allowed"))
    with pytest.raises(WorkflowError) as error:
        service._prepare_linux_graphical_session(
            ssh, service.settings.vms[0], ResultBuilder("automation"), "test", "fixture-password"
        )
    assert error.value.step == "automation.gdm_account_identity"


@pytest.mark.parametrize("locked", [False, True])
def test_gdm_never_types_secret_without_password_conversation(monkeypatch, locked):
    service = AutomationService(settings())
    marker = "LIBERTIX_GDM_LOCKED" if locked else "LIBERTIX_GDM_GREETER_READY"
    ssh = SimpleNamespace(run=lambda *_a, **_k: CommandResult(marker, "", 0))
    keys = []
    client = SimpleNamespace(keyPress=keys.append, disconnect=lambda: None)
    monkeypatch.setattr(service, "_assert_single_gdm_account", lambda *_: None)
    monkeypatch.setattr(
        service, "_wait_for_gdm_password_worker", lambda *_a, **kw: not kw["present"]
    )
    monkeypatch.setattr(service.vnc, "connect", lambda _: client)
    monkeypatch.setattr(service, "_capture_from_client", lambda *_: Path("ready.png"))
    monkeypatch.setattr(service, "_type_text", lambda *_: pytest.fail("No secret may be typed"))
    with pytest.raises(WorkflowError, match="five attempts"):
        service._prepare_linux_graphical_session(
            ssh, service.settings.vms[0], ResultBuilder("automation"), "test", "secret"
        )
    assert keys.count("esc") == (0 if locked else 5)


@pytest.mark.parametrize("present", [False, True])
def test_password_worker_wait_is_bounded_and_requires_exact_state(monkeypatch, present):
    marker = "LIBERTIX_GDM_PASSWORD_PENDING" if present else "LIBERTIX_GDM_PASSWORD_ABSENT"
    commands = []
    ssh = SimpleNamespace(
        run=lambda command, **_: commands.append(command) or CommandResult(marker, "", 0)
    )
    monkeypatch.setattr("app.services.automation_postinstall.time.sleep", lambda _: None)
    assert AutomationService._wait_for_gdm_password_worker(ssh, present=present)
    assert "-p Leader" in commands[0]
    assert "pgrep -u 0" in commands[0]
    commands.clear()
    assert not AutomationService._wait_for_gdm_password_worker(ssh, present=not present)
    assert len(commands) == 5


@pytest.mark.parametrize("stdout,code", [("", 0), ("LIBERTIX_GDM_PASSWORD_PENDING", 2)])
def test_password_worker_unknown_state_refuses_input(stdout, code):
    ssh = SimpleNamespace(run=lambda *_a, **_k: CommandResult(stdout, "", code))
    with pytest.raises(WorkflowError) as error:
        AutomationService._wait_for_gdm_password_worker(ssh, present=True)
    assert error.value.step == "automation.gdm_password_state"


@pytest.mark.parametrize("workers,pending", [("100", False), ("100 200", True), ("", False)])
def test_password_probe_executes_shell_and_excludes_existing_session(monkeypatch, workers, pending):
    prelude = (
        "loginctl() { case \"$1\" in list-sessions) echo 'c1 1000 test';; "
        "show-session) echo 100;; esac; }; "
        f'pgrep() {{ for pid in {workers}; do echo "$pid"; done; }}; '
    )
    if not workers:
        prelude = prelude[: prelude.index("pgrep()")] + "pgrep() { return 1; }; "

    def run(command, **_):
        response = subprocess.run(
            ["bash", "-c", prelude + command], capture_output=True, text=True, timeout=5
        )
        return CommandResult(response.stdout, response.stderr, response.returncode)

    monkeypatch.setattr("app.services.automation_postinstall.time.sleep", lambda _: None)
    assert AutomationService._wait_for_gdm_password_worker(
        SimpleNamespace(run=run), present=pending
    )


def test_password_probe_refuses_failed_session_inventory():
    def run(command, **_):
        response = subprocess.run(
            ["bash", "-c", "loginctl() { return 1; }; pgrep() { echo 200; }; " + command],
            capture_output=True,
            text=True,
            timeout=5,
        )
        return CommandResult(response.stdout, response.stderr, response.returncode)

    with pytest.raises(WorkflowError) as error:
        AutomationService._wait_for_gdm_password_worker(SimpleNamespace(run=run), present=True)
    assert error.value.step == "automation.gdm_password_state"
