import json
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from app.errors import WorkflowError
from app.services.automation import AutomationService
from app.services.automation_progress import OperationProgress
from app.services.common import ResultBuilder
from app.services.validation import ValidationService


def make_service(states, monkeypatch):
    service = object.__new__(AutomationService)
    service.validation = Mock()
    service.validation.parse_powershell_results = ValidationService.parse_powershell_results
    service.validation.run_windows_script.side_effect = [
        SimpleNamespace(stdout="STORAGE_ENCRYPTION_JSON=" + json.dumps(state)) for state in states
    ]
    elapsed = [0]
    monkeypatch.setattr("app.services.automation.time.monotonic", lambda: elapsed[0])
    monkeypatch.setattr(
        "app.services.automation.time.sleep",
        lambda delay: elapsed.__setitem__(0, elapsed[0] + delay),
    )
    return service, elapsed


def state(status="DecryptionInProgress", percentage=100, **changes):
    return {
        "drive": "C:",
        "status": status,
        "percentage": percentage,
        "fully_decrypted": status == "FullyDecrypted" and percentage == 0,
        **changes,
    }


def invoke(service):
    result = ResultBuilder("automation")
    service._decrypt_storage_fixture_volume(
        Mock(),
        SimpleNamespace(name="test-vm"),
        result,
        drive="C:",
        disk_device_path="system-device",
        require_system=True,
    )
    return result


def test_decryption_waits_for_explicit_zero_and_starts_only_once(monkeypatch):
    service, elapsed = make_service(
        [state(), state(percentage=0), state("FullyDecrypted", 0)], monkeypatch
    )
    result = invoke(service)
    calls = service.validation.run_windows_script.call_args_list
    assert [call.kwargs["config"]["begin"] for call in calls] == [True, False, False]
    assert all(call.kwargs["config"]["drive"] == "C:" for call in calls)
    assert all(call.kwargs["config"]["disk_device_path"] == "system-device" for call in calls)
    assert elapsed[0] == 10
    assert len(result.steps) == 3
    progress = OperationProgress(0)
    assert progress.observe(result.steps[0], 1)
    assert not progress.observe(result.steps[0], 2)
    assert progress.observe(result.steps[1], 3)
    assert progress.oldest() == ("global", 3)


@pytest.mark.parametrize(
    "invalid",
    [
        state("FullyEncrypted"),
        state("EncryptionInProgress"),
        state("DecryptionPaused"),
        state(drive="D:"),
        state(percentage=-1),
        state(percentage=101),
        state(percentage=False),
        state(fully_decrypted="true"),
        state(fully_decrypted=True),
        state("FullyDecrypted", 0, fully_decrypted=False),
        {},
        [],
    ],
)
def test_invalid_or_stopped_decryption_fails_closed(invalid, monkeypatch):
    service, _ = make_service([invalid], monkeypatch)
    with pytest.raises(WorkflowError, match="Invalid encryption status"):
        invoke(service)
    assert service.validation.run_windows_script.call_count == 1


def test_decryption_has_a_deadline_even_if_the_percentage_never_changes(monkeypatch):
    service, elapsed = make_service([state()] * 120, monkeypatch)
    with pytest.raises(WorkflowError, match="exceeded its deadline") as error:
        invoke(service)
    assert elapsed[0] == 600
    assert error.value.details["vm"] == "test-vm"
    assert service.validation.run_windows_script.call_count == 120
    assert error.value.details["inactivity_timeout_seconds"] == 600


def test_progressing_decryption_can_outlast_the_old_total_deadline(monkeypatch):
    states = [state(percentage=100 - index // 2) for index in range(200)]
    service, elapsed = make_service(states + [state("FullyDecrypted", 0)], monkeypatch)
    invoke(service)
    assert elapsed[0] == 1000
    assert service.validation.run_windows_script.call_count == 201


def test_decryption_total_deadline_is_bounded_even_with_progress(monkeypatch):
    service, elapsed = make_service(
        [state(percentage=100 - index // 20) for index in range(360)], monkeypatch
    )
    with pytest.raises(WorkflowError, match="exceeded its deadline") as error:
        invoke(service)
    assert elapsed[0] == 1800
    assert error.value.details["timeout_seconds"] == 1800
    assert service.validation.run_windows_script.call_count == 360


def test_decryption_does_not_treat_regression_as_progress(monkeypatch):
    service, _ = make_service([state(percentage=30), state(percentage=31)], monkeypatch)
    with pytest.raises(WorkflowError, match="progress regressed"):
        invoke(service)


def test_secondary_decryption_passes_the_volume_identity_on_every_poll(monkeypatch):
    service, _ = make_service(
        [state(drive="J:"), state("FullyDecrypted", 0, drive="J:")], monkeypatch
    )
    service._decrypt_storage_fixture_volume(
        Mock(),
        SimpleNamespace(name="test-vm"),
        ResultBuilder("automation"),
        drive="J:",
        disk_device_path="secondary-device",
        require_system=False,
        partition_offset=1048576,
        volume_id="secondary-volume",
    )
    for call in service.validation.run_windows_script.call_args_list:
        config = call.kwargs["config"]
        assert config["drive"] == "J:"
        assert config["disk_device_path"] == "secondary-device"
        assert config["partition_offset"] == 1048576
        assert config["volume_id"] == "secondary-volume"
        assert config["require_system"] is False
