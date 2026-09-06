from __future__ import annotations

from types import SimpleNamespace

import pytest

import app.services.automation_postinstall as postinstall
from app.clients.ssh import CommandResult
from app.errors import WorkflowError
from app.services.automation import AutomationService
from app.services.common import ResultBuilder

from .test_core import settings


def test_missing_exit_status_during_reboot_is_pending_not_proven() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]

    class DisconnectedSSH:
        def run(self, *_args, **_kwargs):
            raise WorkflowError(
                "ssh.command",
                "No exit status",
                details={"exception_type": "MissingExitStatus", "exit_code": -1},
            )

    result = ResultBuilder("automation")
    service._request_linux_boot_from_windows(DisconnectedSSH(), vm, result)  # noqa: SLF001
    assert len(result.steps) == 1
    assert result.steps[0].context["request_acknowledged"] is False
    assert result.steps[0].context["reboot_verified"] is False
    assert "must still be proven" in result.steps[0].message


@pytest.mark.parametrize("changes", [False, True])
def test_windows_ssh_wait_rejects_the_old_boot_session(monkeypatch, changes: bool) -> None:
    service = AutomationService(settings(post_install_boot_timeout_seconds=1))
    vm = service.validation.select_vms(["vm2"])[0]
    counter = iter(i / 10 for i in range(100))
    monkeypatch.setattr(
        postinstall, "time", SimpleNamespace(monotonic=lambda: next(counter), sleep=lambda _: None)
    )
    clients = []

    class ConnectedSSH:
        def __init__(self, *_args, **_kwargs):
            self.closed = False
            clients.append(self)

        def __enter__(self):
            return self

        def __exit__(self, *_args):
            self.closed = True

        def run(self, *_args, **_kwargs):
            return CommandResult("WINDOWS_READY", "", 0)

    monkeypatch.setattr(postinstall, "SSHClient", ConnectedSSH)
    monkeypatch.setattr(
        service,
        "_read_windows_boot_id",
        lambda *_: "638000000000000001" if changes and len(clients) > 1 else "638000000000000000",
    )
    result = ResultBuilder("automation")

    def wait():
        return service._wait_for_ssh(  # noqa: SLF001
            vm,
            result=result,
            username="test",
            password="test",
            trust_on_first_use=False,
            probe="probe",
            expected="WINDOWS_READY",
            phase="test-reboot",
            previous_windows_boot_id="638000000000000000",
        )

    if changes:
        current = wait()
        assert len(clients) == 2
        assert clients[0].closed
        assert not current.closed
        assert result.steps[-1].context["boot_id"] == "638000000000000001"
    else:
        with pytest.raises(WorkflowError, match="Timed out"):
            wait()
        assert all(client.closed for client in clients)
        assert not result.steps


def test_unanswered_consent_records_boot_identity_before_request(monkeypatch) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    calls = []

    class DisconnectedSSH:
        def run(self, command, **_kwargs):
            calls.append(command)
            if len(calls) == 1:
                return CommandResult("638000000000000000", "", 0)
            raise WorkflowError("ssh", "missing", details={"exception_type": "MissingExitStatus"})

    result = ResultBuilder("automation")
    previous = service._request_unanswered_prompt_reboot(DisconnectedSSH(), vm, result)  # noqa: SLF001
    assert previous == "638000000000000000"
    assert "LastBootUpTime" in calls[0]
    assert calls[1].startswith("shutdown.exe")
    assert result.steps[-1].context["reboot_verified"] is False
