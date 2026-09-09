import pytest
from pydantic import ValidationError

from app import main as main_module
from app.models import AutomationRequest, OperationResult

from .test_core import settings


def test_snapshot_mode_keeps_existing_requests_on_default_snapshot() -> None:
    request = AutomationRequest(apply=True, linux_password="test-password")
    assert request.snapshot_mode == "default"
    assert request.installation_target == "windows"


def test_secondary_installation_requires_explicit_snapshot_mode() -> None:
    fields = {"apply": True, "linux_password": "test-password"}
    with pytest.raises(ValidationError):
        AutomationRequest(**fields, installation_target="secondary")
    request = AutomationRequest(
        **fields, installation_target="secondary", snapshot_mode="secondary-disk"
    )
    assert request.installation_target == "secondary"
    for value in ("", "D:", "usb", None):
        with pytest.raises(ValidationError):
            AutomationRequest(**fields, installation_target=value)


def test_preference_wallpaper_keeps_custom_fixture_by_default():
    fields = {"apply": True, "linux_password": "test-password"}
    assert AutomationRequest(**fields).preference_wallpaper == "custom"
    assert AutomationRequest(
        **fields, preference_wallpaper="windows-default"
    ).preference_wallpaper == ("windows-default")
    with pytest.raises(ValidationError):
        AutomationRequest(**fields, preference_wallpaper="arbitrary-path")


@pytest.mark.parametrize("mode", ["clean3;reboot", "arbitrary-snapshot", "", None])
def test_snapshot_mode_rejects_unknown_modes(mode) -> None:
    with pytest.raises(ValidationError):
        AutomationRequest(apply=True, linux_password="test-password", snapshot_mode=mode)


def test_secondary_disk_snapshot_identifier_is_validated() -> None:
    with pytest.raises(ValidationError):
        settings(secondary_disk_reset_snapshot="clean3;reboot")


def test_secondary_disk_mode_does_not_change_later_default_runs(monkeypatch) -> None:
    configured = settings(
        reset_snapshot="existing-baseline", secondary_disk_reset_snapshot="two-disk-baseline"
    )
    observed: list[tuple[str, object]] = []

    class FakeAutomationService:
        def __init__(self, configuration):
            self.configuration = configuration

        def run(self, selectors, **kwargs):
            observed.append((self.configuration.reset_snapshot, selectors))
            assert kwargs["linux_password"] == "test-password"
            assert kwargs["preference_wallpaper"] == "windows-default"
            assert kwargs["installation_target"] == (
                "secondary"
                if self.configuration.reset_snapshot == "two-disk-baseline"
                else "windows"
            )
            return OperationResult(status="ok", operation="automation", message="test")

    monkeypatch.setattr(main_module, "AutomationService", FakeAutomationService)
    for mode in ("secondary-disk", "default", "secondary-disk", "default"):
        request = AutomationRequest(
            apply=True,
            linux_password="test-password",
            snapshot_mode=mode,
            installation_target="secondary" if mode == "secondary-disk" else "windows",
            preference_wallpaper="windows-default",
        )
        result = main_module._run_operation(configured, "automation", ["vm1"], request)
        assert result.status == "ok"
        assert configured.reset_snapshot == "existing-baseline"
    assert observed == [
        ("two-disk-baseline", ["vm1"]),
        ("existing-baseline", ["vm1"]),
        ("two-disk-baseline", ["vm1"]),
        ("existing-baseline", ["vm1"]),
    ]
