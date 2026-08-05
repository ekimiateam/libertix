import re
import subprocess
import threading
from pathlib import Path, PurePosixPath, PureWindowsPath
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

import app.services.automation as automation_module
from app.clients.ssh import CommandResult
from app.clients.vision_llm import VisionLLMClient
from app.clients.vision_models import InstallProgressVerdict
from app.clients.vnc import VNCClient
from app.config import Settings
from app.errors import WorkflowError
from app.models import ValidationRequest
from app.services.automation import AutomationOptions, AutomationService, Point
from app.services.automation_postinstall import CrossOsArtifacts
from app.services.automation_wizard import WizardAutomationMixin
from app.services.common import ResultBuilder
from app.services.reset import RESET_SNAPSHOT, ResetService
from app.services.validation import ValidationService

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_warning_acknowledgement_points_match_current_wizard_layout() -> None:
    assert Point(430, 575) == WizardAutomationMixin.BIOS_WARNING_ACKNOWLEDGEMENT
    assert Point(430, 566) == WizardAutomationMixin.UEFI_WARNING_ACKNOWLEDGEMENT


def test_vnc_text_typing_uses_vncdotool_literal_minus(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeClient:
        def __init__(self) -> None:
            self.keys: list[str] = []

        def keyPress(self, key: str) -> None:  # noqa: N802
            self.keys.append(key)

    client = FakeClient()
    monkeypatch.setattr("app.services.automation_wizard.time.sleep", lambda _seconds: None)

    WizardAutomationMixin._type_text(client, "fr-FR", "us")

    assert client.keys == ["f", "r", "minus", "F", "R"]


def test_vnc_text_typing_pretranslates_for_french_windows(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FakeClient:
        def __init__(self) -> None:
            self.keys: list[str] = []

        def keyPress(self, key: str) -> None:  # noqa: N802
            self.keys.append(key)

    client = FakeClient()
    monkeypatch.setattr("app.services.automation_wizard.time.sleep", lambda _seconds: None)

    WizardAutomationMixin._type_text(client, "test-passphrase", "fr")

    assert "".join(client.keys) == "test6pqssphrqse"


def test_vnc_select_all_releases_control_when_keypress_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FailingClient:
        def __init__(self) -> None:
            self.events: list[tuple[str, str]] = []

        def keyDown(self, key: str) -> None:  # noqa: N802
            self.events.append(("down", key))

        def keyPress(self, key: str) -> None:  # noqa: N802
            self.events.append(("press", key))
            raise RuntimeError("VNC write failed")

        def keyUp(self, key: str) -> None:  # noqa: N802
            self.events.append(("up", key))

    client = FailingClient()
    monkeypatch.setattr("app.services.automation_wizard.time.sleep", lambda _seconds: None)

    with pytest.raises(RuntimeError, match="VNC write failed"):
        WizardAutomationMixin._select_all(client)

    assert client.events == [("down", "ctrl"), ("press", "q"), ("up", "ctrl")]


def read_repo(relative_path: str) -> str:
    """Read project sources independently of pytest's working directory."""

    return (REPO_ROOT / relative_path).read_text(encoding="utf-8-sig")


def settings(**overrides: object) -> Settings:
    values = {
        "main_ssh_host": "192.168.1.208",
        "main_ssh_user": "root",
        "main_ssh_password": "secret",
        "windows_ssh_password": "secret",
        "samba_unc": r"\\192.168.1.208\smb",
        "samba_username": "admin",
        "samba_password": "secret",
        "build_vm_host": "192.168.1.138",
        "build_vm_user": "admin",
        "build_vm_password": "secret",
        "ssh_known_hosts": "/tmp/libertix-test-known-hosts",
        "filepool_base_url": "http://192.168.1.170:8000/filepool",
        "repository_url": "https://github.com/ekimiateam/libertix.git",
        "smb_root": "/root/smb",
        "llm_api_url": "http://192.168.1.247:8000/v1",
        "llm_api_key": "secret",
        "llm_model": "Qwen3.6-35B-A3B-Thinking",
        "proxmox_url": "https://192.168.1.166:8006",
        "proxmox_token_id": "root@pam!eki",
        "proxmox_token_secret": "secret",
        "api_access_token": "secret",
        "vms": (
            {
                "name": "vm1",
                "host": "192.168.1.240",
                "os": "Windows 10 BIOS",
                "vnc": "192.168.1.166:10",
                "screen_width": 1024,
                "screen_height": 768,
                "vmid": 500,
                "firmware": "bios",
                "automation_enabled": True,
            },
            {
                "name": "vm2",
                "host": "192.168.1.241",
                "os": "Windows 10 UEFI",
                "vnc": "192.168.1.166:11",
                "screen_width": 1280,
                "screen_height": 800,
                "vmid": 501,
                "firmware": "uefi",
                "disable_defender_for_automation": True,
                "automation_enabled": True,
            },
            {
                "name": "vm3",
                "host": "192.168.1.242",
                "os": "Windows 11 UEFI",
                "vnc": "192.168.1.166:12",
                "screen_width": 1280,
                "screen_height": 800,
                "vmid": 502,
                "firmware": "uefi",
                "automation_enabled": True,
            },
        ),
        "_env_file": None,
    }
    values.update(overrides)
    return Settings(**values)


def apply_changes_source() -> str:
    """Return all files that form the ApplyChanges partial class."""

    return "\n".join(
        path.read_text(encoding="utf-8-sig")
        for path in sorted((REPO_ROOT / "Pages").glob("ApplyChanges*.cs"))
    )


def test_share_path_translation() -> None:
    service = ValidationService(settings())
    actual = service.to_windows_share_path(
        PurePosixPath("/root/smb/Libertix-release/folder/Libertix.exe")
    )
    assert actual == PureWindowsPath("Z:/Libertix-release/folder/Libertix.exe")


def test_smb_root_is_strictly_guarded() -> None:
    with pytest.raises(ValidationError):
        settings(smb_root="/")


@pytest.mark.parametrize(
    "url",
    [
        "ftp://192.168.1.170/filepool",
        "http://user:password@192.168.1.170/filepool",
        "http://192.168.1.170/filepool?token=secret",
        "http://192.168.1.170/filepool#fragment",
    ],
)
def test_filepool_base_url_rejects_unsafe_values(url: str) -> None:
    with pytest.raises(ValidationError):
        settings(filepool_base_url=url)


def test_reset_scope_is_exact() -> None:
    assert ResetService(settings())._selected_vmids(None) == (500, 501, 502)  # noqa: SLF001
    assert RESET_SNAPSHOT == "clean2"


def test_reset_selector_uses_configured_vm_names() -> None:
    service = ResetService(settings())

    assert service._selected_vmids(["vm3", "win11-uefi", "502"]) == (502,)  # noqa: SLF001


def test_reset_selector_does_not_depend_on_vm_order() -> None:
    configured = settings().vms
    service = ResetService(settings(vms=tuple(reversed(configured))))

    assert service._selected_vmids(["vm1", "vm3"]) == (500, 502)  # noqa: SLF001


def test_result_builder_cannot_report_success_after_failure() -> None:
    result = ResultBuilder("automation")
    result.failure(WorkflowError("test.failure", "fatal"))

    final = result.success("must not become successful")

    assert final.status == "error"
    assert final.steps[-1].step == "test.failure"


def test_reset_restores_selected_vms_in_parallel(monkeypatch: pytest.MonkeyPatch) -> None:
    selected = (500, 501, 502)
    entered: set[int] = set()
    max_active = 0
    condition = threading.Condition()

    class FakeProxmox:
        def __init__(self, *_args: object, **_kwargs: object) -> None:
            pass

        def __enter__(self) -> "FakeProxmox":
            return self

        def __exit__(self, *_args: object) -> None:
            pass

        def rollback(self, _node: str, vmid: int, _snapshot: str) -> None:
            nonlocal max_active
            with condition:
                entered.add(vmid)
                max_active = max(max_active, len(entered))
                condition.notify_all()
                condition.wait_for(lambda: len(entered) == len(selected), timeout=2)

    monkeypatch.setattr("app.services.reset.ProxmoxClient", FakeProxmox)
    service = ResetService(settings())
    result = ResultBuilder("reset")

    service._restore_snapshots(  # noqa: SLF001
        {vmid: "node-a" for vmid in selected},
        selected,
        result,
    )

    assert entered == set(selected)
    assert max_active == len(selected)
    assert sorted(step.context["target"] for step in result.steps) == ["500", "501", "502"]


def test_local_source_copy_excludes_env_files(tmp_path: Path) -> None:
    root = tmp_path
    allowed = root / "auto_tests" / ".env.example"
    allowed_aria2 = root / "Tools" / "aria2" / "aria2c.exe"
    blocked_env = root / "auto_tests" / ".env"
    blocked_named_env = root / "auto_tests" / ".env.local"
    blocked_filepool = root / "auto_tests" / "app" / "filepool" / "mint.iso"
    blocked_other_exe = root / "bin" / "Release" / "Libertix.exe"

    for path in (
        allowed,
        allowed_aria2,
        blocked_env,
        blocked_named_env,
        blocked_filepool,
        blocked_other_exe,
    ):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x", encoding="utf-8")

    assert ValidationService._include_local_source_path(root, allowed) is True  # noqa: SLF001
    assert ValidationService._include_local_source_path(root, allowed_aria2) is True  # noqa: SLF001
    assert ValidationService._include_local_source_path(root, blocked_env) is False  # noqa: SLF001
    assert ValidationService._include_local_source_path(root, blocked_named_env) is False  # noqa: SLF001
    assert ValidationService._include_local_source_path(root, blocked_filepool) is False  # noqa: SLF001
    assert ValidationService._include_local_source_path(root, blocked_other_exe) is False  # noqa: SLF001


def test_vnc_display_is_converted_to_tcp_port() -> None:
    assert VNCClient._vncdotool_address("192.168.1.166:10") == "192.168.1.166::5910"


def test_absolute_vnc_click_is_not_scaled() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    events: list[tuple[str, int, int] | tuple[str, int]] = []
    client = SimpleNamespace(
        mouseMove=lambda x, y: events.append(("move", x, y)),
        mousePress=lambda button: events.append(("press", button)),
    )

    service._click_absolute(client, vm, Point(1045, 643), 0)  # noqa: SLF001

    assert events == [("move", 1045, 643), ("press", 1)]
    with pytest.raises(WorkflowError, match="hors écran"):
        service._click_absolute(client, vm, Point(1280, 643), 0)  # noqa: SLF001


def test_sharing_page_uses_its_own_scaled_next_button(monkeypatch: pytest.MonkeyPatch) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    events: list[tuple[str, int, int] | tuple[str, int]] = []
    client = SimpleNamespace(
        mouseMove=lambda x, y: events.append(("move", x, y)),
        mousePress=lambda button: events.append(("press", button)),
    )
    screens = iter(("sharing", "account"))
    monotonic_values = iter((0.0, 0.0, 400.0, 350.0))

    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(automation_module.time, "monotonic", lambda: next(monotonic_values))
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("sharing-navigation.png"),
    )
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: SimpleNamespace(  # type: ignore[method-assign]
        detected_screen=next(screens),
        expected_screen_visible=False,
        no_blocking_error=True,
        summary="test",
        visible_text="",
    )

    service._navigate_to_account(  # noqa: SLF001
        client,
        vm,
        welcome_point=Point(512, 432),
        distro_point=Point(220, 389),
        next_point=Point(838, 614),
        sharing_point=Point(822, 579),
        username="test",
        result=ResultBuilder("automation"),
    )

    assert events == [("move", 1028, 603), ("press", 1)]


def test_account_password_fields_are_rewritten_after_wpf_validation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    writes: list[tuple[Point, str]] = []

    monkeypatch.setattr(
        service,
        "_fill_field",
        lambda _client, _vm, point, text: writes.append((point, text)),
    )

    service._fill_account_fields(  # noqa: SLF001
        object(),
        vm,
        username_point=Point(512, 220),
        password_point=Point(512, 333),
        confirmation_point=Point(512, 445),
        username="test",
        password="secret",
    )

    assert writes == [
        (Point(512, 220), "test"),
        (Point(512, 333), "secret"),
        (Point(512, 445), "secret"),
        (Point(512, 333), "secret"),
        (Point(512, 445), "secret"),
    ]


def test_navigation_closes_windows_security_after_defender_preparation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    events: list[tuple[str, str]] = []
    client = SimpleNamespace(
        keyDown=lambda key: events.append(("down", key)),
        keyPress=lambda key: events.append(("press", key)),
        keyUp=lambda key: events.append(("up", key)),
    )
    screens = iter(
        (
            ("other", "Protection contre les virus et menaces"),
            ("account", "Créez votre compte Linux"),
        )
    )

    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("windows-security-navigation.png"),
    )

    def analyze(*_args: object, **_kwargs: object) -> SimpleNamespace:
        screen, visible_text = next(screens)
        return SimpleNamespace(
            detected_screen=screen,
            expected_screen_visible=False,
            no_blocking_error=True,
            summary="test",
            visible_text=visible_text,
        )

    service.vision_llm.analyze_wizard_state = analyze  # type: ignore[method-assign]
    service._navigate_to_account(  # noqa: SLF001
        client,
        vm,
        welcome_point=Point(512, 432),
        distro_point=Point(220, 389),
        next_point=Point(838, 614),
        sharing_point=Point(822, 579),
        username="test",
        result=ResultBuilder("automation"),
    )

    assert events == [("down", "alt"), ("press", "f4"), ("up", "alt")]


def test_navigation_retries_invalid_llm_verdict_without_clicking(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    events: list[tuple[str, int, int] | tuple[str, int]] = []
    client = SimpleNamespace(
        mouseMove=lambda x, y: events.append(("move", x, y)),
        mousePress=lambda button: events.append(("press", button)),
    )
    calls = 0

    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("wizard-retry.png"),
    )

    def analyze(*_args: object, **_kwargs: object) -> SimpleNamespace:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise WorkflowError("llm.wizard_state", "No complete wizard verdict")
        return SimpleNamespace(
            detected_screen="account",
            expected_screen_visible=True,
            no_blocking_error=True,
            summary="test",
            visible_text="Créez votre compte Linux",
        )

    service.vision_llm.analyze_wizard_state = analyze  # type: ignore[method-assign]
    result = ResultBuilder("automation")
    service._navigate_to_account(  # noqa: SLF001
        client,
        vm,
        welcome_point=Point(512, 432),
        distro_point=Point(220, 389),
        next_point=Point(838, 614),
        sharing_point=Point(899, 588),
        username="test",
        result=result,
    )

    assert calls == 2
    assert events == []
    assert result.steps[-1].step == "automation.wizard_vision_retry"


def test_navigation_accepts_compatibility_progress_without_false_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    events: list[tuple[str, int, int] | tuple[str, int]] = []
    client = SimpleNamespace(
        mouseMove=lambda x, y: events.append(("move", x, y)),
        mousePress=lambda button: events.append(("press", button)),
    )

    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("compatibility-progress.png"),
    )
    verdicts = iter(
        [
            SimpleNamespace(
                detected_screen="compatibility",
                expected_screen_visible=False,
                no_blocking_error=False,
                summary="Compatibility checks are in progress",
                visible_text="Vérification de la machine en cours... Continuer",
            ),
            SimpleNamespace(
                detected_screen="compatibility",
                expected_screen_visible=False,
                no_blocking_error=True,
                summary="Machine compatible",
                visible_text="PREFLIGHT_OK=true Continuer",
            ),
            *[
                SimpleNamespace(
                    detected_screen=screen,
                    expected_screen_visible=False,
                    no_blocking_error=True,
                    summary=screen,
                    visible_text=screen,
                )
                for screen in ("distro", "resize", "sharing", "account")
            ],
        ]
    )
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: next(verdicts)  # type: ignore[method-assign]

    result = ResultBuilder("automation")
    service._navigate_to_account(  # noqa: SLF001
        client,
        vm,
        welcome_point=Point(512, 432),
        distro_point=Point(220, 389),
        next_point=Point(838, 614),
        sharing_point=Point(822, 579),
        username="test",
        result=result,
    )

    assert len([event for event in events if event[0] == "press"]) == 5
    assert any(step.step == "automation.compatibility_wait" for step in result.steps)


def test_wizard_screen_uses_visible_title_when_model_returns_other() -> None:
    verdict = VisionLLMClient._load_wizard_json(  # noqa: SLF001
        '{"detected_screen":"other","visible_text":"Choisissez votre version de Linux !",'
        '"expected_screen_visible":false,"no_blocking_error":true,'
        '"username_visible":false,"password_fields_filled":false,"summary":"selection"}'
    )

    assert verdict["detected_screen"] == "distro"


def test_navigation_ignores_desktop_weather_warning_on_distro(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    events: list[tuple[str, int, int] | tuple[str, int]] = []
    client = SimpleNamespace(
        mouseMove=lambda x, y: events.append(("move", x, y)),
        mousePress=lambda button: events.append(("press", button)),
    )
    screens = iter(
        (
            ("distro", False, "Choisissez votre version de Linux ! Avertissement d'orage"),
            ("account", True, "Créez votre compte Linux"),
        )
    )
    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("weather-warning.png"),
    )

    def analyze(*_args: object, **_kwargs: object) -> SimpleNamespace:
        screen, no_error, text = next(screens)
        return SimpleNamespace(
            detected_screen=screen,
            expected_screen_visible=False,
            no_blocking_error=no_error,
            summary=screen,
            visible_text=text,
        )

    service.vision_llm.analyze_wizard_state = analyze  # type: ignore[method-assign]
    service._navigate_to_account(  # noqa: SLF001
        client,
        vm,
        welcome_point=Point(512, 432),
        distro_point=Point(220, 389),
        next_point=Point(838, 614),
        sharing_point=Point(822, 579),
        username="test",
        result=ResultBuilder("automation"),
    )

    assert len([event for event in events if event[0] == "press"]) == 2


def test_validation_source_defaults_to_local() -> None:
    assert ValidationRequest().source == "local"


def test_validation_source_accepts_local() -> None:
    assert ValidationRequest(source="local").source == "local"


def test_validation_vm_selector_accepts_aliases() -> None:
    service = ValidationService(settings())

    selected = service.select_vms(["10 uefi"])

    assert [vm.name for vm in selected] == ["vm2"]


def test_validation_vm_selector_rejects_unknown() -> None:
    service = ValidationService(settings())

    with pytest.raises(Exception, match="Sélecteur VM inconnu"):
        service.select_vms(["not-a-vm"])


def test_launch_interactive_uses_elevated_scheduled_task(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeSshContext:
        def __enter__(self) -> object:
            return object()

        def __exit__(self, *_args: object) -> None:
            return None

    service = ValidationService(settings())

    def fake_run_windows_script(
        *_args: object, script_name: str, step: str, **_kwargs: object
    ) -> object:
        assert script_name == "launch_libertix_elevated.ps1"
        assert step == "vm.launch_elevated"
        return SimpleNamespace(
            stdout=(
                "PID=1234\nSESSION_ID=2\nTASK_NAME=LibertixValidation_vm1\n"
                "EXECUTABLE=Z:\\Libertix-release\\Libertix.exe\n"
            )
        )

    monkeypatch.setattr(service, "ssh", lambda *_args, **_kwargs: FakeSshContext())
    monkeypatch.setattr(service, "run_windows_script", fake_run_windows_script)
    vm = service.select_vms(["vm1"])[0]
    result = ResultBuilder("validation")
    launch = service._launch_interactive(  # noqa: SLF001
        vm,
        PureWindowsPath("Z:/Libertix-release/Libertix.exe"),
        result,
    )

    assert launch["pid"] == 1234
    assert launch["session_id"] == 2
    assert launch["window_handle"] == 0
    assert launch["launch_method"] == "scheduled_task_elevated"


def test_automation_launch_passes_the_windows_address_to_the_dev_ssh_option(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FakeSshContext:
        def __enter__(self) -> object:
            return object()

        def __exit__(self, *_args: object) -> None:
            return None

    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]

    def fake_run_windows_script(
        *_args: object,
        script_name: str,
        config: dict[str, object],
        step: str,
        **_kwargs: object,
    ) -> object:
        assert script_name == "launch_libertix_elevated.ps1"
        assert step == "automation.launch_elevated"
        assert config["development_static_ipv4"] == vm.host
        return SimpleNamespace(
            stdout=(
                "PID=1234\nSESSION_ID=2\nTASK_NAME=LibertixAutoInstall_vm1\n"
                "EXECUTABLE=Z:\\Libertix-release\\Libertix.exe\n"
            )
        )

    monkeypatch.setattr(service.validation, "ssh", lambda *_args, **_kwargs: FakeSshContext())
    monkeypatch.setattr(service.validation, "run_windows_script", fake_run_windows_script)

    launch = service._launch_elevated(  # noqa: SLF001
        vm,
        PureWindowsPath("Z:/Libertix-release/Libertix.exe"),
    )

    assert launch["pid"] == 1234
    assert launch["session_id"] == 2


def test_automation_scope_accepts_vm500() -> None:
    service = AutomationService(settings())
    selected = service.validation.select_vms(["vm1"])

    service._assert_autoclick_scope(selected, ["vm1"])  # noqa: SLF001


def test_automation_scope_accepts_vm502_uefi() -> None:
    service = AutomationService(settings())
    selected = service.validation.select_vms(["vm3"])

    service._assert_autoclick_scope(selected, ["vm3"])  # noqa: SLF001


def test_automation_scope_accepts_vm501_uefi() -> None:
    service = AutomationService(settings())
    selected = service.validation.select_vms(["vm2"])

    service._assert_autoclick_scope(selected, ["vm2"])  # noqa: SLF001


def test_automation_scope_accepts_all_validated_vms() -> None:
    service = AutomationService(settings())
    selected = service.validation.select_vms(["vm1", "vm2", "vm3"])

    profiles = service._automation_profiles(selected, ["vm1", "vm2", "vm3"])  # noqa: SLF001

    assert {name: profile.vmid for name, profile in profiles.items()} == {
        "vm1": 500,
        "vm2": 501,
        "vm3": 502,
    }


def test_automation_refuses_vm_already_in_io_error() -> None:
    class FakeProxmox:
        def _request(self, _method: str, _path: str, *, step: str) -> object:
            assert step == "automation.vm_status"
            return {"status": "running", "qmpstatus": "io-error"}

    service = AutomationService(settings())

    with pytest.raises(WorkflowError, match="io-error"):
        service._assert_vm_not_in_io_error(  # noqa: SLF001
            FakeProxmox(), "node-a", 500, ResultBuilder("automation")
        )


def test_automation_refuses_low_local_lvm_headroom() -> None:
    class FakeProxmox:
        def _request(self, _method: str, _path: str, *, step: str) -> object:
            assert step == "automation.storage"
            return {"total": 100 * 1024**3, "used": 95 * 1024**3, "avail": 5 * 1024**3}

    service = AutomationService(settings())

    with pytest.raises(WorkflowError, match="local-lvm insuffisante"):
        service._assert_proxmox_storage_headroom(  # noqa: SLF001
            FakeProxmox(),
            {500: "node-a", 501: "node-a", 502: "node-a"},
            3,
            ResultBuilder("automation"),
        )


def test_automation_reports_local_lvm_headroom() -> None:
    class FakeProxmox:
        def _request(self, _method: str, _path: str, *, step: str) -> object:
            assert step == "automation.storage"
            return {"total": 100 * 1024**3, "used": 30 * 1024**3, "avail": 70 * 1024**3}

    service = AutomationService(settings())
    result = ResultBuilder("automation")

    service._assert_proxmox_storage_headroom(  # noqa: SLF001
        FakeProxmox(), {500: "node-a", 501: "node-a", 502: "node-a"}, 3, result
    )

    assert result.steps[-1].step == "automation.storage_headroom"
    assert result.steps[-1].context["available_gib"] == 70
    assert result.steps[-1].context["required_gib"] == 60


@pytest.mark.parametrize(
    ("prepared", "realtime", "exclusion", "expected"),
    (
        ("realtime-disabled", "false", r"C:\release", True),
        ("exclusion-only", "true", r"C:\release", True),
        ("realtime-disabled", "true", r"C:\release", False),
        ("true", "false", r"C:\release", False),
        ("exclusion-only", "true", "", False),
    ),
)
def test_defender_preparation_contract(
    prepared: str, realtime: str, exclusion: str, expected: bool
) -> None:
    assert (
        AutomationService._defender_preparation_is_valid(  # noqa: SLF001
            prepared, realtime, exclusion
        )
        is expected
    )


def test_apply_requires_visual_monitoring() -> None:
    result = AutomationService(settings()).run(
        ["vm1"],
        apply=True,
        linux_username="test",
        linux_password="test",
        monitor_iso=False,
        source="local",
    )

    assert result.status == "error"
    assert result.steps[-1].step == "automation.monitor_required"


def test_wizard_account_guard_is_fail_closed(tmp_path: Path) -> None:
    service = AutomationService(settings())
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: SimpleNamespace(  # type: ignore[method-assign]
        detected_screen="account",
        expected_screen_visible=True,
        no_blocking_error=True,
        username_visible=False,
        password_fields_filled=False,
        visible_text="Créez votre compte Linux utilisateur Mot de passe",
        model_dump=lambda: {},
    )
    vm = service.validation.select_vms(["vm1"])[0]

    with pytest.raises(WorkflowError, match="Apply est bloqué"):
        service._assert_wizard_state(  # noqa: SLF001
            tmp_path / "account.png",
            vm,
            expected_screen="account",
            expected_username="test",
            result=ResultBuilder("automation"),
        )


def test_wizard_account_guard_accepts_explicit_visible_text(tmp_path: Path) -> None:
    service = AutomationService(settings())
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: SimpleNamespace(  # type: ignore[method-assign]
        detected_screen="account",
        expected_screen_visible=True,
        no_blocking_error=True,
        username_visible=False,
        password_fields_filled=False,
        visible_text=(
            "Créez votre compte Linux test Mot de passe •••• Confirmer le mot de passe ••••"
        ),
        model_dump=lambda: {},
    )
    vm = service.validation.select_vms(["vm1"])[0]

    service._assert_wizard_state(  # noqa: SLF001
        tmp_path / "account.png",
        vm,
        expected_screen="account",
        expected_username="test",
        result=ResultBuilder("automation"),
    )


def test_automation_scope_rejects_unvalidated_vm() -> None:
    service = AutomationService(
        settings(
            vms=(
                {
                    "name": "vm1",
                    "host": "192.168.1.240",
                    "os": "Windows 10 BIOS",
                    "vnc": "192.168.1.166:10",
                    "screen_width": 1024,
                    "screen_height": 768,
                    "vmid": 500,
                    "firmware": "bios",
                    "automation_enabled": True,
                },
                {
                    "name": "vm4",
                    "host": "192.168.1.244",
                    "os": "Windows experimental",
                    "vnc": "192.168.1.166:14",
                    "screen_width": 1024,
                    "screen_height": 768,
                    "vmid": 501,
                    "firmware": "uefi",
                    "automation_enabled": False,
                },
            )
        )
    )
    selected = service.validation.select_vms(["vm1", "vm4"])

    with pytest.raises(Exception, match="Auto-click Libertix refusé"):
        service._assert_autoclick_scope(selected, ["vm1", "vm4"])  # noqa: SLF001


def test_automation_logs_vm500_reset_before_ui(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[str, object, object | None]] = []

    class FakeProxmox:
        def __init__(self, *_args: object, **_kwargs: object) -> None:
            pass

        def __enter__(self) -> "FakeProxmox":
            return self

        def __exit__(self, *_args: object) -> None:
            pass

        def locate_vm(self, vmid: int) -> str:
            calls.append(("locate", vmid, None))
            return "node-a"

        def assert_snapshot(self, node: str, vmid: int, snapshot: str) -> None:
            calls.append(("assert", vmid, snapshot))

        def rollback(self, node: str, vmid: int, snapshot: str) -> None:
            calls.append(("rollback", vmid, snapshot))

    monkeypatch.setattr(automation_module, "ProxmoxClient", FakeProxmox)
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None

    result = ResultBuilder("automation")
    service._restore_clean_snapshot(result, profile)  # noqa: SLF001

    assert calls == [
        ("locate", 500, None),
        ("assert", 500, RESET_SNAPSHOT),
        ("rollback", 500, RESET_SNAPSHOT),
    ]
    assert result.steps[-1].step == "automation.reset_vm_done"
    assert "Reset VM500 terminé" in result.steps[-1].message


def test_automation_logs_vm502_reset_for_uefi(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[str, object, object | None]] = []

    class FakeProxmox:
        def __init__(self, *_args: object, **_kwargs: object) -> None:
            pass

        def __enter__(self) -> "FakeProxmox":
            return self

        def __exit__(self, *_args: object) -> None:
            pass

        def locate_vm(self, vmid: int) -> str:
            calls.append(("locate", vmid, None))
            return "node-a"

        def assert_snapshot(self, node: str, vmid: int, snapshot: str) -> None:
            calls.append(("assert", vmid, snapshot))

        def rollback(self, node: str, vmid: int, snapshot: str) -> None:
            calls.append(("rollback", vmid, snapshot))

    monkeypatch.setattr(automation_module, "ProxmoxClient", FakeProxmox)
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None

    result = ResultBuilder("automation")
    service._restore_clean_snapshot(result, profile)  # noqa: SLF001

    assert calls == [
        ("locate", 502, None),
        ("assert", 502, RESET_SNAPSHOT),
        ("rollback", 502, RESET_SNAPSHOT),
    ]
    assert result.steps[-1].step == "automation.reset_vm_done"
    assert "Reset VM502 terminé" in result.steps[-1].message


def test_automation_logs_vm501_reset_for_uefi(monkeypatch: pytest.MonkeyPatch) -> None:
    calls: list[tuple[str, object, object | None]] = []

    class FakeProxmox:
        def __init__(self, *_args: object, **_kwargs: object) -> None:
            pass

        def __enter__(self) -> "FakeProxmox":
            return self

        def __exit__(self, *_args: object) -> None:
            pass

        def locate_vm(self, vmid: int) -> str:
            calls.append(("locate", vmid, None))
            return "node-a"

        def assert_snapshot(self, node: str, vmid: int, snapshot: str) -> None:
            calls.append(("assert", vmid, snapshot))

        def rollback(self, node: str, vmid: int, snapshot: str) -> None:
            calls.append(("rollback", vmid, snapshot))

    monkeypatch.setattr(automation_module, "ProxmoxClient", FakeProxmox)
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None

    result = ResultBuilder("automation")
    service._restore_clean_snapshot(result, profile)  # noqa: SLF001

    assert calls == [
        ("locate", 501, None),
        ("assert", 501, RESET_SNAPSHOT),
        ("rollback", 501, RESET_SNAPSHOT),
    ]
    assert result.steps[-1].step == "automation.reset_vm_done"
    assert "Reset VM501 terminé" in result.steps[-1].message


def test_automation_apply_false_only_launches_ui(monkeypatch: pytest.MonkeyPatch, tmp_path) -> None:
    class FakeClient:
        def __init__(self) -> None:
            self.clicks = 0
            self.keys = 0
            self.disconnected = False

        def captureScreen(self, path: str) -> None:
            Path(path).write_bytes(b"fake-png")

        def mouseMove(self, _x: int, _y: int) -> None:
            pass

        def mousePress(self, _button: int) -> None:
            self.clicks += 1

        def keyPress(self, _key: str) -> None:
            self.keys += 1

        def disconnect(self) -> None:
            self.disconnected = True

    fake_client = FakeClient()
    monkeypatch.setattr(automation_module.api, "connect", lambda _address: fake_client)
    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    service = AutomationService(settings(capture_dir=tmp_path))
    vm = service.validation.select_vms(["vm1"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None
    result = ResultBuilder("automation")

    service._click_wizard(  # noqa: SLF001
        vm,
        AutomationOptions(
            apply=False, linux_username="test", linux_password="linux", monitor_iso=True
        ),
        profile,
        result,
    )

    assert fake_client.clicks == 0
    assert fake_client.keys == 0
    assert fake_client.disconnected is True
    assert [step.step for step in result.steps] == [
        "automation.capture",
        "automation.launch_only_stop",
    ]
    assert result.steps[0].context["label"] == "00-welcome"


def test_automation_run_removes_temporary_capture_workspace(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    service = AutomationService(settings(capture_dir=tmp_path))
    vm = service.validation.select_vms(["vm1"])[0]

    monkeypatch.setattr(service.validation, "select_vms", lambda _selectors: (vm,))
    monkeypatch.setattr(service, "_restore_clean_snapshots", lambda _result, _profiles: None)
    monkeypatch.setattr(
        service.validation,
        "prepare_server",
        lambda _result, source: PurePosixPath("/root/smb/Libertix-release/Libertix.exe"),
    )

    def fake_run_vm(*_args, **_kwargs):
        (service._capture_dir / "proof.png").write_bytes(b"capture")  # noqa: SLF001
        return ResultBuilder("automation").success("ok")

    monkeypatch.setattr(service, "_run_vm_isolated", fake_run_vm)

    result = service.run(
        ["vm1"],
        apply=False,
        linux_username="test",
        linux_password="test",
        monitor_iso=True,
        source="local",
    )

    assert result.status == "ok"
    assert list(tmp_path.iterdir()) == []


def test_validation_run_removes_temporary_capture_workspace(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    service = ValidationService(settings(capture_dir=tmp_path))
    vm = service.select_vms(["vm1"])[0]

    monkeypatch.setattr(service, "select_vms", lambda _selectors: (vm,))
    monkeypatch.setattr(
        service,
        "prepare_server",
        lambda _result, source: PurePosixPath("/root/smb/Libertix-release/Libertix.exe"),
    )

    def fake_validate_vm(*_args, **_kwargs):
        (service._capture_dir / "proof.png").write_bytes(b"capture")  # noqa: SLF001
        return ResultBuilder("validation").success("ok")

    monkeypatch.setattr(service, "_validate_vm_isolated", fake_validate_vm)

    result = service.run(["vm1"], source="local")

    assert result.status == "ok"
    assert list(tmp_path.iterdir()) == []


def test_automation_monitor_stops_only_on_the_installed_boot_menu() -> None:
    service = AutomationService(settings())

    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Downloading Mint ISO... 60% Windows desktop with Libertix wizard",
        )
        is False
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Gestionnaire de démarrage Windows; no Libertix installer visible",
        )
        is False
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Appliquer les modifications Creating UEFI installer partition "
            "C:\\LibertixTools\\downloads\\mint.iso",
        )
        is False
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Appliquer les modifications Copying UEFI installer... "
            "Mounting ISO... Copying ISO contents to X:... Libertix UEFI installer copied.",
        )
        is False
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "vmlinuz initrd squashfs",
        )
        is False
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Installation automatique Code: 120-unsquashfs F12: mode terminal",
        )
        is False
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Code: 130-target-system-config Configuration du système installé (76%)",
        )
        is False
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Linux Mint GNU/Linux  Windows Boot Manager  Shutdown  Advanced options",
        )
        is True
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Linux Mint GNU/Linux\nWindows\nShutdown\nAdvanced options",
        )
        is True
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Linux Mint GNU/Linux\nWindows\nAdvanced options",
        )
        is False
    )


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
def test_automation_monitor_stops_when_mint_desktop_is_seen_after_reboot(
    monkeypatch: pytest.MonkeyPatch,
    firmware: str,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    verdicts = iter(
        (
            InstallProgressVerdict(
                iso_download_finished=True,
                installation_finished=True,
                reboot_prompt_visible=True,
                still_in_progress=False,
                error_visible=False,
                summary="Préparation UEFI terminée, bouton Redémarrer visible.",
                visible_text="Libertix 100% Redémarrer",
            ),
            InstallProgressVerdict(
                iso_download_finished=False,
                installation_finished=False,
                reboot_prompt_visible=False,
                still_in_progress=True,
                error_visible=False,
                summary="Configuration du système installé à 76 %.",
                visible_text="Code: 130-target-system-config 76%",
            ),
            InstallProgressVerdict(
                iso_download_finished=True,
                installation_finished=True,
                reboot_prompt_visible=False,
                still_in_progress=False,
                error_visible=False,
                summary="Bureau Linux Mint opérationnel après installation.",
                visible_text="Bienvenue à Linux Mint 22.3 Cinnamon",
            ),
        )
    )
    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"/tmp/{label}.png"),
    )
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda _capture, _name, _os: next(verdicts),
    )
    reboot_clicks: list[str] = []
    monkeypatch.setattr(
        service,
        "_click_reboot_after_preparation",
        lambda selected_vm, _result: reboot_clicks.append(selected_vm.name),
    )
    result = ResultBuilder("automation")

    service._monitor_until_live_boot(vm, result, firmware)  # type: ignore[arg-type]  # noqa: SLF001

    assert reboot_clicks == ["vm3"]
    assert (
        len([step for step in result.steps if step.step == "automation.monitor_installation"]) == 3
    )
    assert result.steps[-1].step == "automation.installation_finished"


def test_automation_monitor_labels_final_grub_menu_before_generic_finished_flag(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    verdicts = iter(
        (
            InstallProgressVerdict(
                iso_download_finished=True,
                installation_finished=True,
                reboot_prompt_visible=True,
                still_in_progress=False,
                error_visible=False,
                summary="Windows preparation is complete.",
                visible_text="Libertix 100% Redémarrer",
            ),
            InstallProgressVerdict(
                iso_download_finished=True,
                installation_finished=True,
                reboot_prompt_visible=False,
                still_in_progress=False,
                error_visible=False,
                summary="The installed boot menu is visible.",
                visible_text=("Linux Mint GNU/Linux\nWindows\nShutdown\nAdvanced options"),
            ),
        )
    )
    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"/tmp/{label}.png"),
    )
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda _capture, _name, _os: next(verdicts),
    )
    monkeypatch.setattr(service, "_click_reboot_after_preparation", lambda _vm, _result: None)
    result = ResultBuilder("automation")

    outcome = service._monitor_until_live_boot(vm, result, "bios")  # noqa: SLF001

    assert outcome == "boot-menu"
    assert result.steps[-1].step == "automation.installed_boot_menu_seen"


def test_automation_monitor_keeps_waiting_during_inactive_reboot_display(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    verdicts = iter(
        (
            InstallProgressVerdict(
                iso_download_finished=True,
                installation_finished=True,
                reboot_prompt_visible=True,
                still_in_progress=False,
                error_visible=False,
                summary="Windows preparation is complete.",
                visible_text="Libertix 100% Redémarrer",
            ),
            InstallProgressVerdict(
                iso_download_finished=False,
                installation_finished=False,
                reboot_prompt_visible=False,
                still_in_progress=False,
                error_visible=True,
                summary="The VM display is inactive, so installation status cannot be determined.",
                visible_text="Display output is not active.",
            ),
            InstallProgressVerdict(
                iso_download_finished=True,
                installation_finished=False,
                reboot_prompt_visible=False,
                still_in_progress=False,
                error_visible=False,
                summary="The installed boot menu is visible.",
                visible_text=(
                    "Linux Mint GNU/Linux\nWindows Boot Manager\nShutdown\nAdvanced options"
                ),
            ),
        )
    )
    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"/tmp/{label}.png"),
    )
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda _capture, _name, _os: next(verdicts),
    )
    monkeypatch.setattr(service, "_click_reboot_after_preparation", lambda _vm, _result: None)
    result = ResultBuilder("automation")

    service._monitor_until_live_boot(vm, result, "uefi")  # noqa: SLF001

    assert any(step.step == "automation.display_transition" for step in result.steps)
    assert result.steps[-1].step == "automation.installed_boot_menu_seen"


def test_automation_monitor_waits_for_the_final_rollback_verdict(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    verdicts = iter(
        (
            InstallProgressVerdict(
                iso_download_finished=False,
                installation_finished=False,
                reboot_prompt_visible=False,
                still_in_progress=True,
                error_visible=True,
                summary="Preparation failed; rollback is running.",
                visible_text="Error detected. Restoring Windows... 0%",
            ),
            InstallProgressVerdict(
                iso_download_finished=False,
                installation_finished=False,
                reboot_prompt_visible=False,
                still_in_progress=False,
                error_visible=True,
                summary="The preparation failed after recovery completed.",
                visible_text="Preparation failed. Windows has been restored.",
            ),
        )
    )
    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"/tmp/{label}.png"),
    )
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda _capture, _name, _os: next(verdicts),
    )
    result = ResultBuilder("automation")

    with pytest.raises(WorkflowError) as raised:
        service._monitor_until_live_boot(vm, result, "bios")  # noqa: SLF001

    assert raised.value.details["rollback_outcome"] == "verified"
    assert "rollback vérifié" in raised.value.message
    assert (
        len([step for step in result.steps if step.step == "automation.monitor_installation"]) == 2
    )
    assert any(step.step == "automation.rollback_in_progress" for step in result.steps)
    assert (
        service._rollback_terminal_outcome(  # noqa: SLF001
            "Rollback Windows terminé et vérifié."
        )
        == "verified"
    )


def test_automation_monitor_reports_an_incomplete_rollback_immediately(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    verdict = InstallProgressVerdict(
        iso_download_finished=False,
        installation_finished=False,
        reboot_prompt_visible=False,
        still_in_progress=False,
        error_visible=True,
        summary="Manual intervention is required.",
        visible_text="Rollback incomplete. Manual intervention is required.",
    )
    monkeypatch.setattr(automation_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"/tmp/{label}.png"),
    )
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda _capture, _name, _os: verdict,
    )
    result = ResultBuilder("automation")

    with pytest.raises(WorkflowError) as raised:
        service._monitor_until_live_boot(vm, result, "bios")  # noqa: SLF001

    assert raised.value.details["rollback_outcome"] == "incomplete"
    assert "rollback incomplet" in raised.value.message


def test_bios_final_grub_waits_for_manual_selection() -> None:
    grub_defaults = read_repo("assets/live/configure-target-main.sh")

    assert "GRUB_TIMEOUT=-1" in grub_defaults
    assert "GRUB_RECORDFAIL_TIMEOUT=-1" in grub_defaults
    assert "GRUB_TIMEOUT=10" not in grub_defaults


def test_bios_installer_keeps_windows_boot_partition_active() -> None:
    installer = read_repo("assets/live/libertix-install-main.sh")
    bios_adapter = read_repo("assets/live/libertix-bios-adapter.sh")
    preflight = read_repo("Scripts/libertix-storage-preflight.ps1")

    assert "WINDOWS_BOOT_PARTITION_OFFSET_BYTES" in installer
    assert 'set "$NEW_PART_NUM" boot off' in installer
    assert 'set "$WINDOWS_BOOT_PART_NUM" boot on' in installer
    assert 'set "$NEW_PART_NUM" boot on' not in installer
    assert "final verify: Windows boot partition is not active" in bios_adapter
    assert 'Write-Result "BOOT_PARTITION_OFFSET"' in preflight

    awk_program = """
        $1 == number {
            matched = 1
            count = split($7, flags, ",")
            for (i = 1; i <= count; i++) {
                sub(/;$/, "", flags[i])
                if (flags[i] == "boot") has_boot = 1
            }
        }
        END { exit !(matched && has_boot) }
    """
    sample = "/dev/sda:64GB:scsi:512:512:msdos:QEMU:;\n1:1MB:53MB:52MB:primary:ntfs:boot;\n"
    result = subprocess.run(
        ["awk", "-F:", "-v", "number=1", awk_program],
        input=sample,
        text=True,
        check=False,
        capture_output=True,
    )
    assert result.returncode == 0


def test_uefi_recovery_guard_uses_exact_windows_manifest() -> None:
    installer = read_repo("assets/live/libertix-install-main.sh")
    runtime = read_repo("assets/live/libertix-install-runtime-common.sh")

    assert "assert_recovery_unchanged_or_die" in installer
    assert 'partition_at_offset "$DISK" "$RECOVERY_PARTITION_OFFSET_BYTES"' in runtime
    assert 'recovery_size=$(blockdev --getsize64 "$recovery_partition"' in runtime
    assert '"$recovery_size" = "$RECOVERY_PARTITION_SIZE_BYTES"' in runtime
    assert "Windows recovery partition size changed" in runtime


def test_uefi_bitlocker_wait_uses_monotonic_timer() -> None:
    script = read_repo("Scripts/uefi/Libertix.Uefi.Storage.ps1")

    assert "[System.Diagnostics.Stopwatch]::StartNew()" in script
    assert "$decryptionTimer.Elapsed -lt $maxDecryptionWait" in script
    assert "(Get-Date).AddHours(6)" not in script


def test_live_installers_require_exact_disk_and_recovery_manifest() -> None:
    storage = read_repo("assets/live/libertix-storage-common.sh")
    runtime = read_repo("assets/live/libertix-install-runtime-common.sh")
    assert "resolve_target_disk_from_manifest" in storage
    assert "assert_recovery_unchanged_or_die" in runtime

    for path in ("iso/live/install-mint.sh", "iso-uefi/live/install-mint.sh"):
        wrapper = read_repo(path)
        assert "libertix-install-main.sh" in wrapper

    installer = read_repo("assets/live/libertix-install-main.sh")
    assert "resolve_target_disk_from_manifest" in installer
    assert "WINDOWS_PARTITION_OFFSET_BYTES" in installer
    assert "INSTALLER_PARTITION_OFFSET_BYTES" in installer
    assert "RECOVERY_PARTITION_OFFSET_BYTES" in installer
    assert "RECOVERY_PARTITION_SIZE_BYTES" in installer
    assert "ntfsresize failed; the partition table was not changed" in installer
    assert "WARNING: ntfsresize failed, continuing" not in installer


def test_uefi_one_shot_does_not_reorder_bootorder() -> None:
    script = read_repo("Scripts/uefi/Libertix.Uefi.Firmware.ps1")
    staging = read_repo("Scripts/uefi/Libertix.Uefi.Staging.ps1")
    function_body = script.split("function Set-NativeUefiBootOrderOnce", 1)[1].split(
        "function Get-FirmwareBootNumberByDescription", 1
    )[0]

    assert 'Set-FirmwareVariable -Name "BootOrder"' not in function_body
    assert 'Set-FirmwareVariable -Name "BootNext"' in staging


def test_uefi_recovery_tasks_are_not_clock_boundary_dependent() -> None:
    script = read_repo("Scripts/libertix-register-uefi-recovery-tasks.ps1")
    source = apply_changes_source()

    assert "New-ScheduledTaskTrigger -AtStartup" in script
    assert "New-ScheduledTaskTrigger -AtLogOn" in script
    assert "-StartWhenAvailable" in script
    assert "StartBoundary" not in script
    assert "libertix-register-uefi-recovery-tasks.ps1" in source
    method_start = source.index("private void InstallUefiRecoveryAgent")
    method_end = source.index("private static void DeleteUefiRecoverySession", method_start)
    assert '"/SC ONSTART /RU SYSTEM' not in source[method_start:method_end]


def test_wpf_storage_preflight_fails_closed() -> None:
    source = apply_changes_source()
    preflight = read_repo("Scripts/libertix-storage-preflight.ps1")

    assert "DetectFirmwareTypeOrThrow" in source
    assert "Installation was stopped before any disk change" in source
    assert "SYSTEM_DISK_NUMBER" in preflight
    assert "BITLOCKER_SAFE" in preflight
    assert "Exactly one Windows recovery partition is required" in preflight


def test_linux_post_install_checks_continue_after_one_failure() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    result = ResultBuilder("automation")

    class FakeSSH:
        def __init__(self) -> None:
            self.calls: list[tuple[str, dict[str, object]]] = []

        def run(self, command: str, **kwargs) -> CommandResult:
            self.calls.append((command, kwargs))
            exit_code = 1 if "timedatectl" in command else 0
            stderr = "clock not synchronized" if exit_code else ""
            return CommandResult(stdout="diagnostic", stderr=stderr, exit_code=exit_code)

    ssh = FakeSSH()
    options = AutomationOptions(True, "test", "test-passphrase", True)

    service._run_linux_checks(ssh, vm, options, result)  # type: ignore[arg-type]  # noqa: SLF001

    tests = [step.context["test"] for step in result.steps]
    assert "linux.time_sync" in tests
    assert "linux.package_database" in tests
    assert "linux.name_resolution" in tests
    assert tests[-1] == "linux.name_resolution"
    assert (
        next(step for step in result.steps if step.context["test"] == "linux.time_sync").status
        == "error"
    )
    assert len(ssh.calls) == len(tests)
    sudo_calls = [(command, kwargs) for command, kwargs in ssh.calls if command.startswith("sudo ")]
    assert len(sudo_calls) == 2
    assert all("test-passphrase" not in command for command, _kwargs in sudo_calls)
    assert all(kwargs["stdin_data"] == "test-passphrase\n" for _command, kwargs in sudo_calls)


def test_post_install_grub_selection_uses_vision_before_typing(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    result = ResultBuilder("automation")

    class FakeVnc:
        def __init__(self) -> None:
            self.events: list[tuple[str, object]] = []

        def mouseMove(self, x: int, y: int) -> None:  # noqa: N802
            self.events.append(("mouse", (x, y)))

        def keyPress(self, key: str) -> None:  # noqa: N802
            self.events.append(("key", key))

        def disconnect(self) -> None:
            self.events.append(("disconnect", None))

    vnc = FakeVnc()
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"/tmp/{label}.png"),
    )
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda _capture, _name, _os: InstallProgressVerdict(
            iso_download_finished=True,
            installation_finished=True,
            reboot_prompt_visible=False,
            still_in_progress=False,
            error_visible=False,
            summary="The installed boot menu is visible.",
            visible_text=("Linux Mint GNU/Linux\nWindows Boot Manager\nShutdown\nAdvanced options"),
        ),
    )
    monkeypatch.setattr("app.services.automation_postinstall.api.connect", lambda _address: vnc)

    selected = service._select_grub_entry_if_visible(  # noqa: SLF001
        vm, result, "windows", 3
    )

    assert selected is True
    assert vnc.events == [
        ("mouse", (5, 5)),
        ("key", "home"),
        ("key", "down"),
        ("key", "enter"),
        ("disconnect", None),
    ]
    assert result.steps[-1].context["phase"] == "windows-boot"


def test_linux_windows_reboot_password_is_sent_only_on_stdin() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    result = ResultBuilder("automation")

    class FakeSSH:
        command = ""
        stdin_data = ""

        def run(self, command: str, **kwargs) -> CommandResult:
            self.command = command
            self.stdin_data = kwargs["stdin_data"]
            return CommandResult(stdout="", stderr="", exit_code=0)

    ssh = FakeSSH()
    options = AutomationOptions(True, "test", "test-passphrase", True)

    service._request_windows_boot(  # type: ignore[arg-type]  # noqa: SLF001
        ssh, vm, options, result
    )

    assert "test-passphrase" not in ssh.command
    assert ssh.stdin_data == "test-passphrase\n"
    assert "Windows Boot Manager" in ssh.command
    assert result.steps[-1].status == "ok"


def test_windows_post_install_checks_continue_after_one_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    result = ResultBuilder("automation")
    called: list[str] = []

    def fake_run_windows_script(_ssh, *, config, **_kwargs) -> CommandResult:
        called.append(config["check"])
        if config["check"] == "bitlocker":
            raise WorkflowError(
                "automation.test.windows",
                "BitLocker diagnostic failure",
                details={"exit_code": 1, "stderr": "not decrypted"},
            )
        return CommandResult(stdout="RESULT=OK", stderr="", exit_code=0)

    monkeypatch.setattr(service.validation, "run_windows_script", fake_run_windows_script)
    artifacts = CrossOsArtifacts(
        windows_relative_path=r"Users\Public\Documents\probe.bin",
        windows_sha256="a" * 64,
        linux_relative_path="probe.bin",
        linux_sha256="b" * 64,
    )

    service._run_windows_checks(  # noqa: SLF001
        object(),
        vm,
        AutomationOptions(True, "test", "test-passphrase", True),
        artifacts,
        result,
    )

    assert "bitlocker" in called
    assert called[-1] == "chkdsk_scan"
    assert (
        next(step for step in result.steps if step.context["test"] == "windows.bitlocker").status
        == "error"
    )
    assert (
        next(step for step in result.steps if step.context["test"] == "windows.chkdsk_scan").status
        == "ok"
    )


def test_windows_post_install_script_exposes_every_requested_check() -> None:
    script = read_repo("auto_tests/app/scripts/post_install_windows_check.ps1")
    service_source = read_repo("auto_tests/app/services/automation_postinstall.py")

    requested = set(re.findall(r'^\s+"([a-z0-9_]+)",?$', service_source, re.MULTILINE))
    implemented = set(re.findall(r'^\s+"([a-z0-9_]+)" \{$', script, re.MULTILINE))

    assert requested.intersection({"identity", "firmware", "cross_os_hash"}) <= implemented
    assert "$linuxHomePath" in script
    assert "$home =" not in script.casefold()
    assert "Get-NetRoute `" in script
    assert "$defaultRoutes.Count -ge 1" in script
    assert 'NextHop -contains "192.168.1.1"' not in script
    assert {
        "identity",
        "firmware",
        "system_volume",
        "recovery",
        "bitlocker",
        "temporary_artifacts",
        "network",
        "hibernation",
        "ext4_driver",
        "ext4_readonly_mount",
        "linux_home",
        "linux_home_hash",
        "ext4_write_denied",
        "explorer_shortcut",
        "cross_os_hash",
        "dism_check_health",
        "sfc_verify_only",
        "chkdsk_scan",
    } <= implemented
