import hashlib
import re
import shlex
import subprocess
import threading
from pathlib import Path, PurePosixPath, PureWindowsPath
from types import SimpleNamespace

import pytest
from PIL import Image, ImageDraw
from pydantic import ValidationError

import app.services.automation as automation_module
import app.services.automation_monitoring as automation_monitoring_module
import app.services.automation_postinstall as automation_postinstall_module
import app.services.automation_wizard as automation_wizard_module
from app.clients.ssh import CommandResult
from app.clients.vision_models import InstallProgressVerdict
from app.clients.vision_parsing import load_wizard_json
from app.clients.vnc import VNCClient
from app.config import Settings
from app.distributions import load_distribution_profile
from app.errors import WorkflowError
from app.models import ValidationRequest
from app.services.automation import AutomationService
from app.services.automation_postinstall import CrossOsArtifacts
from app.services.automation_types import AutomationOptions, Point
from app.services.automation_windows_checks import (
    build_windows_validation_plan,
    windows_validation_timeout_seconds,
)
from app.services.automation_wizard import WizardAutomationMixin
from app.services.common import ResultBuilder
from app.services.reset import ResetService
from app.services.source_tree import LocalSourceTree
from app.services.validation import ValidationService

REPO_ROOT = Path(__file__).resolve().parents[2]


def test_distribution_profiles_are_loaded_from_the_versioned_catalog() -> None:
    mint = load_distribution_profile("mint")
    zorin = load_distribution_profile("zorin")

    assert (mint.catalog_index, mint.os_release_id, mint.grub_icon) == (
        0,
        "linuxmint",
        "linuxmint",
    )
    assert (zorin.catalog_index, zorin.os_release_id, zorin.grub_icon) == (
        1,
        "zorin",
        "zorin",
    )
    assert mint.installer_iso_file_name == "mint.iso"
    assert zorin.installer_iso_file_name == "zorin.iso"


def test_wizard_distribution_keyboard_selection_follows_catalog_order(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    mint = load_distribution_profile("mint")
    zorin = load_distribution_profile("zorin")
    events: list[tuple[str, str]] = []
    client = SimpleNamespace(
        keyDown=lambda key: events.append(("down", key)),
        keyPress=lambda key: events.append(("press", key)),
        keyUp=lambda key: events.append(("up", key)),
    )
    service = AutomationService(settings())
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)

    service._select_distribution_with_keyboard(client, mint.catalog_index)  # noqa: SLF001
    mint_events = list(events)
    events.clear()
    service._select_distribution_with_keyboard(client, zorin.catalog_index)  # noqa: SLF001

    assert mint_events == [
        ("down", "ctrl"),
        ("press", "home"),
        ("up", "ctrl"),
        ("press", "enter"),
    ]
    assert events == [
        ("down", "ctrl"),
        ("press", "home"),
        ("up", "ctrl"),
        ("down", "ctrl"),
        ("press", "right"),
        ("up", "ctrl"),
        ("press", "enter"),
    ]


def test_wizard_pages_expose_deterministic_keyboard_navigation() -> None:
    pages = {
        "ChooseDistro.xaml": "ChooseDistro_PreviewKeyDown",
        "ResizeDisk.xaml": "ResizeDisk_PreviewKeyDown",
        "SharingOptionsPage.xaml": "SharingOptionsPage_PreviewKeyDown",
        "AccountCreation.xaml": "AccountCreation_PreviewKeyDown",
        "WarningConfirmation.xaml": "WarningConfirmation_PreviewKeyDown",
    }

    for file_name, handler in pages.items():
        source = (REPO_ROOT / "Pages" / file_name).read_text(encoding="utf-8-sig")
        assert 'KeyboardNavigation.TabNavigation="Cycle"' in source
        assert f'PreviewKeyDown="{handler}"' in source
        assert 'IsDefault="True"' in source

    distro = (REPO_ROOT / "Pages/ChooseDistro.xaml.cs").read_text(encoding="utf-8-sig")
    assert "e.Key == Key.Right" in distro
    assert "DistrosListBox.SelectedIndex = selectedIndex" in distro
    assert "NavigateToSelectedDistro();" in distro
    resize = (REPO_ROOT / "Pages/ResizeDisk.xaml.cs").read_text(encoding="utf-8-sig")
    assert "e.Key == Key.End && Keyboard.Modifiers == ModifierKeys.Control" in resize
    assert "NavigateToSharingOptions();" in resize


def test_distribution_cards_have_uniform_rounded_selection_chrome() -> None:
    source = (REPO_ROOT / "Pages/ChooseDistro.xaml").read_text(encoding="utf-8-sig")
    card_style = source.split('<Style x:Key="DistroCard"', maxsplit=1)[1].split(
        "</Style>", maxsplit=1
    )[0]
    container_style = source.split('<Style TargetType="ListBoxItem">', maxsplit=1)[1].split(
        "</Style>", maxsplit=1
    )[0]

    assert '<Setter Property="Height" Value="285"/>' in card_style
    assert '<Setter Property="CornerRadius" Value="8"/>' in card_style
    assert '<DataTrigger Binding="{Binding IsSelected}" Value="True">' in card_style
    assert '<ControlTemplate TargetType="{x:Type ListBoxItem}">' in container_style
    assert "<ContentPresenter " in container_style
    assert "<Border " not in container_style


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
        "main_ssh_host": "192.0.2.208",
        "main_ssh_user": "root",
        "main_ssh_password": "secret",
        "windows_ssh_password": "secret",
        "samba_unc": r"\\192.0.2.208\smb",
        "samba_username": "admin",
        "samba_password": "secret",
        "build_vm_host": "192.0.2.138",
        "build_vm_user": "admin",
        "build_vm_password": "secret",
        "ssh_known_hosts": "/tmp/libertix-test-known-hosts",
        "filepool_base_url": "http://192.0.2.170:8000/filepool",
        "development_static_ipv4_prefix_length": 24,
        "development_static_ipv4_gateway": "192.0.2.1",
        "development_dns_servers": ("8.8.8.8", "1.1.1.1"),
        "repository_url": "https://github.com/ekimiateam/libertix.git",
        "smb_root": "/srv/libertix-smb",
        "allowed_smb_roots": ("/srv/libertix-smb",),
        "allowed_proxmox_vmids": (500, 501, 502),
        "llm_api_url": "http://192.0.2.247:8000/v1",
        "llm_api_key": "secret",
        "llm_model": "Qwen3.6-35B-A3B-Thinking",
        "proxmox_url": "https://192.0.2.166:8006",
        "proxmox_token_id": "root@pam!eki",
        "proxmox_token_secret": "secret",
        "vms": (
            {
                "name": "vm1",
                "host": "192.0.2.240",
                "os": "Windows 10 BIOS",
                "vnc": "192.0.2.166:10",
                "screen_width": 1024,
                "screen_height": 768,
                "vmid": 500,
                "firmware": "bios",
                "automation_enabled": True,
            },
            {
                "name": "vm2",
                "host": "192.0.2.241",
                "os": "Windows 10 UEFI",
                "vnc": "192.0.2.166:11",
                "screen_width": 1280,
                "screen_height": 800,
                "vmid": 501,
                "firmware": "uefi",
                "automation_enabled": True,
            },
            {
                "name": "vm3",
                "host": "192.0.2.242",
                "os": "Windows 11 UEFI",
                "vnc": "192.0.2.166:12",
                "screen_width": 1280,
                "screen_height": 800,
                "vmid": 502,
                "firmware": "uefi",
                "automation_enabled": True,
            },
        ),
        "_env_file": None,
    }
    if "capture_dir" in overrides and "runtime_dir" not in overrides:
        values["runtime_dir"] = Path(overrides["capture_dir"]).parent
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
        PurePosixPath("/srv/libertix-smb/Libertix-release/folder/Libertix.exe")
    )
    assert actual == PureWindowsPath("Z:/Libertix-release/folder/Libertix.exe")


def test_smb_root_is_strictly_guarded() -> None:
    with pytest.raises(ValidationError):
        settings(smb_root="/")


@pytest.mark.parametrize(
    "field,value",
    [
        ("source_dir_name", "../outside"),
        ("source_dir_name", "/absolute"),
        ("release_dir_name", r"..\outside"),
        ("release_dir_name", "nested/path"),
    ],
)
def test_workspace_directory_names_reject_path_components(field: str, value: str) -> None:
    with pytest.raises(ValidationError):
        settings(**{field: value})


def test_capture_directory_must_be_confined_to_runtime_directory(tmp_path: Path) -> None:
    with pytest.raises(ValidationError):
        settings(
            runtime_dir=tmp_path / "runtime",
            capture_dir=tmp_path / "outside" / "captures",
        )


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("ssh_timeout_seconds", 0),
        ("command_timeout_seconds", -1),
        ("llm_max_attempts", 0),
        ("proxmox_task_timeout_seconds", 0),
        ("automation_monitor_interval_seconds", 0),
        ("post_install_boot_timeout_seconds", -5),
        ("vms", ()),
    ],
)
def test_runtime_configuration_rejects_empty_or_nonpositive_controls(
    field: str, value: object
) -> None:
    with pytest.raises(ValidationError):
        settings(**{field: value})


@pytest.mark.parametrize("address", ["0.0.0.0", "127.0.0.1", "169.254.1.1", "224.0.0.1"])
def test_development_network_rejects_nonconfigurable_ipv4(address: str) -> None:
    with pytest.raises(ValidationError):
        settings(development_static_ipv4_gateway=address)


def test_local_source_uses_git_ignore_rules(tmp_path: Path) -> None:
    repository = tmp_path / "repository"
    repository.mkdir()
    subprocess.run(["git", "init", "-q", str(repository)], check=True)
    (repository / ".gitignore").write_text(
        "local-markdown/\n.work/\nauto_tests/logs/\n*.pem\n",
        encoding="utf-8",
    )
    (repository / "tracked.txt").write_text("tracked", encoding="utf-8")
    (repository / "untracked.txt").write_text("untracked", encoding="utf-8")
    (repository / "catalog-signing-private.pem").write_text("private", encoding="utf-8")
    (repository / "local-markdown").mkdir()
    (repository / "local-markdown" / "LOCAL_ENVIRONMENT.md").write_text(
        "private topology", encoding="utf-8"
    )
    (repository / ".work").mkdir()
    (repository / ".work" / "rootfs.img").write_bytes(b"large")
    (repository / "auto_tests" / "logs").mkdir(parents=True)
    (repository / "auto_tests" / "logs" / "operation.log").write_text(
        "diagnostic", encoding="utf-8"
    )
    subprocess.run(
        ["git", "-C", str(repository), "add", ".gitignore", "tracked.txt"],
        check=True,
    )

    selected = {
        path.relative_to(repository).as_posix()
        for path in LocalSourceTree.selected_files(repository)
    }

    assert selected == {".gitignore", "tracked.txt", "untracked.txt"}


def test_live_sha256_verification_accepts_only_the_expected_file(
    tmp_path: Path,
    run_shell_function,
) -> None:
    payload = tmp_path / "installer.iso"
    payload.write_bytes(b"trusted installer")
    expected = hashlib.sha256(payload.read_bytes()).hexdigest()
    runtime = REPO_ROOT / "assets/live/libertix-install-runtime-common.sh"

    accepted = run_shell_function(runtime, "verify_file_sha256", str(payload), expected.upper())
    rejected = run_shell_function(runtime, "verify_file_sha256", str(payload), "0" * 64)

    assert accepted.returncode == 0
    assert rejected.returncode != 0


def test_live_context_keeps_distinct_states_for_the_same_plan(tmp_path: Path) -> None:
    first = tmp_path / "first"
    second = tmp_path / "second"
    candidates = tmp_path / "candidates"
    for directory in (first, second, candidates):
        directory.mkdir()
    plan = b'{"planId":"same"}\n'
    (first / "installation-plan.json").write_bytes(plan)
    (second / "installation-plan.json").write_bytes(plan)
    (first / "installation-state.json").write_text("first\n", encoding="utf-8")
    (second / "installation-state.json").write_text("second\n", encoding="utf-8")
    context = REPO_ROOT / "assets/live/libertix-live-context.sh"
    command = (
        'source "$1"; copy_libertix_context_candidate "$2" "$4"; '
        'copy_libertix_context_candidate "$3" "$4"; '
        'find "$4" -maxdepth 1 -type f -name "*.plan.json" -print'
    )

    completed = subprocess.run(
        [
            "bash",
            "-c",
            command,
            "bash",
            str(context),
            str(first / "installation-plan.json"),
            str(second / "installation-plan.json"),
            str(candidates),
        ],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0
    assert len(completed.stdout.splitlines()) == 2


def test_live_state_transition_is_published_to_the_windows_recovery_root(
    tmp_path: Path,
) -> None:
    state = tmp_path / "installation-state.json"
    windows = tmp_path / "windows"
    state.write_text('{"revision":7}\n', encoding="utf-8")
    windows.mkdir()
    context = REPO_ROOT / "assets/live/libertix-live-context.sh"
    command = (
        'windows_path_to_relative() { printf "%s\\n" "Recovery/Current"; }; '
        'source "$1"; INSTALLATION_STATE_PATH="$2"; '
        'RECOVERY_ROOT_WINDOWS="C:\\\\Recovery\\\\Current"; '
        'publish_installation_state_mirror "$3"; '
        'cmp "$2" "$3/Recovery/Current/installation-state.json"'
    )

    completed = subprocess.run(
        ["bash", "-c", command, "bash", str(context), str(state), str(windows)],
        check=False,
        capture_output=True,
        text=True,
    )

    assert completed.returncode == 0, completed.stderr


@pytest.mark.parametrize(
    "url",
    [
        "ftp://192.0.2.170/filepool",
        "http://user:password@192.0.2.170/filepool",
        "http://192.0.2.170/filepool?token=secret",
        "http://192.0.2.170/filepool#fragment",
    ],
)
def test_filepool_base_url_rejects_unsafe_values(url: str) -> None:
    with pytest.raises(ValidationError):
        settings(filepool_base_url=url)


def test_reset_scope_is_exact() -> None:
    configured = settings(reset_snapshot="baseline-a")
    assert ResetService(configured)._selected_vmids(None) == (500, 501, 502)  # noqa: SLF001
    assert configured.reset_snapshot == "baseline-a"


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

        def verify_rollback_state(
            self,
            _node: str,
            _vmid: int,
            snapshot: str,
            *,
            require_running: bool,
        ) -> dict[str, object]:
            assert not require_running
            return {"snapshot_parent": snapshot, "status": "running", "qmpstatus": "running"}

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


def test_local_source_copy_excludes_ignored_runtime_files() -> None:
    selected = {
        path.relative_to(REPO_ROOT).as_posix() for path in LocalSourceTree.selected_files(REPO_ROOT)
    }

    assert "auto_tests/.env.example" in selected
    assert "Tools/aria2/aria2c.exe" in selected
    assert "auto_tests/.env" not in selected
    assert "auto_tests/.env.local" not in selected
    assert "auto_tests/app/filepool/mint.iso" not in selected
    assert "bin/Release/Libertix.exe" not in selected


def test_vnc_display_is_converted_to_tcp_port() -> None:
    assert VNCClient.vncdotool_address("192.0.2.166:10") == "192.0.2.166::5910"


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
    with pytest.raises(WorkflowError, match="outside the display"):
        service._click_absolute(client, vm, Point(1280, 643), 0)  # noqa: SLF001


def test_sharing_page_uses_keyboard_state_and_default_button(
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
    screens = iter(("sharing", "account"))
    monotonic_values = iter((0.0, 0.0, 400.0, 350.0))

    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(automation_wizard_module.time, "monotonic", lambda: next(monotonic_values))
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
        distribution_index=0,
        share_windows_files_in_linux=False,
        share_linux_files_in_windows=True,
        username="test",
        result=ResultBuilder("automation"),
    )

    assert events == [
        ("down", "ctrl"),
        ("press", "home"),
        ("up", "ctrl"),
        ("press", "space"),
        ("press", "tab"),
        ("press", "enter"),
    ]


def test_resize_page_focuses_next_before_keyboard_activation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    events: list[tuple[str, str]] = []
    client = SimpleNamespace(
        keyDown=lambda key: events.append(("down", key)),
        keyPress=lambda key: events.append(("press", key)),
        keyUp=lambda key: events.append(("up", key)),
    )
    screens = iter(("resize", "account"))
    monotonic_values = iter((0.0, 0.0, 400.0, 350.0))

    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(automation_wizard_module.time, "monotonic", lambda: next(monotonic_values))
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("resize-navigation.png"),
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
        distribution_index=1,
        username="test",
        result=ResultBuilder("automation"),
    )

    assert events == [
        ("down", "ctrl"),
        ("press", "end"),
        ("up", "ctrl"),
        ("press", "enter"),
    ]


def test_account_password_fields_are_rewritten_after_wpf_validation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    writes: list[str] = []
    events: list[tuple[str, str]] = []
    client = SimpleNamespace(
        keyDown=lambda key: events.append(("down", key)),
        keyPress=lambda key: events.append(("press", key)),
        keyUp=lambda key: events.append(("up", key)),
    )

    monkeypatch.setattr(
        service,
        "_replace_focused_field",
        lambda _client, _vm, text: writes.append(text),
    )
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)

    service._fill_account_fields(  # noqa: SLF001
        client,
        vm,
        username="test",
        password="secret",
    )

    assert writes == [
        "test",
        "secret",
        "secret",
        "secret",
        "secret",
    ]
    assert events == [
        ("down", "ctrl"),
        ("press", "home"),
        ("up", "ctrl"),
        ("press", "tab"),
        ("press", "tab"),
        ("down", "shift"),
        ("press", "tab"),
        ("up", "shift"),
        ("press", "tab"),
    ]


def test_account_fields_are_refilled_when_the_visible_form_rejects_the_first_write(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    fills: list[str] = []
    captures: list[str] = []
    confirmations = iter((False, True))

    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_fill_account_fields",
        lambda *_args, **_kwargs: fills.append("fill"),
    )
    monkeypatch.setattr(
        service,
        "_capture_wizard_pair",
        lambda _client, _vm, label, _result: (
            captures.append(label) or Path(f"{label}-1.png"),
            Path(f"{label}-2.png"),
        ),
    )

    def assert_state(*_args: object, **_kwargs: object) -> None:
        if not next(confirmations):
            raise WorkflowError(
                "automation.wizard_state",
                "Account fields remain empty",
                details={"detected_screen": "account"},
            )

    monkeypatch.setattr(service, "_assert_wizard_state", assert_state)

    service._fill_and_confirm_account_fields(  # noqa: SLF001
        object(),
        vm,
        username="test",
        password="secret",
        result=ResultBuilder("automation"),
    )

    assert fills == ["fill", "fill"]
    assert captures == ["04-account-filled-01", "04-account-filled-02"]


def test_navigation_closes_windows_security_after_defender_preparation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    closed: list[str] = []
    client = SimpleNamespace()
    screens = iter(
        (
            ("other", "Windows Security is visible", ""),
            ("account", "test", "Créez votre compte Linux"),
        )
    )

    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("windows-security-navigation.png"),
    )

    def analyze(*_args: object, **_kwargs: object) -> SimpleNamespace:
        screen, summary, visible_text = next(screens)
        return SimpleNamespace(
            detected_screen=screen,
            expected_screen_visible=False,
            no_blocking_error=True,
            summary=summary,
            visible_text=visible_text,
        )

    service.vision_llm.analyze_wizard_state = analyze  # type: ignore[method-assign]
    monkeypatch.setattr(
        service,
        "_close_windows_interference",
        lambda _vm, *, kind, step, result: (
            closed.append(kind),
            result.ok(step, "closed"),
        ),
    )
    service._navigate_to_account(  # noqa: SLF001
        client,
        vm,
        distribution_index=0,
        username="test",
        result=ResultBuilder("automation"),
    )

    assert closed == ["security"]


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

    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
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
        distribution_index=0,
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
    events: list[tuple[str, str]] = []
    client = SimpleNamespace(
        keyDown=lambda key: events.append(("down", key)),
        keyPress=lambda key: events.append(("press", key)),
        keyUp=lambda key: events.append(("up", key)),
    )

    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
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
                summary="The page is compatible and has no COMPAT_E_* error",
                visible_text="Machine compatible avec Libertix. Continuer",
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
        distribution_index=0,
        username="test",
        result=result,
    )

    pressed_keys = [key for event, key in events if event == "press"]
    assert len(pressed_keys) == 8
    assert pressed_keys.count("end") == 1
    assert any(step.step == "automation.compatibility_wait" for step in result.steps)


def test_navigation_activates_visible_welcome_window_before_retrying_enter(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    events: list[tuple[str, str]] = []
    client = SimpleNamespace(
        keyDown=lambda key: events.append(("down", key)),
        keyPress=lambda key: events.append(("press", key)),
        keyUp=lambda key: events.append(("up", key)),
    )
    verdicts = iter(
        (
            SimpleNamespace(
                detected_screen="welcome",
                expected_screen_visible=False,
                no_blocking_error=True,
                summary="Libertix is visible but inactive",
                visible_text="Bienvenue sur Libertix !",
            ),
            SimpleNamespace(
                detected_screen="account",
                expected_screen_visible=True,
                no_blocking_error=True,
                summary="Account page",
                visible_text="Créez votre compte Linux",
            ),
        )
    )
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("welcome-focus-recovery.png"),
    )
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: next(verdicts)  # type: ignore[method-assign]

    service._navigate_to_account(  # noqa: SLF001
        client,
        vm,
        distribution_index=0,
        username="test",
        result=ResultBuilder("automation"),
    )

    assert events == [
        ("down", "alt"),
        ("press", "tab"),
        ("up", "alt"),
        ("press", "enter"),
    ]


def test_navigation_reports_blocking_compatibility_error_immediately(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    events: list[tuple[str, int, int] | tuple[str, int]] = []
    client = SimpleNamespace(
        mouseMove=lambda x, y: events.append(("move", x, y)),
        mousePress=lambda button: events.append(("press", button)),
    )

    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("compatibility-error.png"),
    )
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: SimpleNamespace(  # type: ignore[method-assign]
        detected_screen="compatibility",
        expected_screen_visible=False,
        no_blocking_error=False,
        summary="Compatibility failed with COMPAT_E_RAM_TOO_LOW",
        visible_text="COMPAT_E_RAM_TOO_LOW: 2048 MiB required",
    )

    result = ResultBuilder("automation")
    with pytest.raises(WorkflowError) as raised:
        service._navigate_to_account(  # noqa: SLF001
            client,
            vm,
            distribution_index=0,
            username="test",
            result=result,
        )

    assert raised.value.step == "automation.compatibility_preflight"
    assert "COMPAT_E_RAM_TOO_LOW" in raised.value.details["summary"]
    assert events == []


def test_navigation_reports_insufficient_resize_capacity_immediately(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    events: list[tuple[str, int, int] | tuple[str, int]] = []
    client = SimpleNamespace(
        mouseMove=lambda x, y: events.append(("move", x, y)),
        mousePress=lambda button: events.append(("press", button)),
    )

    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("resize-capacity-error.png"),
    )
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: SimpleNamespace(  # type: ignore[method-assign]
        detected_screen="resize",
        expected_screen_visible=False,
        no_blocking_error=False,
        summary="The resize page is blocked",
        visible_text="Espace insuffisant. 2,5 Gio supplémentaires sont nécessaires.",
    )

    result = ResultBuilder("automation")
    with pytest.raises(WorkflowError) as raised:
        service._navigate_to_account(  # noqa: SLF001
            client,
            vm,
            distribution_index=0,
            username="test",
            result=result,
        )

    assert raised.value.step == "automation.resize_capacity"
    assert "Espace insuffisant" in raised.value.details["visible_text"]
    assert events == []


def test_wizard_screen_uses_visible_title_when_model_returns_other() -> None:
    verdict = load_wizard_json(
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
    events: list[tuple[str, str]] = []
    client = SimpleNamespace(
        keyDown=lambda key: events.append(("down", key)),
        keyPress=lambda key: events.append(("press", key)),
        keyUp=lambda key: events.append(("up", key)),
    )
    screens = iter(
        (
            ("distro", False, "Choisissez votre version de Linux ! Avertissement d'orage"),
            ("account", True, "Créez votre compte Linux"),
        )
    )
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
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
        distribution_index=0,
        username="test",
        result=ResultBuilder("automation"),
    )

    assert events == [
        ("down", "ctrl"),
        ("press", "home"),
        ("up", "ctrl"),
        ("press", "enter"),
    ]


def test_navigation_closes_windows_settings_covering_libertix(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    keys: list[tuple[str, str]] = []
    closed: list[str] = []
    client = SimpleNamespace(
        keyDown=lambda key: keys.append(("down", key)),
        keyPress=lambda key: keys.append(("press", key)),
        keyUp=lambda key: keys.append(("up", key)),
        mouseMove=lambda _x, _y: None,
        mousePress=lambda _button: None,
    )
    verdicts = iter(
        (
            SimpleNamespace(
                detected_screen="other",
                expected_screen_visible=False,
                no_blocking_error=True,
                summary="Windows Settings is covering the Libertix wizard",
                visible_text="",
            ),
            SimpleNamespace(
                detected_screen="account",
                expected_screen_visible=True,
                no_blocking_error=True,
                summary="Account page",
                visible_text="Créez votre compte Linux",
            ),
        )
    )
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_close_windows_interference",
        lambda _vm, *, kind, step, result: (
            closed.append(kind),
            result.ok(step, "closed"),
        ),
    )
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args, **_kwargs: Path("windows-settings.png"),
    )
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: next(verdicts)  # type: ignore[method-assign]
    result = ResultBuilder("automation")

    service._navigate_to_account(  # noqa: SLF001
        client,
        vm,
        distribution_index=0,
        username="test",
        result=result,
    )

    assert keys == []
    assert closed == ["settings"]
    assert any(step.step == "automation.dismiss_windows_settings" for step in result.steps)


def test_account_navigation_waits_for_the_warning_transition() -> None:
    source = (REPO_ROOT / "auto_tests/app/services/automation_wizard.py").read_text(
        encoding="utf-8"
    )
    account_transition = source.split("self._fill_and_confirm_account_fields", 1)[1].split(
        "self._confirm_warning_page", 1
    )[0]

    assert 'self._press_key(client, "enter", 5.0)' in account_transition


def test_warning_confirmation_closes_windows_settings_and_retries(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    keys: list[tuple[str, str]] = []
    closed: list[str] = []
    client = SimpleNamespace(
        keyDown=lambda key: keys.append(("down", key)),
        keyPress=lambda key: keys.append(("press", key)),
        keyUp=lambda key: keys.append(("up", key)),
        mouseMove=lambda x, y: keys.append(("move", f"{x},{y}")),
        mousePress=lambda button: keys.append(("mouse", str(button))),
    )
    verdicts = iter(
        (
            SimpleNamespace(
                detected_screen="other",
                expected_screen_visible=False,
                no_blocking_error=True,
                username_visible=False,
                password_fields_filled=False,
                summary="Windows Settings is covering the Libertix wizard",
                visible_text="",
                model_dump=lambda: {
                    "detected_screen": "other",
                    "expected_screen_visible": False,
                    "no_blocking_error": True,
                    "username_visible": False,
                    "password_fields_filled": False,
                    "summary": "Windows Settings is covering the Libertix wizard",
                    "visible_text": "",
                },
            ),
            SimpleNamespace(
                detected_screen="account",
                expected_screen_visible=False,
                no_blocking_error=True,
                username_visible=True,
                password_fields_filled=True,
                summary="Account page still visible",
                visible_text="Créez votre compte Linux test •••• ••••",
                model_dump=lambda: {
                    "detected_screen": "account",
                    "expected_screen_visible": False,
                    "no_blocking_error": True,
                    "username_visible": True,
                    "password_fields_filled": True,
                    "summary": "Account page still visible",
                    "visible_text": "Créez votre compte Linux test •••• ••••",
                },
            ),
            SimpleNamespace(
                detected_screen="warning",
                expected_screen_visible=True,
                no_blocking_error=True,
                username_visible=False,
                password_fields_filled=False,
                summary="Final warning page",
                visible_text="Avertissement",
                model_dump=lambda: {
                    "detected_screen": "warning",
                    "expected_screen_visible": True,
                    "no_blocking_error": True,
                    "username_visible": False,
                    "password_fields_filled": False,
                    "summary": "Final warning page",
                    "visible_text": "Avertissement",
                },
            ),
        )
    )
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_close_windows_interference",
        lambda _vm, *, kind, step, result: (
            closed.append(kind),
            result.ok(step, "closed"),
        ),
    )
    monkeypatch.setattr(
        service,
        "_capture_wizard_pair",
        lambda *_args, **_kwargs: (Path("warning-1.png"), Path("warning-2.png")),
    )
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: next(verdicts)  # type: ignore[method-assign]
    result = ResultBuilder("automation")

    service._confirm_warning_page(  # noqa: SLF001
        client,
        vm,
        "test",
        result,
    )

    assert closed == ["settings"]
    assert ("press", "enter") in keys
    assert not any(event[0] in {"move", "mouse"} for event in keys)
    assert any(step.step == "automation.dismiss_windows_settings" for step in result.steps)
    assert result.steps[-1].step == "automation.wizard_state"


def test_warning_acknowledgement_uses_deterministic_focus_and_visual_proof(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    keys: list[tuple[str, str]] = []
    client = SimpleNamespace(
        keyDown=lambda key: keys.append(("down", key)),
        keyPress=lambda key: keys.append(("press", key)),
        keyUp=lambda key: keys.append(("up", key)),
    )

    def verdict(acknowledged: bool) -> SimpleNamespace:
        values = {
            "detected_screen": "warning",
            "expected_screen_visible": True,
            "no_blocking_error": True,
            "username_visible": False,
            "password_fields_filled": False,
            "warning_acknowledged": acknowledged,
            "summary": "Warning page with confirmation checkbox",
            "visible_text": "Avertissement Je comprends",
        }
        return SimpleNamespace(**values, model_dump=lambda: values)

    verdicts = iter((verdict(False), verdict(True)))
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_wizard_pair",
        lambda *_args, **_kwargs: (Path("warning-1.png"), Path("warning-2.png")),
    )
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: next(verdicts)  # type: ignore[method-assign]
    result = ResultBuilder("automation")

    service._acknowledge_warning_page(  # noqa: SLF001
        client,
        vm,
        "test",
        result,
    )

    assert keys == [
        ("down", "ctrl"),
        ("press", "home"),
        ("up", "ctrl"),
        ("press", "space"),
    ]
    assert result.steps[-1].step == "automation.warning_acknowledged"


def test_warning_acknowledgement_does_not_toggle_an_already_checked_box(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    keys: list[tuple[str, str]] = []
    client = SimpleNamespace(
        keyDown=lambda key: keys.append(("down", key)),
        keyPress=lambda key: keys.append(("press", key)),
        keyUp=lambda key: keys.append(("up", key)),
    )
    values = {
        "detected_screen": "warning",
        "expected_screen_visible": True,
        "no_blocking_error": True,
        "username_visible": False,
        "password_fields_filled": False,
        "warning_acknowledged": True,
        "summary": "Warning page with selected confirmation checkbox",
        "visible_text": "Avertissement Je comprends",
    }
    monkeypatch.setattr(
        service,
        "_capture_wizard_pair",
        lambda *_args, **_kwargs: (Path("warning-1.png"), Path("warning-2.png")),
    )
    service.vision_llm.analyze_wizard_state = lambda *_args, **_kwargs: SimpleNamespace(  # type: ignore[method-assign]
        **values, model_dump=lambda: values
    )
    result = ResultBuilder("automation")

    service._acknowledge_warning_page(  # noqa: SLF001
        client,
        vm,
        "test",
        result,
    )

    assert keys == []
    assert result.steps[-1].step == "automation.warning_acknowledged"


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

    with pytest.raises(Exception, match="Unknown VM selector"):
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


def test_validation_retries_capture_when_libertix_is_not_visible_yet(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    service = ValidationService(settings(capture_dir=tmp_path, launch_wait_seconds=0.01))
    vm = service.select_vms(["vm1"])[0]
    verdicts = iter(
        (
            SimpleNamespace(
                valid=False,
                model_dump=lambda: {
                    "no_visible_problem": False,
                    "libertix_running": False,
                    "welcome_message_ok": False,
                    "summary": "Windows desktop only",
                    "visible_problems": ["Libertix is not visible"],
                },
            ),
            SimpleNamespace(
                valid=True,
                model_dump=lambda: {
                    "no_visible_problem": True,
                    "libertix_running": True,
                    "welcome_message_ok": True,
                    "summary": "Welcome screen visible",
                    "visible_problems": [],
                },
            ),
        )
    )
    captures: list[Path] = []

    monkeypatch.setattr(
        service,
        "deploy_to_documents",
        lambda *_args: PureWindowsPath("C:/Libertix.exe"),
    )
    monkeypatch.setattr(service, "_launch_interactive", lambda *_args: {"pid": 1234})
    monkeypatch.setattr(service.vnc, "capture", lambda _address, path: captures.append(path))
    monkeypatch.setattr(service.vision_llm, "analyze", lambda *_args: next(verdicts))
    monkeypatch.setattr("app.services.validation.time.sleep", lambda _seconds: None)
    result = ResultBuilder("validation")

    service._validate_vm(vm, PureWindowsPath("Z:/Libertix.exe"), result)  # noqa: SLF001

    assert len(captures) == 2
    assert [step.step for step in result.steps].count("llm.verdict_retry") == 1
    assert result.steps[-1].step == "llm.verdict"
    assert result.steps[-1].context["attempt"] == 2


def test_launch_interactive_confirms_process_when_launcher_output_is_empty(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FakeSshContext:
        def __enter__(self) -> object:
            return object()

        def __exit__(self, *_args: object) -> None:
            return None

    service = ValidationService(settings())
    scripts: list[str] = []

    def fake_run_windows_script(
        *_args: object, script_name: str, step: str, **_kwargs: object
    ) -> object:
        scripts.append(script_name)
        if script_name == "launch_libertix_elevated.ps1":
            assert step == "vm.launch_elevated"
            return SimpleNamespace(stdout="", stderr="")

        assert script_name == "confirm_libertix_process.ps1"
        assert step == "vm.launch_elevated.confirm_process"
        return SimpleNamespace(
            stdout=(
                "PID=1234\nSESSION_ID=2\nTASK_NAME=LibertixValidation_vm1\n"
                "EXECUTABLE=Z:\\Libertix-release\\Libertix.exe\n"
            ),
            stderr="",
        )

    monkeypatch.setattr(service, "ssh", lambda *_args, **_kwargs: FakeSshContext())
    monkeypatch.setattr(service, "run_windows_script", fake_run_windows_script)
    vm = service.select_vms(["vm1"])[0]

    launch = service._launch_interactive(  # noqa: SLF001
        vm,
        PureWindowsPath("Z:/Libertix-release/Libertix.exe"),
        ResultBuilder("validation"),
    )

    assert scripts == ["launch_libertix_elevated.ps1", "confirm_libertix_process.ps1"]
    assert launch["pid"] == 1234
    assert launch["session_id"] == 2


def test_about_back_navigation_uses_a_fresh_welcome_page() -> None:
    source = read_repo("MainWindow.xaml.cs")
    project = read_repo("Libertix.csproj")
    return_to_welcome = source.split("public void ReturnToWelcome()", 1)[1].split(
        "private Welcome CreateWelcomePage", 1
    )[0]

    assert '<Page Include="Pages\\Welcome.xaml" />' in project
    assert "CreateWelcomePage()" in return_to_welcome
    assert "navigation.RemoveBackEntry()" in return_to_welcome
    assert "GoBack()" not in return_to_welcome


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
        assert config["development_static_ipv4_prefix_length"] == 24
        assert config["development_static_ipv4_gateway"] == "192.0.2.1"
        assert config["development_dns_servers"] == ["8.8.8.8", "1.1.1.1"]
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


def test_automation_prepares_snapshot_clock_before_deployment(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FakeSshContext:
        def __enter__(self) -> object:
            return object()

        def __exit__(self, *_args: object) -> None:
            return None

    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    observed: dict[str, object] = {}

    def fake_ssh(*_args: object, **kwargs: object) -> FakeSshContext:
        observed["remote_os"] = kwargs.get("remote_os")
        return FakeSshContext()

    def fake_run_windows_script(
        *_args: object,
        script_name: str,
        config: dict[str, object],
        step: str,
        **_kwargs: object,
    ) -> CommandResult:
        observed.update(script_name=script_name, config=config, step=step)
        return CommandResult(
            stdout=(
                "UTC_NOW=2026-08-07T00:00:00.0000000Z\n"
                "CLOCK_SKEW_SECONDS=1\n"
                "TOAST_NOTIFICATIONS_DISABLED=True\n"
                "WINDOWS_BACKUP_NOTIFICATIONS_DISABLED=True\n"
                "WINDOWS_NOTIFICATION_SERVICES_DISABLED=True\n"
            ),
            stderr="",
            exit_code=0,
        )

    monkeypatch.setattr(service.validation, "ssh", fake_ssh)
    monkeypatch.setattr(service.validation, "run_windows_script", fake_run_windows_script)
    result = ResultBuilder("automation")

    service._prepare_windows_test_vm(vm, result)  # noqa: SLF001

    assert observed["script_name"] == "prepare_windows_test_vm.ps1"
    assert observed["step"] == "automation.prepare_vm"
    assert observed["remote_os"] == "windows"
    assert "utc_now" in observed["config"]
    assert result.steps[-1].context["clock_skew_seconds"] == 1
    assert result.steps[-1].context["toast_notifications_disabled"] is True
    assert result.steps[-1].context["windows_backup_notifications_disabled"] is True
    assert result.steps[-1].context["windows_notification_services_disabled"] is True


def test_automation_scope_accepts_vm500() -> None:
    service = AutomationService(settings())
    selected = service.validation.select_vms(["vm1"])

    service._automation_profiles(selected, ["vm1"])  # noqa: SLF001


def test_automation_scope_accepts_vm502_uefi() -> None:
    service = AutomationService(settings())
    selected = service.validation.select_vms(["vm3"])

    service._automation_profiles(selected, ["vm3"])  # noqa: SLF001


def test_automation_scope_accepts_vm501_uefi() -> None:
    service = AutomationService(settings())
    selected = service.validation.select_vms(["vm2"])

    service._automation_profiles(selected, ["vm2"])  # noqa: SLF001


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
        def get_vm_status(self, _node: str, _vmid: int, *, step: str) -> object:
            assert step == "automation.vm_status"
            return {"status": "running", "qmpstatus": "io-error"}

    service = AutomationService(settings())

    with pytest.raises(WorkflowError, match="io-error"):
        service.preflight.assert_vm_not_in_io_error(
            FakeProxmox(), "node-a", 500, ResultBuilder("automation")
        )


def test_automation_refuses_low_configured_storage_headroom() -> None:
    class FakeProxmox:
        def _request(self, _method: str, _path: str, *, step: str) -> object:
            assert step == "automation.storage"
            return {"total": 100 * 1024**3, "used": 95 * 1024**3, "avail": 5 * 1024**3}

    service = AutomationService(settings(proxmox_storage="fast-pool"))

    with pytest.raises(WorkflowError, match="insufficient fast-pool"):
        service.preflight.assert_proxmox_storage_headroom(
            FakeProxmox(),
            {500: "node-a", 501: "node-a", 502: "node-a"},
            3,
            ResultBuilder("automation"),
        )


def test_automation_reports_configured_storage_headroom() -> None:
    paths: list[str] = []

    class FakeProxmox:
        def _request(self, _method: str, path: str, *, step: str) -> object:
            assert step == "automation.storage"
            paths.append(path)
            return {"total": 100 * 1024**3, "used": 30 * 1024**3, "avail": 70 * 1024**3}

    service = AutomationService(
        settings(
            proxmox_storage="fast-pool",
            proxmox_storage_min_free_gib=10,
            proxmox_storage_min_free_per_vm_gib=15,
        )
    )
    result = ResultBuilder("automation")

    service.preflight.assert_proxmox_storage_headroom(
        FakeProxmox(), {500: "node-a", 501: "node-a", 502: "node-a"}, 3, result
    )

    assert result.steps[-1].step == "automation.storage_headroom"
    assert result.steps[-1].context["storage"] == "fast-pool"
    assert result.steps[-1].context["available_gib"] == 70
    assert result.steps[-1].context["required_gib"] == 45
    assert paths == ["/nodes/node-a/storage/fast-pool/status"]


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

    with pytest.raises(WorkflowError, match="Apply is blocked"):
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
                    "host": "192.0.2.240",
                    "os": "Windows 10 BIOS",
                    "vnc": "192.0.2.166:10",
                    "screen_width": 1024,
                    "screen_height": 768,
                    "vmid": 500,
                    "firmware": "bios",
                    "automation_enabled": True,
                },
                {
                    "name": "vm4",
                    "host": "192.0.2.244",
                    "os": "Windows experimental",
                    "vnc": "192.0.2.166:14",
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

    with pytest.raises(Exception, match="Libertix auto-click refused"):
        service._automation_profiles(selected, ["vm1", "vm4"])  # noqa: SLF001


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

        def verify_rollback_state(
            self,
            _node: str,
            vmid: int,
            snapshot: str,
            *,
            require_running: bool,
        ) -> dict[str, object]:
            assert require_running
            calls.append(("verify", vmid, snapshot))
            return {"snapshot_parent": snapshot, "status": "running", "qmpstatus": "running"}

    monkeypatch.setattr(automation_module, "ProxmoxClient", FakeProxmox)
    service = AutomationService(settings(reset_snapshot="baseline-a"))
    vm = service.validation.select_vms(["vm1"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None

    result = ResultBuilder("automation")
    service._restore_clean_snapshot(result, profile)  # noqa: SLF001

    assert calls == [
        ("locate", 500, None),
        ("assert", 500, "baseline-a"),
        ("rollback", 500, "baseline-a"),
        ("verify", 500, "baseline-a"),
    ]
    assert result.steps[-1].step == "automation.reset_vm_done"
    assert "VM500 reset completed" in result.steps[-1].message


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

        def verify_rollback_state(
            self,
            _node: str,
            vmid: int,
            snapshot: str,
            *,
            require_running: bool,
        ) -> dict[str, object]:
            assert require_running
            calls.append(("verify", vmid, snapshot))
            return {"snapshot_parent": snapshot, "status": "running", "qmpstatus": "running"}

    monkeypatch.setattr(automation_module, "ProxmoxClient", FakeProxmox)
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None

    result = ResultBuilder("automation")
    service._restore_clean_snapshot(result, profile)  # noqa: SLF001

    assert calls == [
        ("locate", 502, None),
        ("assert", 502, service.settings.reset_snapshot),
        ("rollback", 502, service.settings.reset_snapshot),
        ("verify", 502, service.settings.reset_snapshot),
    ]
    assert result.steps[-1].step == "automation.reset_vm_done"
    assert "VM502 reset completed" in result.steps[-1].message


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

        def verify_rollback_state(
            self,
            _node: str,
            vmid: int,
            snapshot: str,
            *,
            require_running: bool,
        ) -> dict[str, object]:
            assert require_running
            calls.append(("verify", vmid, snapshot))
            return {"snapshot_parent": snapshot, "status": "running", "qmpstatus": "running"}

    monkeypatch.setattr(automation_module, "ProxmoxClient", FakeProxmox)
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None

    result = ResultBuilder("automation")
    service._restore_clean_snapshot(result, profile)  # noqa: SLF001

    assert calls == [
        ("locate", 501, None),
        ("assert", 501, service.settings.reset_snapshot),
        ("rollback", 501, service.settings.reset_snapshot),
        ("verify", 501, service.settings.reset_snapshot),
    ]
    assert result.steps[-1].step == "automation.reset_vm_done"
    assert "VM501 reset completed" in result.steps[-1].message


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
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    service = AutomationService(settings(capture_dir=tmp_path))
    monkeypatch.setattr(service.vnc, "connect", lambda _address: fake_client)
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
        lambda _result, source: PurePosixPath("/srv/libertix-smb/Libertix-release/Libertix.exe"),
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
        lambda _result, source: PurePosixPath("/srv/libertix-smb/Libertix-release/Libertix.exe"),
    )

    def fake_validate_vm(*_args, **_kwargs):
        (service._capture_dir / "proof.png").write_bytes(b"capture")  # noqa: SLF001
        return ResultBuilder("validation").success("ok")

    monkeypatch.setattr(service, "_validate_vm_isolated", fake_validate_vm)

    result = service.run(["vm1"], source="local")

    assert result.status == "ok"
    assert list(tmp_path.iterdir()) == []


@pytest.mark.parametrize(
    ("shutdown", "advanced"),
    [
        ("Shutdown", "Advanced options"),
        ("Éteindre", "Options avancées"),
        ("Apagar", "Opciones avanzadas"),
        ("シャットダウン", "詳細オプション"),
    ],
)
def test_automation_monitor_stops_only_on_the_installed_boot_menu(
    shutdown: str,
    advanced: str,
) -> None:
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
            f"Linux Mint 22.3 Cinnamon  Windows Boot Manager  {shutdown}  {advanced}",
        )
        is True
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Linux Mint 22.3 Cinnamon\nWindows\nShutdown\nAdvanced options",
        )
        is True
    )
    assert (
        service._reboot_or_live_started(  # noqa: SLF001
            "Linux Mint 22.3 Cinnamon\nWindows\nAdvanced options",
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
    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
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


def test_automation_monitor_retries_a_restart_prompt_instead_of_calling_it_linux(
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
                summary="Preparation complete; restart control visible.",
                visible_text="Libertix 100% Redémarrer",
            ),
            InstallProgressVerdict(
                iso_download_finished=True,
                installation_finished=True,
                reboot_prompt_visible=True,
                still_in_progress=False,
                error_visible=False,
                summary="The Libertix installer still shows its restart control.",
                visible_text="Redémarrer",
            ),
            InstallProgressVerdict(
                iso_download_finished=True,
                installation_finished=False,
                reboot_prompt_visible=False,
                still_in_progress=False,
                error_visible=False,
                summary="The installed boot menu is visible.",
                visible_text="Linux Mint 22.3 Cinnamon\nWindows\nShutdown\nAdvanced options",
            ),
        )
    )
    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
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

    outcome = service._monitor_until_live_boot(vm, result, "bios")  # noqa: SLF001

    assert outcome == "boot-menu"
    assert reboot_clicks == ["vm1", "vm1"]
    assert any(step.step == "automation.reboot_retry" for step in result.steps)
    assert not any(step.step == "automation.installation_finished" for step in result.steps)


def test_linux_desktop_evidence_rejects_the_windows_restart_prompt() -> None:
    service = AutomationService(settings())

    assert service._installed_linux_desktop_seen(  # noqa: SLF001
        "Bienvenue à Linux Mint 22.3 Cinnamon desktop"
    )
    assert not service._installed_linux_desktop_seen(  # noqa: SLF001
        "Libertix 100% Redémarrer"
    )


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
                visible_text=("Linux Mint 22.3 Cinnamon\nWindows\nShutdown\nAdvanced options"),
            ),
        )
    )
    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
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
                    "Linux Mint 22.3 Cinnamon\nWindows Boot Manager\nShutdown\nAdvanced options"
                ),
            ),
        )
    )
    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
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
    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
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
    assert "verified rollback" in raised.value.message
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
    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
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
    assert "incomplete rollback" in raised.value.message


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
    assert "set_bios_boot_flags_or_die" in installer
    assert 'sfdisk --lock --activate "$DISK" "$partition_number"' in bios_adapter
    assert "only_mbr_partition_has_boot_flag" in bios_adapter
    assert "final verify: Windows boot partition is not active" in bios_adapter
    assert "bootPartitionOffset = [long]$boot.Offset" in preflight

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

    for path in ("iso/live/libertix-install.sh", "iso-uefi/live/libertix-install.sh"):
        wrapper = read_repo(path)
        assert "libertix-install-main.sh" in wrapper

    installer = read_repo("assets/live/libertix-install-main.sh")
    assert "resolve_target_disk_from_manifest" in installer
    assert "WINDOWS_PARTITION_OFFSET_BYTES" in installer
    assert "INSTALLER_PARTITION_OFFSET_BYTES" in installer
    assert "RECOVERY_PARTITION_OFFSET_BYTES" in installer
    assert "RECOVERY_PARTITION_SIZE_BYTES" in installer
    assert 'NEW_PART="$LIVE_PART"' in installer
    assert "ntfsresize" not in installer
    assert "mkpart primary ext4" not in installer
    assert 'parted "$DISK" unit MB print free' not in installer


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
    method_start = source.index("private void ArmUefiRecoveryAgent")
    method_end = source.index("private static string WriteProtectedUefiConfig", method_start)
    assert '"/SC ONSTART /RU SYSTEM' not in source[method_start:method_end]


def test_recovery_is_armed_before_any_bitlocker_mutation() -> None:
    workflow = read_repo("Pages/ApplyChanges.xaml.cs")
    bios = read_repo("Pages/ApplyChanges.Bios.cs")
    uefi = read_repo("Pages/ApplyChanges.Uefi.cs")
    installer = read_repo("Scripts/libertix-uefi-install.ps1")
    transaction = read_repo("Scripts/uefi/Libertix.Uefi.Transaction.ps1")

    assert workflow.index("decryptBitLocker: false") < workflow.index(
        "ExecuteUefiInstallationAsync"
    )
    assert bios.index("CompleteExecutionStep(InstallationStep.WindowsRecoveryArmed)") < (
        bios.index("decryptBitLocker: true")
    )
    assert uefi.index("ArmUefiRecoveryAgent(recovery, powershell)") < uefi.index(
        "RunStreamingProcessAsync"
    )
    assert "SkipInstaller" not in installer
    assert "Assert-LibertixTransactionRecoveryRunId" in transaction
    assert "-ExpectedRecoveryRunId" in installer


def test_bios_recovery_payload_includes_atomic_state_dependency() -> None:
    source = read_repo("Pages/ApplyChanges.Windows.cs")
    method_start = source.index("private async Task<bool> InstallWindowsRecoveryGuardAsync")
    method_end = source.index("private async Task<double> QueryShrinkSpaceAsync", method_start)
    method = source[method_start:method_end]

    assert '"Libertix.InstallationState.psm1"' in method
    assert method.count('"Libertix.AtomicFile.psm1"') == 2


def test_bios_live_ledger_is_detached_before_drive_letter_removal() -> None:
    bios = read_repo("Pages/ApplyChanges.Bios.cs")
    method = bios.split("private async Task<bool> PrepareBiosTemporaryBootAsync()", 1)[1].split(
        "private async Task<bool> RemoveBiosInstallerAccessPathAsync()", 1
    )[0]

    completed = method.index("CompleteExecutionStep(InstallationStep.WindowsTemporaryBootPrepared)")
    detached = method.index("_executionLedger.SetMirrorPath(null)")
    access_path_removed = method.index("await RemoveBiosInstallerAccessPathAsync()")

    assert completed < detached < access_path_removed


def test_bios_recovery_task_is_not_clock_boundary_dependent() -> None:
    script = read_repo("Scripts/libertix-register-bios-recovery-task.ps1")
    source = apply_changes_source()

    assert "New-ScheduledTaskTrigger -AtStartup" in script
    assert "-StartWhenAvailable" in script
    assert "StartBoundary" in script
    assert "IsNullOrWhiteSpace" in script
    assert "libertix-register-bios-recovery-task.ps1" in source
    method_start = source.index("private async Task<bool> InstallWindowsRecoveryGuardAsync")
    method_end = source.index("private async Task<double> QueryShrinkSpaceAsync", method_start)
    method = source[method_start:method_end]
    assert '"schtasks.exe"' not in method
    assert '"/SC ONSTART' not in method


def test_windows_finalization_transport_outlives_its_guest_deadline() -> None:
    assert windows_validation_timeout_seconds("finalization") == 420
    assert windows_validation_timeout_seconds("sfc_verify_only") == 1800
    assert windows_validation_timeout_seconds("chkdsk_scan") == 1800
    assert windows_validation_timeout_seconds("identity") == 300


def test_wpf_storage_preflight_fails_closed() -> None:
    source = apply_changes_source()
    preflight = read_repo("Scripts/libertix-storage-preflight.ps1")

    assert "DetectFirmwareTypeOrThrow" in source
    assert "Installation was stopped before any disk change" in source
    assert "systemDiskNumber = [int]$partition.DiskNumber" in preflight
    assert "bitLockerSafe = [bool]$bitLocker.Safe" in preflight
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
    assert {
        "linux.hostname",
        "linux.locale",
        "linux.keyboard",
        "linux.timezone",
        "linux.root_uuid",
        "linux.ssh_security",
        "linux.development_profile",
        "linux.boot_mode_files",
        "linux.grub_regeneration",
        "linux.running_kernel_artifacts",
        "linux.initramfs_integrity",
        "linux.sharing_policy",
        "linux.desktop_stack",
        "linux.first_boot_cleanup",
        "linux.system_resources",
    } <= set(tests)
    assert "linux.time_sync" in tests
    assert "linux.package_database" in tests
    assert "linux.package_dependencies" in tests
    assert "linux.name_resolution" in tests
    assert tests[-1] == "linux.name_resolution"
    assert (
        next(step for step in result.steps if step.context["test"] == "linux.time_sync").status
        == "error"
    )
    assert len(ssh.calls) == len(tests)
    sudo_calls = [(command, kwargs) for command, kwargs in ssh.calls if command.startswith("sudo ")]
    assert len(sudo_calls) == 10
    assert all(
        command.startswith("sh -eu -c ") or command.startswith("sudo -S -p '' sh -eu -c ")
        for command, _kwargs in ssh.calls
    )
    assert all("test-passphrase" not in command for command, _kwargs in sudo_calls)
    assert all(kwargs["stdin_data"] == "test-passphrase\n" for _command, kwargs in sudo_calls)
    sharing_policy_call = next(
        (command, kwargs) for command, kwargs in sudo_calls if "share-linux-in-windows" in command
    )
    assert sharing_policy_call[0].startswith("sudo -S -p '' sh -eu -c ")
    commands = "\n".join(command for command, _kwargs in ssh.calls)
    grub_regeneration_command = next(
        command for command, _kwargs in ssh.calls if "update-grub" in command
    )
    grub_regeneration_script = shlex.split(grub_regeneration_command)[-1]
    syntax = subprocess.run(
        ["sh", "-n", "-c", grub_regeneration_script],
        capture_output=True,
        check=False,
        text=True,
    )
    assert syntax.returncode == 0, syntax.stderr
    time_sync_call = next(
        (command, kwargs) for command, kwargs in ssh.calls if "NTPSynchronized" in command
    )
    assert "timeout 5s timedatectl show" in time_sync_call[0]
    assert "timeout 5s timedatectl status" in time_sync_call[0]
    assert time_sync_call[1]["timeout"] == 150
    assert "address1=192.0.2.240/24,192.0.2.1" in commands
    assert "default via 192.0.2.1" in commands
    assert "8.8.8.8" in commands
    assert "1.1.1.1" in commands


def test_linux_post_install_check_requires_selected_distribution_identity() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    result = ResultBuilder("automation")

    class FakeSSH:
        def __init__(self) -> None:
            self.commands: list[str] = []

        def run(self, command: str, **_kwargs: object) -> CommandResult:
            self.commands.append(command)
            return CommandResult(stdout="diagnostic", stderr="", exit_code=0)

    ssh = FakeSSH()
    options = AutomationOptions(
        True,
        "test",
        "test-passphrase",
        True,
        distribution=load_distribution_profile("zorin"),
    )

    service._run_linux_checks(ssh, vm, options, result)  # type: ignore[arg-type]  # noqa: SLF001

    os_release_command = next(command for command in ssh.commands if "VERSION_ID" in command)
    os_release_script = shlex.split(os_release_command)[-1]
    assert 'test "$ID" = zorin' in os_release_script
    os_release_result = next(
        step for step in result.steps if step.context["test"] == "linux.os_release"
    )
    assert os_release_result.status == "ok"


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

        def keyDown(self, key: str) -> None:  # noqa: N802
            self.events.append(("key_down", key))

        def keyUp(self, key: str) -> None:  # noqa: N802
            self.events.append(("key_up", key))

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
            visible_text=(
                "Linux Mint 22.3 Cinnamon\nWindows Boot Manager\nShutdown\nAdvanced options"
            ),
        ),
    )
    monkeypatch.setattr(service.vnc, "connect", lambda _address: vnc)
    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)

    selected = service._select_grub_entry_if_visible(  # noqa: SLF001
        vm, result, "windows", 3
    )

    assert selected is True
    assert vnc.events == [
        ("mouse", (5, 5)),
        ("key", "home"),
        ("key", "down"),
        ("key_down", "enter"),
        ("key_up", "enter"),
        ("disconnect", None),
    ]
    assert result.steps[-1].context["phase"] == "windows-boot"
    assert result.steps[-1].message == "Sent the windows selection from the installed GRUB menu"


def test_installed_grub_theme_is_detected_from_stable_local_colors(tmp_path: Path) -> None:
    grub_capture = tmp_path / "grub.png"
    image = Image.new("RGB", (1280, 800), (34, 33, 52))
    draw = ImageDraw.Draw(image)
    draw.rectangle((320, 200, 960, 250), fill=(66, 66, 82))
    image.save(grub_capture)

    unrelated_capture = tmp_path / "unrelated.png"
    Image.new("RGB", (1280, 800), (11, 16, 32)).save(unrelated_capture)

    assert AutomationService._installed_grub_theme_visible(grub_capture) is True
    assert AutomationService._installed_grub_theme_visible(unrelated_capture) is False


def test_grub_ready_wait_requires_two_local_theme_frames_before_typing(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    result = ResultBuilder("automation")
    grub_capture = tmp_path / "grub.png"
    Image.new("RGB", (1280, 800), (34, 33, 52)).save(grub_capture)
    captures: list[str] = []
    sent: list[str] = []
    theme_frames = iter((False, True, True))

    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: captures.append(label) or grub_capture,
    )
    monkeypatch.setattr(
        service,
        "_installed_grub_theme_visible",
        lambda _capture: next(theme_frames),
    )
    monkeypatch.setattr(
        service,
        "_send_grub_entry",
        lambda _vm, _result, entry: sent.append(entry) or True,
    )
    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)

    selected = service._select_grub_entry_when_theme_ready(  # noqa: SLF001
        vm,
        result,
        "windows",
        distribution=load_distribution_profile("mint"),
    )

    assert selected is True
    assert len(captures) == 3
    assert sent == ["windows"]


def test_wait_for_ssh_retries_a_still_visible_grub_menu(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(
        settings(
            post_install_boot_timeout_seconds=1,
            post_install_poll_interval_seconds=0.001,
        )
    )
    vm = service.validation.select_vms(["vm3"])[0]
    result = ResultBuilder("automation")
    connection_attempts = {"count": 0}
    ready_selections: list[str] = []
    selection_attempts: list[int] = []

    class FakeSSH:
        def __init__(self, *_args, **_kwargs) -> None:
            pass

        def __enter__(self):
            connection_attempts["count"] += 1
            return self

        def run(self, *_args, **_kwargs) -> CommandResult:
            if connection_attempts["count"] < 7:
                raise WorkflowError("probe", "Target OS is not ready")
            return CommandResult(stdout="READY\n", stderr="", exit_code=0)

        def __exit__(self, *_args) -> None:
            pass

    monkeypatch.setattr(automation_postinstall_module, "SSHClient", FakeSSH)
    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_select_grub_entry_when_theme_ready",
        lambda _vm, _result, entry, **_kwargs: ready_selections.append(entry) or True,
    )
    monkeypatch.setattr(
        service,
        "_select_grub_entry_if_visible",
        lambda _vm, _result, _entry, attempt, **_kwargs: selection_attempts.append(attempt) or True,
    )

    client = service._wait_for_ssh(  # noqa: SLF001
        vm,
        result=result,
        username="admin",
        password="secret",
        trust_on_first_use=False,
        probe="echo READY",
        expected="READY",
        phase="windows_final",
        grub_entry="windows",
    )

    assert isinstance(client, FakeSSH)
    assert connection_attempts["count"] == 7
    assert ready_selections == ["windows"]
    assert selection_attempts == [3, 6]


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


def test_final_windows_reboot_uses_a_distinct_result_name() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    result = ResultBuilder("automation")

    class FakeSSH:
        def run(self, _command: str, **_kwargs) -> CommandResult:
            return CommandResult(stdout="", stderr="", exit_code=0)

    service._request_windows_boot(  # type: ignore[arg-type]  # noqa: SLF001
        FakeSSH(),
        vm,
        AutomationOptions(True, "test", "test-passphrase", True),
        result,
        test_name="linux.final_windows_reboot",
    )

    assert result.steps[-1].context["test"] == "linux.final_windows_reboot"
    assert result.steps[-1].message == "linux.final_windows_reboot: OK"


def test_windows_post_install_checks_continue_after_one_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    result = ResultBuilder("automation")
    called: list[str] = []
    timeouts: dict[str, float] = {}

    def fake_run_windows_script(_ssh, *, config, timeout, **_kwargs) -> CommandResult:
        called.append(config["check"])
        timeouts[config["check"]] = timeout
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
    assert timeouts["identity"] == 300
    assert timeouts["sfc_verify_only"] == 1800
    assert timeouts["chkdsk_scan"] == 1800


def test_windows_validation_plan_keeps_conditional_sharing_checks_declarative() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    artifacts = CrossOsArtifacts(
        windows_relative_path=r"Users\Public\Documents\probe.bin",
        windows_sha256="a" * 64,
        linux_relative_path="probe.bin",
        linux_sha256="b" * 64,
    )
    options = AutomationOptions(
        True,
        "test",
        "test-passphrase",
        True,
        distribution=load_distribution_profile("zorin"),
        share_windows_files_in_linux=False,
        share_linux_files_in_windows=False,
    )

    plan = build_windows_validation_plan(vm, options, artifacts)

    assert "sharing_disabled" in plan.check_names
    assert "cross_os_hash" not in plan.check_names
    assert "ext4_driver" not in plan.check_names
    assert plan.check_names[-3:] == ("dism_check_health", "sfc_verify_only", "chkdsk_scan")
    assert plan.base_config["installer_iso_file_name"] == "zorin.iso"
    assert plan.base_config["expected_firmware"] == vm.firmware


def test_cross_os_artifacts_are_removed_after_their_checks() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    result = ResultBuilder("automation")
    commands: list[str] = []

    class FakeSSH:
        def run(self, command: str, **_kwargs) -> CommandResult:
            commands.append(command)
            return CommandResult(stdout="", stderr="", exit_code=0)

    options = AutomationOptions(True, "test", "test-passphrase", True)
    artifacts = CrossOsArtifacts(
        windows_relative_path=(r"Users\Public\Documents\libertix-auto-test-0123456789abcdef.bin"),
        windows_sha256="a" * 64,
        linux_relative_path="libertix-auto-test-fedcba9876543210.bin",
        linux_sha256="b" * 64,
    )

    service._cleanup_windows_cross_os_artifact(  # noqa: SLF001
        FakeSSH(), vm, options, artifacts, result
    )
    service._cleanup_linux_cross_os_artifact(  # noqa: SLF001
        FakeSSH(), vm, options, artifacts, result
    )

    assert "del /f /q C:\\Users\\Public\\Documents\\libertix-auto-test-" in commands[0]
    assert "rm -f -- /home/test/libertix-auto-test-" in commands[1]
    assert [step.context["test"] for step in result.steps] == [
        "sharing.windows_artifact_cleanup",
        "sharing.linux_artifact_cleanup",
    ]
    assert all(step.status == "ok" for step in result.steps)


def test_cross_os_artifact_cleanup_failure_is_reported() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    result = ResultBuilder("automation")

    class FakeSSH:
        def run(self, _command: str, **_kwargs) -> CommandResult:
            return CommandResult(stdout="", stderr="file remains", exit_code=1)

    service._cleanup_linux_cross_os_artifact(  # noqa: SLF001
        FakeSSH(),
        vm,
        AutomationOptions(True, "test", "test-passphrase", True),
        CrossOsArtifacts("unused", "", "probe.bin", "b" * 64),
        result,
    )

    assert result.steps[-1].status == "error"
    assert result.steps[-1].context["test"] == "sharing.linux_artifact_cleanup"


def test_windows_script_cleanup_does_not_mask_the_primary_failure() -> None:
    service = AutomationService(settings())

    class FailingSSH:
        host = "example.test"

        def __init__(self) -> None:
            self.run_count = 0

        def upload_text(self, *_args, **_kwargs) -> None:
            pass

        def run(self, *_args, **_kwargs) -> CommandResult:
            self.run_count += 1
            if self.run_count == 1:
                raise WorkflowError(
                    "automation.test.windows",
                    "Primary Windows check timeout",
                    details={"exception_type": "TimeoutError"},
                )
            raise WorkflowError(
                "automation.test.windows.cleanup_script",
                "Cleanup transport is closed",
                details={"exception_type": "EOFError"},
            )

    ssh = FailingSSH()
    with pytest.raises(WorkflowError) as caught:
        service.validation.run_windows_script(  # type: ignore[arg-type]
            ssh,
            script_name="post_install_windows_check.ps1",
            config={"check": "sfc_verify_only"},
            step="automation.test.windows",
            timeout=1800,
        )

    assert caught.value.message == "Primary Windows check timeout"
    assert caught.value.details["exception_type"] == "TimeoutError"
    assert ssh.run_count == 2


def test_windows_script_cleans_the_script_when_config_upload_fails() -> None:
    service = AutomationService(settings())

    class ConfigUploadFailureSSH:
        host = "example.test"

        def __init__(self) -> None:
            self.upload_count = 0
            self.cleanup_commands: list[str] = []

        def upload_text(self, *_args, **_kwargs) -> None:
            self.upload_count += 1
            if self.upload_count == 2:
                raise WorkflowError("upload", "Config upload failed")

        def run(self, command: str, **_kwargs) -> CommandResult:
            self.cleanup_commands.append(command)
            return CommandResult(stdout="", stderr="", exit_code=0)

    ssh = ConfigUploadFailureSSH()
    with pytest.raises(WorkflowError, match="Config upload failed"):
        service.validation.run_windows_script(  # type: ignore[arg-type]
            ssh,
            script_name="post_install_windows_check.ps1",
            config={"samba_password": "must-not-remain"},
            step="automation.test.windows",
            timeout=1800,
        )

    assert ssh.upload_count == 2
    assert len(ssh.cleanup_commands) == 1
    assert "Remove-Item" in ssh.cleanup_commands[0]


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
    assert 'NextHop -contains "192.0.2.1"' not in script
    assert {
        "final_state",
        "finalization",
        "identity",
        "firmware",
        "system_volume",
        "system_resources",
        "partition_layout",
        "boot_partition",
        "boot_configuration",
        "recovery",
        "bitlocker",
        "temporary_artifacts",
        "network",
        "locale",
        "ssh_service",
        "core_services",
        "hibernation",
        "ext4_driver",
        "ext4_readonly_mount",
        "linux_home",
        "linux_home_hash",
        "ext4_write_denied",
        "explorer_shortcut",
        "sharing_tasks",
        "cross_os_hash",
        "dism_check_health",
        "sfc_verify_only",
        "chkdsk_scan",
    } <= implemented


def test_final_windows_state_check_excludes_slow_health_scans() -> None:
    script = read_repo("auto_tests/app/scripts/post_install_windows_check.ps1")
    start = script.index('        "final_state" {')
    end = script.index('        "identity" {', start)
    final_state = script[start:end].casefold()

    assert "get-ciminstance win32_operatingsystem" in final_state
    assert "get-computerinfo" in final_state
    assert "get-volume" in final_state
    assert "get-netipaddress" in final_state
    assert "get-service" in final_state
    assert "bcdedit.exe" in final_state
    assert "dism.exe" not in final_state
    assert "sfc.exe" not in final_state
    assert "chkdsk.exe" not in final_state
