import runpy
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import SimpleNamespace

import pytest

from app.clients.ssh import CommandResult
from app.errors import WorkflowError
from app.services.automation import AutomationService

from .test_core import settings

HELPER = Path(__file__).parents[1] / "app/scripts/focus_linux_post_install_result.py"


@pytest.mark.parametrize(
    "fault", ["", "stale", "future", "inactive", "hidden", "pid", "fingerprint", "date"]
)
def test_product_focus_requires_fresh_exact_visible_active_state(fault):
    code = runpy.run_path(str(HELPER))
    state = {
        "processId": 123,
        "fingerprint": "a" * 64,
        "visible": True,
        "active": True,
        "updatedAtUtc": datetime.now(UTC).isoformat(),
    }
    replacements = {
        "stale": ("updatedAtUtc", (datetime.now(UTC) - timedelta(seconds=10)).isoformat()),
        "future": ("updatedAtUtc", (datetime.now(UTC) + timedelta(seconds=10)).isoformat()),
        "inactive": ("active", False),
        "hidden": ("visible", False),
        "pid": ("processId", 124),
        "fingerprint": ("fingerprint", "b" * 64),
        "date": ("updatedAtUtc", "invalid"),
    }
    if fault:
        key, value = replacements[fault]
        state[key] = value
    assert code["product_state_is_active"](state, 123, "a" * 64) is (not fault)


@pytest.mark.parametrize("outcome", ["active", "inactive", "identity-changed"])
def test_wayland_switching_is_bounded_and_never_sends_enter(monkeypatch, outcome):
    service = AutomationService(settings())
    vm = service.settings.vms[0]
    keys = []
    monkeypatch.setattr("app.services.automation_postinstall.time.sleep", lambda _: None)
    monkeypatch.setattr(
        service.vnc,
        "connect",
        lambda _: SimpleNamespace(
            keyDown=lambda key: keys.append(("down", key)),
            keyPress=lambda key: keys.append(("press", key)),
            keyUp=lambda key: keys.append(("up", key)),
            disconnect=lambda: None,
        ),
    )
    calls = []

    def probe(*args, **kwargs):
        calls.append(kwargs)
        active = outcome == "active" and len(calls) == 2
        fingerprint = "b" * 64 if outcome == "identity-changed" else "a" * 64
        return CommandResult(
            f"PROCESS_ID=123\nFINGERPRINT={fingerprint}\n"
            f"ACTIVE_WINDOW_PROVEN={active}\n"
            f"RESULT={'OK' if active else 'NEEDS_USER_ACTIVATION'}\n",
            "",
            0,
        )

    monkeypatch.setattr(service, "_run_linux_script_resiliently", probe)
    initial = {"PROCESS_ID": "123", "FINGERPRINT": "a" * 64}
    if outcome == "identity-changed":
        with pytest.raises(WorkflowError, match="identity changed"):
            service._activate_wayland_result(vm, object(), "123", initial)
    else:
        result = service._activate_wayland_result(vm, object(), "123", initial)
        assert result["ACTIVE_WINDOW_PROVEN"] == str(outcome == "active")
    assert len(calls) == {"active": 2, "inactive": 6, "identity-changed": 1}[outcome]
    assert all(key in {"alt", "tab"} for _, key in keys)
    assert all(call["arguments"][-1] == "--check-only" for call in calls)


def test_xprop_does_not_start_after_deadline(monkeypatch):
    code = runpy.run_path(str(HELPER))
    monkeypatch.setattr(code["time"], "monotonic", lambda: 10)
    monkeypatch.setattr(code["subprocess"], "run", lambda *a, **k: pytest.fail("Deadline expired"))
    with pytest.raises(TimeoutError):
        code["xprop"]({}, "-root", deadline=9)


@pytest.mark.parametrize(
    "delay,fault",
    [
        (25, ""),
        (85, ""),
        (95, ""),
        (0, "pid"),
        (0, "stale"),
        (0, "hidden"),
        (0, "fingerprint"),
        (0, "home"),
    ],
)
def test_window_readiness_waits_for_real_fresh_visibility_without_accepting(
    monkeypatch, delay, fault
):
    code = runpy.run_path(str(HELPER))
    clock = [0.0]
    monkeypatch.setattr(code["time"], "monotonic", lambda: clock[0])
    monkeypatch.setattr(
        code["time"], "sleep", lambda amount: clock.__setitem__(0, clock[0] + amount)
    )

    def read(_):
        if clock[0] < delay:
            return None
        return {
            "processId": 124 if fault == "pid" else 123,
            "fingerprint": "bad" if fault == "fingerprint" else "a" * 64,
            "visible": fault != "hidden",
            "active": False,
            "updatedAtUtc": (
                datetime.now(UTC) - timedelta(seconds=10 if fault == "stale" else 0)
            ).isoformat(),
        }

    monkeypatch.setitem(code["wait_product_window"].__globals__, "read_json", read)
    monkeypatch.setitem(
        code["wait_product_window"].__globals__,
        "write_json_atomic",
        lambda *args: pytest.fail("Readiness must not activate or dismiss the window"),
    )
    environment = {} if fault == "home" else {"HOME": "/home/test"}
    assert code["wait_product_window"](123, environment, 90) is (not fault and delay < 90)
    assert clock[0] <= 90.1
