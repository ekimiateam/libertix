import base64
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
from app.clients.vnc import VNCClient
from app.config import Settings
from app.distributions import load_distribution_profile
from app.errors import WorkflowError
from app.models import ValidationRequest
from app.services.automation import AutomationService
from app.services.automation_postinstall import CrossOsArtifacts, RemoteCheck
from app.services.automation_types import AutomationOptions
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


def test_apply_changes_reboot_is_a_focused_keyboard_default() -> None:
    xaml = read_repo("Pages/ApplyChanges.xaml")
    bios = read_repo("Pages/ApplyChanges.Bios.cs")
    uefi = read_repo("Pages/ApplyChanges.Uefi.cs")

    reboot_button = xaml.split('<Button x:Name="RebootButton"', maxsplit=1)[1].split(
        "/>\n",
        maxsplit=1,
    )[0]
    assert 'KeyboardNavigation.TabNavigation="Cycle"' in xaml
    assert 'AutomationProperties.AutomationId="ApplyChangesRebootButton"' in reboot_button
    visible_and_focused = (
        "RebootButton.Visibility = Visibility.Visible;\n"
        "            RebootButton.IsDefault = true;\n"
        "            RebootButton.Focus();"
    )
    assert visible_and_focused in bios
    assert visible_and_focused in uefi


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
        ("filepool_dir_name", "../outside"),
        ("filepool_dir_name", "nested/path"),
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


def test_local_filepool_sync_uploads_changed_artifacts_atomically(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    repository = tmp_path / "repository"
    filepool = repository / "auto_tests" / "app" / "filepool"
    filepool.mkdir(parents=True)
    for name, payload in {
        "catalog.json": b"versioned-catalog",
        "libertix-installer-bios.iso": b"bios",
        "libertix-installer-uefi.iso": b"uefi",
    }.items():
        (filepool / name).write_bytes(payload)
    runtime_dir = tmp_path / "runtime"
    runtime_catalog = runtime_dir / "filepool" / "catalog.json"
    runtime_catalog.parent.mkdir(parents=True)
    runtime_catalog.write_bytes(b"runtime-catalog")

    class FakeSSH:
        host = "192.0.2.208"

        def __init__(self) -> None:
            self.commands: list[tuple[str, str]] = []
            self.uploads: list[tuple[Path, str, str]] = []

        def run(self, command: str, *, step: str, **_kwargs: object) -> CommandResult:
            self.commands.append((step, command))
            return CommandResult(stdout="", stderr="", exit_code=0)

        def upload_file(self, local: Path, remote: str, *, step: str) -> None:
            self.uploads.append((local, remote, step))

    service = ValidationService(
        settings(runtime_dir=runtime_dir, capture_dir=runtime_dir / "captures")
    )
    monkeypatch.setattr(service, "_local_repository_root", lambda: repository)
    ssh = FakeSSH()
    result = ResultBuilder("validation")

    service._sync_local_filepool_to_server(ssh, result)  # noqa: SLF001

    assert [item[0].name for item in ssh.uploads] == [
        "catalog.json",
        "libertix-installer-bios.iso",
        "libertix-installer-uefi.iso",
    ]
    assert ssh.uploads[0][0] == runtime_catalog
    assert all(item[2] == "server.filepool_upload" for item in ssh.uploads)
    publish_commands = [
        command for step, command in ssh.commands if step == "server.filepool_publish"
    ]
    assert len(publish_commands) == 3
    assert all("sha256sum" in command and "stat -c %s" in command for command in publish_commands)
    assert all("mv -f" in command for command in publish_commands)
    assert any(step == "server.filepool_http_probe" for step, _command in ssh.commands)
    assert result.steps[-1].step == "server.filepool_sync"
    assert result.steps[-1].context["copied"] == 3
    assert result.steps[-1].context["reused"] == 0


def test_local_filepool_sync_reuses_matching_remote_artifacts(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    repository = tmp_path / "repository"
    filepool = repository / "auto_tests" / "app" / "filepool"
    filepool.mkdir(parents=True)
    artifacts = {
        "catalog.json": b"catalog",
        "libertix-installer-bios.iso": b"bios",
        "libertix-installer-uefi.iso": b"uefi",
    }
    for name, payload in artifacts.items():
        (filepool / name).write_bytes(payload)
    expected_hashes = iter(
        hashlib.sha256(artifacts[name]).hexdigest() for name in sorted(artifacts)
    )

    class FakeSSH:
        host = "192.0.2.208"

        def __init__(self) -> None:
            self.uploads: list[tuple[Path, str, str]] = []

        def run(self, _command: str, *, step: str, **_kwargs: object) -> CommandResult:
            stdout = next(expected_hashes) if step == "server.filepool_hash" else ""
            return CommandResult(stdout=stdout, stderr="", exit_code=0)

        def upload_file(self, local: Path, remote: str, *, step: str) -> None:
            self.uploads.append((local, remote, step))

    runtime_dir = tmp_path / "runtime"
    service = ValidationService(
        settings(runtime_dir=runtime_dir, capture_dir=runtime_dir / "captures")
    )
    monkeypatch.setattr(service, "_local_repository_root", lambda: repository)
    ssh = FakeSSH()
    result = ResultBuilder("validation")

    service._sync_local_filepool_to_server(ssh, result)  # noqa: SLF001

    assert ssh.uploads == []
    assert result.steps[-1].context["copied"] == 0
    assert result.steps[-1].context["reused"] == 3


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("ssh_timeout_seconds", 0),
        ("command_timeout_seconds", -1),
        ("llm_max_attempts", 0),
        ("proxmox_task_timeout_seconds", 0),
        ("automation_monitor_interval_seconds", 0),
        ("automation_operation_timeout_seconds", 0),
        ("automation_stall_timeout_seconds", 0),
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
    assert configured.automation_operation_timeout_seconds == 1800


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
            assert require_running
            return {"snapshot_parent": snapshot, "status": "running", "qmpstatus": "running"}

    monkeypatch.setattr("app.services.reset.ProxmoxClient", FakeProxmox)
    service = ResetService(settings())
    service.automation_preflight.configure_windows_guest_network = (  # type: ignore[method-assign]
        lambda _proxmox, _node, profile: {"ipv4": profile.vm_host}
    )
    result = ResultBuilder("reset")

    service._restore_snapshots(  # noqa: SLF001
        {vmid: "node-a" for vmid in selected},
        selected,
        result,
    )

    assert entered == set(selected)
    assert max_active == len(selected)
    rollback_steps = [step for step in result.steps if step.step == "proxmox.rollback"]
    network_steps = [step for step in result.steps if step.step == "reset.guest_network_ready"]
    assert sorted(step.context["target"] for step in rollback_steps) == ["500", "501", "502"]
    assert sorted(step.context["target"] for step in network_steps) == ["500", "501", "502"]


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


def test_validation_source_defaults_to_local() -> None:
    assert ValidationRequest().source == "local"


def test_validation_source_accepts_local() -> None:
    assert ValidationRequest(source="local").source == "local"


def test_validation_source_accepts_latest_published_dev_build() -> None:
    assert ValidationRequest(source="published").source == "published"


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
                "WINDOW_HANDLE=9876\nWINDOW_TITLE=Libertix\nWINDOW_VISIBLE=True\n"
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
    assert launch["window_handle"] == 9876
    assert launch["window_title"] == "Libertix"
    assert launch["window_visible"] is True
    assert launch["launch_method"] == "scheduled_task_elevated"


def test_process_confirmation_preserves_unattended_protocol_paths(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FakeSshContext:
        def __enter__(self) -> object:
            return object()

        def __exit__(self, *_args: object) -> None:
            return None

    service = ValidationService(settings())

    def fake_run_windows_script(
        *_args: object,
        script_name: str,
        **_kwargs: object,
    ) -> SimpleNamespace:
        if script_name == "launch_libertix_elevated.ps1":
            return SimpleNamespace(
                stdout=(
                    "UNATTENDED_STATUS_PATH=C:\\ProgramData\\Libertix\\Automation\\run.status.json\n"
                    "UNATTENDED_ACKNOWLEDGEMENT_PATH=C:\\ProgramData\\Libertix\\Automation\\run.ack\n"
                ),
                stderr="",
            )
        return SimpleNamespace(
            stdout=(
                "PID=1234\nSESSION_ID=2\nTASK_NAME=LibertixAutoInstall_vm1\n"
                "EXECUTABLE=Z:\\Libertix-release\\Libertix.exe\n"
                "WINDOW_HANDLE=9876\nWINDOW_TITLE=Libertix\nWINDOW_VISIBLE=True\n"
            ),
            stderr="",
        )

    monkeypatch.setattr(service, "ssh", lambda *_args, **_kwargs: FakeSshContext())
    monkeypatch.setattr(service, "run_windows_script", fake_run_windows_script)
    vm = service.select_vms(["vm1"])[0]

    values = service.launch_elevated_process(
        vm,
        PureWindowsPath("Z:/Libertix-release/Libertix.exe"),
        task_name="LibertixAutoInstall_vm1",
        step="automation.launch_elevated",
        unattended_config={"schemaVersion": 1},
    )

    assert values["PID"] == "1234"
    assert values["UNATTENDED_STATUS_PATH"].endswith("run.status.json")
    assert values["UNATTENDED_ACKNOWLEDGEMENT_PATH"].endswith("run.ack")


def test_validation_uses_process_identity_and_a_nonempty_capture_without_ai(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    service = ValidationService(settings(capture_dir=tmp_path, launch_wait_seconds=0.01))
    vm = service.select_vms(["vm1"])[0]
    captures: list[Path] = []

    monkeypatch.setattr(
        service,
        "deploy_to_documents",
        lambda *_args: PureWindowsPath("C:/Libertix.exe"),
    )
    monkeypatch.setattr(
        service,
        "_launch_interactive",
        lambda *_args, **_kwargs: {
            "pid": 1234,
            "window_handle": 9876,
            "window_title": "Libertix",
        },
    )

    def capture(_address: str, path: Path) -> None:
        captures.append(path)
        path.write_bytes(b"nonempty-vnc-proof")

    monkeypatch.setattr(service.vnc, "capture", capture)
    monkeypatch.setattr("app.services.validation.time.sleep", lambda _seconds: None)
    result = ResultBuilder("validation")

    service._validate_vm(vm, PureWindowsPath("Z:/Libertix.exe"), result)  # noqa: SLF001

    assert len(captures) == 1
    assert result.steps[-1].step == "vnc.capture"
    assert result.steps[-1].context["proof_source"] == "uia-visible-window-and-vnc-capture"
    assert result.steps[-1].context["window_handle"] == 9876


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
                "WINDOW_HANDLE=9876\nWINDOW_TITLE=Libertix\nWINDOW_VISIBLE=True\n"
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


def test_launch_interactive_rejects_an_offscreen_main_window(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    class FakeSshContext:
        def __enter__(self) -> object:
            return object()

        def __exit__(self, *_args: object) -> None:
            return None

    service = ValidationService(settings())

    def fake_run_windows_script(
        *_args: object, script_name: str, **_kwargs: object
    ) -> SimpleNamespace:
        assert script_name in {
            "launch_libertix_elevated.ps1",
            "confirm_libertix_process.ps1",
        }
        return SimpleNamespace(
            stdout=(
                "PID=1234\nSESSION_ID=2\nTASK_NAME=LibertixValidation_vm1\n"
                "EXECUTABLE=Z:\\Libertix-release\\Libertix.exe\n"
                "WINDOW_HANDLE=9876\nWINDOW_TITLE=Libertix\nWINDOW_VISIBLE=False\n"
            ),
            stderr="",
        )

    monkeypatch.setattr(service, "ssh", lambda *_args, **_kwargs: FakeSshContext())
    monkeypatch.setattr(service, "run_windows_script", fake_run_windows_script)
    vm = service.select_vms(["vm1"])[0]

    with pytest.raises(WorkflowError, match="interactive window were not confirmed"):
        service._launch_interactive(  # noqa: SLF001
            vm,
            PureWindowsPath("Z:/Libertix-release/Libertix.exe"),
            ResultBuilder("validation"),
        )


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
                "WINDOW_HANDLE=9876\nWINDOW_TITLE=Libertix\nWINDOW_VISIBLE=True\n"
            )
        )

    monkeypatch.setattr(service.validation, "ssh", lambda *_args, **_kwargs: FakeSshContext())
    monkeypatch.setattr(service.validation, "run_windows_script", fake_run_windows_script)

    launch = service._launch_elevated(  # noqa: SLF001
        vm,
        PureWindowsPath("Z:/Libertix-release/Libertix.exe"),
        AutomationOptions("test", "test-passphrase", True),
    )

    assert launch["pid"] == 1234
    assert launch["session_id"] == 2


def test_published_automation_launch_uses_the_embedded_filepool_channel(
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
        assert config["filepool_base_url"] is None
        return SimpleNamespace(
            stdout=(
                "PID=1234\nSESSION_ID=2\nTASK_NAME=LibertixAutoInstall_vm1\n"
                "EXECUTABLE=Z:\\Libertix-release\\Libertix.exe\n"
                "WINDOW_HANDLE=9876\nWINDOW_TITLE=Libertix\nWINDOW_VISIBLE=True\n"
            )
        )

    monkeypatch.setattr(service.validation, "ssh", lambda *_args, **_kwargs: FakeSshContext())
    monkeypatch.setattr(service.validation, "run_windows_script", fake_run_windows_script)

    launch = service._launch_elevated(  # noqa: SLF001
        vm,
        PureWindowsPath("Z:/Libertix-release/Libertix.exe"),
        AutomationOptions("test", "test-passphrase", True),
        use_default_filepool=True,
    )

    assert launch["pid"] == 1234
    assert launch["session_id"] == 2


def test_full_automation_launch_passes_unattended_values_without_a_password_argument(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    observed: dict[str, object] = {}

    def fake_launch(
        _vm: object,
        _executable: object,
        **kwargs: object,
    ) -> dict[str, str]:
        observed.update(kwargs)
        return {
            "PID": "1234",
            "SESSION_ID": "2",
            "WINDOW_HANDLE": "9876",
            "WINDOW_TITLE": "Libertix",
            "TASK_NAME": "LibertixAutoInstall_vm2",
            "UNATTENDED_STATUS_PATH": (
                r"C:\ProgramData\Libertix\Automation\unattended.status.json"
            ),
            "UNATTENDED_ACKNOWLEDGEMENT_PATH": (
                r"C:\ProgramData\Libertix\Automation\unattended.ack"
            ),
        }

    monkeypatch.setattr(service.validation, "launch_elevated_process", fake_launch)
    options = AutomationOptions(
        "test-linux",
        "pass",
        True,
        linux_size_gib=120,
        distribution=load_distribution_profile("zorin"),
        share_windows_files_in_linux=False,
        share_linux_files_in_windows=True,
        force_offline_ntfs_resize=True,
    )

    launch = service._launch_elevated(  # noqa: SLF001
        vm,
        PureWindowsPath("Z:/Libertix-release/Libertix.exe"),
        options,
    )

    assert observed["unattended_config"] == {
        "schemaVersion": 1,
        "distribution": "zorin",
        "linuxSizeGiB": 120,
        "linuxUsername": "test-linux",
        "linuxPassword": "pass",
        "computerName": "vm2-linux",
        "shareWindowsFilesInLinux": False,
        "shareLinuxFilesInWindows": True,
    }
    assert observed["force_offline_ntfs_resize"] is True
    assert "pass" not in " ".join(str(value) for value in launch.values())
    assert launch["unattended_status_path"].endswith("unattended.status.json")


def test_full_install_requires_the_unattended_stage_protocol() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None
    result = ResultBuilder("automation")

    with pytest.raises(WorkflowError) as raised:
        service._run_unattended_wizard(  # noqa: SLF001
            vm,
            AutomationOptions("test", "pass", True),
            result,
            launch={},
        )

    assert raised.value.step == "automation.unattended_protocol"


def test_unattended_coordination_reconnects_only_after_transport_failure() -> None:
    service = AutomationService(settings())

    class ReconnectingSsh:
        def __init__(self) -> None:
            self.calls = 0
            self.reconnections = 0

        def run(self, *_args: object, **_kwargs: object) -> CommandResult:
            self.calls += 1
            if self.calls == 1:
                raise WorkflowError(
                    "automation.unattended_status",
                    "Remote command execution failed",
                    details={"exception_type": "SSHException", "error": "session inactive"},
                )
            return CommandResult(stdout="STAGE=ready\n", stderr="", exit_code=0)

        def reconnect(self) -> None:
            self.reconnections += 1

    ssh = ReconnectingSsh()
    response = service._run_unattended_control_command(  # noqa: SLF001
        ssh,
        "read-status",
        step="automation.unattended_status",
        timeout=20,
        check=False,
    )

    assert response.stdout == "STAGE=ready\n"
    assert (ssh.calls, ssh.reconnections) == (2, 1)


def test_unattended_coordination_does_not_retry_remote_command_failure() -> None:
    service = AutomationService(settings())

    class FailedCommandSsh:
        def __init__(self) -> None:
            self.reconnections = 0

        def run(self, *_args: object, **_kwargs: object) -> CommandResult:
            raise WorkflowError(
                "automation.unattended_status",
                "Remote command failed",
                details={"exit_code": 1, "stderr": "invalid state"},
            )

        def reconnect(self) -> None:
            self.reconnections += 1

    ssh = FailedCommandSsh()
    with pytest.raises(WorkflowError):
        service._run_unattended_control_command(  # noqa: SLF001
            ssh,
            "read-status",
            step="automation.unattended_status",
            timeout=20,
        )

    assert ssh.reconnections == 0


def test_unattended_coordination_retries_a_failed_reconnection() -> None:
    service = AutomationService(settings())

    class RecoveringSsh:
        def __init__(self) -> None:
            self.calls = 0
            self.reconnections = 0

        def run(self, *_args: object, **_kwargs: object) -> CommandResult:
            self.calls += 1
            if self.calls == 1:
                raise WorkflowError(
                    "automation.unattended_status",
                    "Remote command execution failed",
                    details={"exception_type": "ConnectionResetError"},
                )
            return CommandResult(stdout="STAGE=ready\n", stderr="", exit_code=0)

        def reconnect(self) -> None:
            self.reconnections += 1
            if self.reconnections == 1:
                raise WorkflowError(
                    "ssh.connect",
                    "SSH connection failed",
                    details={"exception_type": "NoValidConnectionsError"},
                )

    ssh = RecoveringSsh()
    response = service._run_unattended_control_command(  # noqa: SLF001
        ssh,
        "read-status",
        step="automation.unattended_status",
        timeout=20,
        check=False,
    )

    assert response.stdout == "STAGE=ready\n"
    assert (ssh.calls, ssh.reconnections) == (2, 2)


def test_linux_remote_check_reconnects_after_transport_failure() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    result = ResultBuilder("automation")

    class ReconnectingSsh:
        def __init__(self) -> None:
            self.calls = 0
            self.reconnections = 0

        def run(self, *_args: object, **_kwargs: object) -> CommandResult:
            self.calls += 1
            if self.calls == 1:
                raise WorkflowError(
                    "automation.test.linux",
                    "Remote command execution failed",
                    details={"exception_type": "ConnectionResetError"},
                )
            return CommandResult(stdout="verified", stderr="", exit_code=0)

        def reconnect(self) -> None:
            self.reconnections += 1

    ssh = ReconnectingSsh()
    response = service._run_remote_check(  # noqa: SLF001
        ssh,
        vm,
        result,
        "linux",
        RemoteCheck("linux.transport_retry", "test -e /etc/os-release"),
    )

    assert response == CommandResult(stdout="verified", stderr="", exit_code=0)
    assert (ssh.calls, ssh.reconnections) == (2, 1)
    assert result.steps[-1].status == "ok"


def test_linux_remote_check_does_not_retry_a_remote_failure() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    result = ResultBuilder("automation")

    class FailedCommandSsh:
        def __init__(self) -> None:
            self.calls = 0
            self.reconnections = 0

        def run(self, *_args: object, **_kwargs: object) -> CommandResult:
            self.calls += 1
            return CommandResult(stdout="", stderr="contract failed", exit_code=1)

        def reconnect(self) -> None:
            self.reconnections += 1

    ssh = FailedCommandSsh()
    response = service._run_remote_check(  # noqa: SLF001
        ssh,
        vm,
        result,
        "linux",
        RemoteCheck("linux.real_failure", "false"),
    )

    assert response == CommandResult(stdout="", stderr="contract failed", exit_code=1)
    assert (ssh.calls, ssh.reconnections) == (1, 0)
    assert result.steps[-1].status == "error"


def test_windows_script_reconnects_after_transport_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())

    class ReconnectingSsh:
        def __init__(self) -> None:
            self.reconnections = 0

        def reconnect(self) -> None:
            self.reconnections += 1

    calls = 0
    delays: list[float] = []

    def fake_run_windows_script(*_args: object, **_kwargs: object) -> CommandResult:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise WorkflowError(
                "automation.test.windows",
                "Remote command ended without an SSH exit status",
                details={
                    "exception_type": "MissingExitStatus",
                    "error": "session closed during reboot",
                    "transport_error": True,
                },
            )
        return CommandResult(stdout="RESULT=OK", stderr="", exit_code=0)

    monkeypatch.setattr(service.validation, "run_windows_script", fake_run_windows_script)
    monkeypatch.setattr("app.services.automation_postinstall.time.sleep", delays.append)
    ssh = ReconnectingSsh()

    response = service._run_windows_script_resiliently(  # noqa: SLF001
        ssh,  # type: ignore[arg-type]
        script_name="post_install_windows_check.ps1",
        config={"check": "chkdsk_scan"},
        step="automation.test.windows",
        timeout=1800,
    )

    assert response == CommandResult(stdout="RESULT=OK", stderr="", exit_code=0)
    assert (calls, ssh.reconnections) == (2, 1)
    assert delays == [2]


def test_linux_script_reconnects_after_transport_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())

    class ReconnectingSsh:
        def __init__(self) -> None:
            self.reconnections = 0

        def reconnect(self) -> None:
            self.reconnections += 1

    calls = 0

    def fake_run_linux_script(*_args: object, **_kwargs: object) -> CommandResult:
        nonlocal calls
        calls += 1
        if calls == 1:
            raise WorkflowError(
                "automation.test.linux",
                "SSH text upload failed",
                details={"exception_type": "SSHException", "error": "Channel closed."},
            )
        return CommandResult(stdout="RESULT=OK", stderr="", exit_code=0)

    monkeypatch.setattr(service.validation, "run_linux_script", fake_run_linux_script)
    retry_delays: list[float] = []
    monkeypatch.setattr("app.services.automation_postinstall.time.sleep", retry_delays.append)
    ssh = ReconnectingSsh()

    response = service._run_linux_script_resiliently(  # noqa: SLF001
        ssh,  # type: ignore[arg-type]
        script_name="focus_linux_post_install_result.py",
        arguments=("--pid", "4321"),
        step="automation.test.linux",
        timeout=30,
    )

    assert response == CommandResult(stdout="RESULT=OK", stderr="", exit_code=0)
    assert (calls, ssh.reconnections) == (2, 1)
    assert retry_delays == [3]


def test_unattended_wizard_captures_and_acknowledges_every_stage(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    reported_stages = (
        "compatibility-running",
        "compatibility-passed",
        "configuration-distribution-applied",
        "configuration-disk-size-applied",
        "configuration-sharing-applied",
        "configuration-account-applied",
        "warning-ready",
        "warning-ready",
        "installation-started",
        "reboot-ready",
    )
    stage_index = {"value": 0}
    acknowledgements: list[str] = []

    class FakeSsh:
        def __enter__(self) -> "FakeSsh":
            return self

        def __exit__(self, *_args: object) -> None:
            return None

        def run(self, command: str, **_kwargs: object) -> CommandResult:
            if "ConvertFrom-Json" in command:
                index = stage_index["value"]
                stage_index["value"] += 1
                return CommandResult(
                    stdout=f"SEQUENCE={index + 1}\nSTAGE={reported_stages[index]}\n",
                    stderr="",
                    exit_code=0,
                )
            acknowledgements.append(command)
            return CommandResult(stdout="", stderr="", exit_code=0)

    captures: list[str] = []
    keyboard_events: list[tuple[str, str] | tuple[str, None]] = []

    class FakeVnc:
        def keyDown(self, key: str) -> None:  # noqa: N802
            keyboard_events.append(("down", key))

        def keyPress(self, key: str) -> None:  # noqa: N802
            keyboard_events.append(("press", key))

        def keyUp(self, key: str) -> None:  # noqa: N802
            keyboard_events.append(("up", key))

        def disconnect(self) -> None:
            keyboard_events.append(("disconnect", None))

    monkeypatch.setattr(service.validation, "ssh", lambda *_args, **_kwargs: FakeSsh())
    focus_calls: list[dict[str, object]] = []
    monkeypatch.setattr(
        service.validation,
        "run_windows_script",
        lambda _ssh, **kwargs: (
            focus_calls.append(kwargs) or CommandResult(stdout="RESULT=OK", stderr="", exit_code=0)
        ),
    )
    monkeypatch.setattr(service.vnc, "connect", lambda _address: FakeVnc())
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: captures.append(label) or Path(f"/tmp/{label}.png"),
    )
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda _client, _vm, label, _result: captures.append(label) or Path(f"/tmp/{label}.png"),
    )
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    result = ResultBuilder("automation")

    service._observe_unattended_wizard(  # noqa: SLF001
        vm,
        AutomationOptions("test", "test-passphrase", True),
        result,
        4321,
        r"C:\ProgramData\Libertix\Automation\run.status.json",
        r"C:\ProgramData\Libertix\Automation\run.ack",
    )

    assert captures == [
        f"wizard-{index:02d}-{stage}"
        if stage != "warning-ready"
        else f"wizard-{index:02d}-warning-ready-keyboard-{index - 6}"
        for index, stage in enumerate(reported_stages, 1)
    ] + ["reboot-ready", "reboot-confirm", "reboot-accepted"]
    assert len(acknowledgements) == len(reported_stages)
    assert len(focus_calls) == 2
    assert all(call["script_name"] == "focus_unattended_warning.ps1" for call in focus_calls)
    assert all(call["config"] == {"process_id": 4321} for call in focus_calls)
    assert [
        step.context["stage"] for step in result.steps if step.step == "automation.unattended_stage"
    ] == list(reported_stages)
    assert keyboard_events == (
        [
            ("press", "tab"),
            ("press", "enter"),
        ]
        * 2
        + [
            ("disconnect", None),
            ("press", "enter"),
            ("press", "enter"),
            ("disconnect", None),
        ]
    )


def test_bootnext_rollback_injection_is_proven_before_reboot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    calls: list[dict[str, object]] = []
    monkeypatch.setattr(
        service.validation,
        "run_windows_script",
        lambda _ssh, **kwargs: (
            calls.append(kwargs)
            or CommandResult(
                stdout=(
                    "FORCED_BOOTNEXT_FAILURE=True\n"
                    "STATE_PATH=C:\\state.json\n"
                    "STATE_PHASE=AwaitingReboot\n"
                    "WINDOWS_BOOT_ID=2026-08-17T12:00:00Z\n"
                    "RESULT=OK\n"
                ),
                stderr="",
                exit_code=0,
            )
        ),
    )
    result = ResultBuilder("automation")

    service._force_bootnext_failure(object(), vm, result)  # type: ignore[arg-type]  # noqa: SLF001

    assert calls == [
        {
            "script_name": "force_uefi_bootnext_failure.ps1",
            "config": {"timeout_seconds": 120},
            "step": "automation.bootnext_rollback.inject",
            "timeout": 150,
        }
    ]
    assert result.steps[-1].step == "automation.bootnext_rollback.inject"


def test_bootnext_rollback_skips_live_monitor_after_controlled_windows_reboot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    options = AutomationOptions(
        "test",
        "test-passphrase",
        True,
        boot_guardian_fault="bootnext-rollback",
    )
    monkeypatch.setattr(service, "_observe_unattended_wizard", lambda *_args: None)
    monkeypatch.setattr(
        service,
        "_monitor_until_live_boot",
        lambda *_args, **_kwargs: pytest.fail("the live monitor must not run"),
    )

    outcome = service._run_unattended_wizard(  # noqa: SLF001
        vm,
        options,
        ResultBuilder("automation"),
        {
            "pid": 42,
            "unattended_status_path": r"C:\status.json",
            "unattended_acknowledgement_path": r"C:\ack.json",
        },
    )

    assert outcome == "bootnext-fallback"


def test_unattended_warning_is_captured_before_keyboard_acceptance(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    events: list[str] = []
    client = SimpleNamespace(
        keyPress=lambda key: events.append(f"key:{key}"),
        disconnect=lambda: events.append("disconnect"),
    )
    monkeypatch.setattr(
        service.validation,
        "run_windows_script",
        lambda *_args, **_kwargs: (
            events.append("focus") or CommandResult(stdout="RESULT=OK", stderr="", exit_code=0)
        ),
    )
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda *_args: events.append("capture") or Path("warning.png"),
    )
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)

    capture = service._accept_unattended_warning_dialog(  # noqa: SLF001
        object(),  # type: ignore[arg-type]
        client,
        vm,
        ResultBuilder("automation"),
        4321,
        7,
        1,
    )

    assert capture == Path("warning.png")
    assert events == ["focus", "capture", "key:tab", "key:enter"]


def test_unattended_terminal_failure_is_reported_without_waiting_for_timeout() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    message = "Distribution catalog is invalid"
    encoded = base64.b64encode(message.encode("utf-8")).decode("ascii")

    class FakeSsh:
        def run(self, _command: str, **_kwargs: object) -> CommandResult:
            return CommandResult(
                stdout=(
                    "SEQUENCE=4\n"
                    "STAGE=failed\n"
                    "ERROR_CODE=distribution-catalog-load\n"
                    f"ERROR_MESSAGE_BASE64={encoded}\n"
                ),
                stderr="",
                exit_code=0,
            )

    with pytest.raises(WorkflowError) as raised:
        service._wait_for_unattended_stage(  # noqa: SLF001
            FakeSsh(),
            vm,
            r"C:\ProgramData\Libertix\Automation\run.status.json",
            3,
            ("configuration-distribution-applied",),
        )

    assert raised.value.step == "automation.unattended_failure"
    assert str(raised.value) == message
    assert raised.value.details["error_code"] == "distribution-catalog-load"


def test_unattended_windows_preparation_stops_on_a_visible_error(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]

    class FakeSsh:
        def run(self, _command: str, **_kwargs: object) -> CommandResult:
            return CommandResult(
                stdout="SEQUENCE=10\nSTAGE=installation-started\n",
                stderr="",
                exit_code=0,
            )

    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda *_args: Path("/tmp/windows-preparation-error.png"),
    )
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda *_args: InstallProgressVerdict(
            iso_download_finished=False,
            installation_finished=False,
            reboot_prompt_visible=False,
            still_in_progress=False,
            error_visible=True,
            summary="The Windows preparation screen shows an installation error.",
            visible_text="Installation failed",
        ),
    )
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    result = ResultBuilder("automation")

    with pytest.raises(WorkflowError) as raised:
        service._wait_for_unattended_stage(  # noqa: SLF001
            FakeSsh(),
            vm,
            r"C:\ProgramData\Libertix\Automation\run.status.json",
            10,
            ("reboot-ready",),
            observe_installation_progress=True,
            result=result,
        )

    assert raised.value.step == "automation.windows_preparation_progress"
    assert raised.value.details["error_visible"] is True


def test_unattended_windows_preparation_reports_a_visual_stall(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    service = AutomationService(
        settings(
            automation_monitor_interval_seconds=0.2,
            automation_stall_timeout_seconds=0.5,
        )
    )
    vm = service.validation.select_vms(["vm1"])[0]
    capture = tmp_path / "unchanged-windows-preparation.png"
    Image.new("RGB", (320, 200), (15, 25, 35)).save(capture)
    clock = {"now": 0.0}

    class FakeSsh:
        def run(self, _command: str, **_kwargs: object) -> CommandResult:
            return CommandResult(
                stdout="SEQUENCE=10\nSTAGE=installation-started\n",
                stderr="",
                exit_code=0,
            )

    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda *_args: capture,
    )
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda *_args: InstallProgressVerdict(
            iso_download_finished=False,
            installation_finished=False,
            reboot_prompt_visible=False,
            still_in_progress=True,
            error_visible=False,
            summary="Windows preparation remains active.",
            visible_text="Downloading the distribution ISO",
        ),
    )
    monkeypatch.setattr(
        automation_wizard_module.time,
        "monotonic",
        lambda: clock["now"],
    )
    monkeypatch.setattr(
        automation_wizard_module.time,
        "sleep",
        lambda seconds: clock.__setitem__("now", clock["now"] + seconds),
    )

    with pytest.raises(WorkflowError) as raised:
        service._wait_for_unattended_stage(  # noqa: SLF001
            FakeSsh(),
            vm,
            r"C:\ProgramData\Libertix\Automation\run.status.json",
            10,
            ("reboot-ready",),
            timeout_seconds=10,
            observe_installation_progress=True,
            result=ResultBuilder("automation"),
        )

    assert raised.value.step == "automation.progress_stalled"
    assert raised.value.details["phase"] == "windows-preparation"
    assert raised.value.details["capture"] == str(capture)
    assert raised.value.details["stalled_seconds"] >= 0.5


def test_unattended_windows_preparation_reports_vision_payment_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    responses = iter(
        (
            CommandResult(
                stdout="SEQUENCE=10\nSTAGE=installation-started\n",
                stderr="",
                exit_code=0,
            ),
            CommandResult(
                stdout="SEQUENCE=11\nSTAGE=reboot-ready\n",
                stderr="",
                exit_code=0,
            ),
        )
    )

    class FakeSsh:
        def run(self, _command: str, **_kwargs: object) -> CommandResult:
            return next(responses)

    def unavailable_vision(*_args: object) -> InstallProgressVerdict:
        raise WorkflowError(
            "llm.install_progress",
            "Vision provider payment required",
            details={"http_status": 402},
        )

    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda *_args: Path("/tmp/windows-preparation-progress.png"),
    )
    monkeypatch.setattr(service.vision_llm, "analyze_install_progress", unavailable_vision)
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    result = ResultBuilder("automation")

    with pytest.raises(WorkflowError) as raised:
        service._wait_for_unattended_stage(  # noqa: SLF001
            FakeSsh(),
            vm,
            r"C:\ProgramData\Libertix\Automation\run.status.json",
            10,
            ("reboot-ready",),
            observe_installation_progress=True,
            result=result,
        )

    assert raised.value.step == "automation.windows_preparation_vision_required"
    assert raised.value.details["http_status"] == 402
    assert raised.value.details["provider_step"] == "llm.install_progress"
    assert raised.value.details["capture"] == "/tmp/windows-preparation-progress.png"
    assert result.steps == []


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
                "WINDOWS_SETUP_REMINDER_DISABLED=True\n"
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
    assert result.steps[-1].context["windows_setup_reminder_disabled"] is True


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


def test_automation_requires_visual_monitoring() -> None:
    result = AutomationService(settings()).run(
        ["vm1"],
        linux_username="test",
        linux_password="test",
        monitor_iso=False,
        source="local",
    )

    assert result.status == "error"
    assert result.steps[-1].step == "automation.monitor_required"


def test_boot_guardian_fault_scope_is_rejected_before_vm_mutation() -> None:
    bios_result = AutomationService(settings()).run(
        ["vm1"],
        linux_username="test",
        linux_password="test",
        monitor_iso=True,
        source="local",
        boot_guardian_fault="boot-order",
    )
    assert bios_result.status == "error"
    assert bios_result.steps[-1].step == "automation.boot_guardian_fault_scope"

    linux_first_result = AutomationService(settings()).run(
        ["vm2"],
        linux_username="test",
        linux_password="test",
        monitor_iso=True,
        source="local",
        first_boot="linux",
        boot_guardian_fault="boot-order",
    )
    assert linux_first_result.status == "error"
    assert linux_first_result.steps[-1].step == "automation.boot_guardian_fault_order"


def test_boot_guardian_boot_order_fixture_requires_dry_run_and_repair_proof(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    actions: list[str] = []

    def fake_script(_ssh: object, **kwargs: object) -> CommandResult:
        config = kwargs["config"]
        assert isinstance(config, dict)
        action = str(config["action"])
        actions.append(action)
        outputs = {
            "plan-boot-order": (
                "RUN_ID=0123456789abcdef0123456789abcdef\n"
                "MODE=firmware-boot-order\nOWNED_BOOT=Boot0007\n"
                "WINDOWS_BOOT=Boot0001\nCURRENT_ORDER=Boot0007,Boot0001\n"
                "FAULT_ORDER=Boot0001,Boot0007\nWOULD_WRITE_BOOT_ORDER=true\nRESULT=OK\n"
            ),
            "inject-boot-order": (
                "INJECTED_UTC=2026-08-16T10:00:00.0000000Z\n"
                "VERIFIED_FAULT_ORDER=Boot0001,Boot0007\n"
                "WINDOWS_BOOT=Boot0001\nRESULT=OK\n"
            ),
            "verify-boot-order": (
                "REPAIR_LOG=C:\\LibertixInstallLogs\\Windows\\run\\BootGuardian\\repair.log\n"
                "REPAIRED_ORDER=Boot0007,Boot0001\nOWNED_BOOT=Boot0007\nRESULT=OK\n"
            ),
        }
        return CommandResult(stdout=outputs[action], stderr="", exit_code=0)

    monkeypatch.setattr(service, "_run_windows_script_resiliently", fake_script)
    result = ResultBuilder("automation")
    injected = service._inject_boot_guardian_boot_order_fault(  # noqa: SLF001
        object(),
        vm,
        result,  # type: ignore[arg-type]
    )
    service._verify_boot_guardian_boot_order_repair(  # noqa: SLF001
        object(),
        vm,
        result,
        injected,  # type: ignore[arg-type]
    )

    assert actions == ["plan-boot-order", "inject-boot-order", "verify-boot-order"]
    assert injected == "2026-08-16T10:00:00.0000000Z"
    assert result.steps[-1].status == "ok"
    assert result.steps[-1].context["REPAIRED_ORDER"] == "Boot0007,Boot0001"


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

    with pytest.raises(Exception, match="Libertix unattended automation refused"):
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
    monkeypatch.setattr(
        service.preflight,
        "configure_windows_guest_network",
        lambda _proxmox, _node, _profile: {
            "interface": "Ethernet",
            "ipv4": "192.0.2.240",
        },
    )
    vm = service.validation.select_vms(["vm1"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None

    result = ResultBuilder("automation")
    service.preflight.restore_clean_snapshot(result, profile)

    assert calls == [
        ("locate", 500, None),
        ("assert", 500, "baseline-a"),
        ("rollback", 500, "baseline-a"),
        ("verify", 500, "baseline-a"),
    ]
    assert result.steps[-2].step == "automation.reset_vm_done"
    assert "VM500 reset completed" in result.steps[-2].message
    assert result.steps[-1].step == "automation.guest_network_ready"


def test_snapshot_restore_network_uses_guest_agent_and_shared_configuration() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None
    commands: list[list[str]] = []

    class FakeProxmox:
        def get_guest_network_interfaces(
            self,
            _node: str,
            _vmid: int,
            *,
            step: str,
        ) -> list[dict[str, object]]:
            assert step in {
                "automation.guest_network_discovery",
                "automation.guest_network_verify",
            }
            return [
                {
                    "name": "Ethernet",
                    "hardware-address": "00:11:22:33:44:55",
                    "ip-addresses": [
                        {
                            "ip-address-type": "ipv4",
                            "ip-address": profile.vm_host,
                        }
                    ],
                },
                {
                    "name": "Loopback Pseudo-Interface 1",
                    "hardware-address": "00:00:00:00:00:00",
                    "ip-addresses": [],
                },
            ]

        def execute_guest_agent_command(
            self,
            _node: str,
            _vmid: int,
            command: list[str],
            *,
            step: str,
            timeout: float,
        ) -> dict[str, object]:
            assert step in {
                "automation.guest_interactive_session",
                "automation.guest_network_configure",
            }
            assert timeout > 0
            commands.append(command)
            return {"exited": True, "exitcode": 0}

    values = service.preflight.configure_windows_guest_network(
        FakeProxmox(),  # type: ignore[arg-type]
        "node-a",
        profile,
    )

    assert values == {
        "interface": "Ethernet",
        "ipv4": profile.vm_host,
        "prefix_length": 24,
        "gateway": "192.0.2.1",
        "dns_server_count": 2,
    }
    assert commands[0][0] == "powershell.exe"
    assert "Get-Process explorer" in commands[0][-1]
    assert commands[1][0:5] == ["netsh.exe", "interface", "ipv4", "set", "address"]
    assert f"address={profile.vm_host}" in commands[1]
    assert "mask=255.255.255.0" in commands[1]
    assert commands[2][4] == "dnsservers"
    assert commands[3][3:5] == ["add", "dnsservers"]


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
    monkeypatch.setattr(
        service.preflight,
        "configure_windows_guest_network",
        lambda _proxmox, _node, _profile: {
            "interface": "Ethernet",
            "ipv4": "192.0.2.242",
        },
    )
    vm = service.validation.select_vms(["vm3"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None

    result = ResultBuilder("automation")
    service.preflight.restore_clean_snapshot(result, profile)

    assert calls == [
        ("locate", 502, None),
        ("assert", 502, service.settings.reset_snapshot),
        ("rollback", 502, service.settings.reset_snapshot),
        ("verify", 502, service.settings.reset_snapshot),
    ]
    assert result.steps[-2].step == "automation.reset_vm_done"
    assert "VM502 reset completed" in result.steps[-2].message
    assert result.steps[-1].step == "automation.guest_network_ready"


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
    monkeypatch.setattr(
        service.preflight,
        "configure_windows_guest_network",
        lambda _proxmox, _node, _profile: {
            "interface": "Ethernet",
            "ipv4": "192.0.2.241",
        },
    )
    vm = service.validation.select_vms(["vm2"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None

    result = ResultBuilder("automation")
    service.preflight.restore_clean_snapshot(result, profile)

    assert calls == [
        ("locate", 501, None),
        ("assert", 501, service.settings.reset_snapshot),
        ("rollback", 501, service.settings.reset_snapshot),
        ("verify", 501, service.settings.reset_snapshot),
    ]
    assert result.steps[-2].step == "automation.reset_vm_done"
    assert "VM501 reset completed" in result.steps[-2].message
    assert result.steps[-1].step == "automation.guest_network_ready"


def test_automation_run_retains_completed_capture_workspace(
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
        linux_username="test",
        linux_password="test",
        monitor_iso=True,
        source="local",
    )

    assert result.status == "ok"
    workspaces = list(tmp_path.glob("automation-*"))
    assert len(workspaces) == 1
    assert (workspaces[0] / ".completed").is_file()
    assert (workspaces[0] / "captures" / "proof.png").read_bytes() == b"capture"


def test_automation_isolates_unexpected_errors_to_the_originating_vm(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    profile = service._automation_profile_for_vm(vm)  # noqa: SLF001
    assert profile is not None
    monkeypatch.setattr(
        service,
        "_prepare_windows_test_vm",
        lambda *_args: (_ for _ in ()).throw(TypeError("broken helper contract")),
    )

    result = service._run_vm_isolated(  # noqa: SLF001
        vm,
        PureWindowsPath("C:/Libertix/Libertix.exe"),
        AutomationOptions("test", "testtest", False),
        None,
    )

    assert result.status == "error"
    assert result.steps[-1].step == "automation.internal"
    assert result.steps[-1].context == {
        "vm": vm.name,
        "target": vm.host,
        "type": "TypeError",
        "exception_type": "WorkflowError",
    }


def test_automation_preserves_primary_failure_when_serial_capture_also_fails(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    serial_session = SimpleNamespace()

    monkeypatch.setattr(service, "_prepare_windows_test_vm", lambda *_args: None)
    monkeypatch.setattr(
        service.validation,
        "deploy_to_documents",
        lambda _vm, executable: executable,
    )
    monkeypatch.setattr(service, "_start_serial_capture", lambda *_args: serial_session)
    monkeypatch.setattr(
        service,
        "_launch_elevated",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(
            WorkflowError(
                "automation.primary",
                "Primary failure",
                details={"vm": vm.name, "target": vm.host},
            )
        ),
    )
    monkeypatch.setattr(
        service,
        "_stop_serial_capture",
        lambda *_args: (_ for _ in ()).throw(
            WorkflowError(
                "automation.serial_capture",
                "Serial capture failure",
                details={"vm": vm.name, "target": vm.host, "path": "serial.log"},
            )
        ),
    )

    result = service._run_vm_isolated(  # noqa: SLF001
        vm,
        PureWindowsPath("C:/Libertix/Libertix.exe"),
        AutomationOptions("test", "testtest", False),
        None,
    )

    assert result.status == "error"
    assert [step.step for step in result.steps[-2:]] == [
        "automation.serial_capture",
        "automation.primary",
    ]
    assert result.steps[-2].context == {
        "vm": vm.name,
        "target": vm.host,
        "path": "serial.log",
    }


def test_serial_capture_unavailable_is_reported_without_false_success(
    tmp_path: Path,
) -> None:
    service = AutomationService(settings(capture_dir=tmp_path))
    vm = service.validation.select_vms(["vm1"])[0]
    destination = tmp_path / "serial" / "vm1-serial-console.log"
    session = SimpleNamespace(
        stop_event=SimpleNamespace(set=lambda: None),
        thread=SimpleNamespace(join=lambda **_kwargs: None, is_alive=lambda: False),
        error=None,
        report=SimpleNamespace(
            path=destination,
            payload_bytes=52,
            connections=1,
            disconnects=0,
            unavailable_reason="serial0 is not configured on the VM",
        ),
        destination=destination,
    )
    result = ResultBuilder("automation")

    service._stop_serial_capture(vm, session, result)  # noqa: SLF001

    assert result.steps[-1].step == "automation.serial_capture_unavailable"
    assert result.steps[-1].status == "ok"
    assert result.steps[-1].context["capture_available"] is False
    assert not any(step.step == "automation.serial_capture_complete" for step in result.steps)


def test_validation_run_retains_completed_capture_workspace(
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
    workspaces = list(tmp_path.glob("validation-*"))
    assert len(workspaces) == 1
    assert (workspaces[0] / ".completed").is_file()
    assert (workspaces[0] / "captures" / "proof.png").read_bytes() == b"capture"


@pytest.mark.parametrize(
    ("shutdown", "advanced"),
    [
        ("Shutdown", "Advanced options"),
        ("Éteindre", "Options avancées"),
        ("Apagar", "Opciones avanzadas"),
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


def test_installation_monitor_reports_vision_payment_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    capture = Path("/tmp/live-install.png")
    analyses = {"value": 0}

    def unavailable_vision(*_args: object) -> InstallProgressVerdict:
        analyses["value"] += 1
        raise WorkflowError(
            "llm.install_progress",
            "Vision provider payment required",
            details={"http_status": 402},
        )

    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(service, "_capture_with_name", lambda *_args: capture)
    monkeypatch.setattr(
        service,
        "_installed_grub_theme_visible",
        lambda _capture: False,
    )
    monkeypatch.setattr(service.vision_llm, "analyze_install_progress", unavailable_vision)
    result = ResultBuilder("automation")

    with pytest.raises(WorkflowError) as raised:
        service._monitor_until_live_boot(  # noqa: SLF001
            vm,
            result,
            "uefi",
            reboot_requested=True,
        )

    assert raised.value.step == "automation.monitor_vision_required"
    assert raised.value.details["http_status"] == 402
    assert raised.value.details["provider_step"] == "llm.install_progress"
    assert raised.value.details["capture"] == str(capture)
    assert analyses["value"] == 1
    assert result.steps == []


def test_installation_monitor_tolerates_transient_vnc_outage_during_reboot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    captures = iter(
        (
            WorkflowError(
                "vnc.capture",
                "VNC capture failed",
                details={"address": vm.vnc, "attempts": 3, "error": "Network is unreachable"},
            ),
            Path("/tmp/final-grub.png"),
        )
    )

    def capture_after_reboot(*_args: object) -> Path:
        outcome = next(captures)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(service, "_capture_with_name", capture_after_reboot)
    monkeypatch.setattr(service, "_installed_grub_theme_visible", lambda _capture: True)
    result = ResultBuilder("automation")

    outcome = service._monitor_until_live_boot(  # noqa: SLF001
        vm,
        result,
        "uefi",
        reboot_requested=True,
    )

    assert outcome == "boot-menu"
    assert [step.step for step in result.steps] == [
        "automation.display_temporarily_unavailable",
        "automation.installed_boot_menu_seen",
    ]
    assert result.steps[0].context["error"] == "Network is unreachable"


def test_installation_monitor_does_not_hide_vnc_failure_before_reboot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    failure = WorkflowError(
        "vnc.capture",
        "VNC capture failed",
        details={"address": vm.vnc, "attempts": 3, "error": "Network is unreachable"},
    )
    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda *_args: (_ for _ in ()).throw(failure),
    )

    with pytest.raises(WorkflowError) as raised:
        service._monitor_until_live_boot(vm, ResultBuilder("automation"), "uefi")  # noqa: SLF001

    assert raised.value is failure


def test_installation_monitor_reboots_verified_live_failure_and_reports_archive(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    service = AutomationService(
        settings(
            automation_monitor_interval_seconds=0.2,
            automation_monitor_timeout_seconds=10,
            automation_stall_timeout_seconds=5,
        )
    )
    vm = service.validation.select_vms(["vm1"])[0]
    capture = tmp_path / "verified-live-failure.png"
    Image.new("RGB", (320, 200), (11, 16, 32)).save(capture)
    clock = {"now": 0.0}
    probes: list[Path] = []

    def visible_live_failure(*_args: object) -> InstallProgressVerdict:
        return InstallProgressVerdict(
            iso_download_finished=True,
            installation_finished=False,
            reboot_prompt_visible=False,
            still_in_progress=False,
            error_visible=True,
            blocking_problem_visible=True,
            summary="The live installer reports a terminal failure.",
            visible_text="Installation failed. Press R to reboot.",
        )

    monkeypatch.setattr(service, "_capture_with_name", lambda *_args: capture)
    monkeypatch.setattr(service, "_installed_grub_theme_visible", lambda _capture: False)
    monkeypatch.setattr(service.vision_llm, "analyze_install_progress", visible_live_failure)
    monkeypatch.setattr(
        service,
        "_request_live_failure_reboot_probe",
        lambda _vm, selected_capture, _result: probes.append(selected_capture),
    )
    monkeypatch.setattr(
        service,
        "_read_archived_live_failure",
        lambda _vm: {
            "message": "CRASH_TEST: target filesystem failed",
            "stage": "090-mount-target",
            "exit_code": "1",
            "rollback": "completed",
            "run_id": "test-run",
        },
    )
    monkeypatch.setattr(
        automation_monitoring_module.time,
        "monotonic",
        lambda: clock["now"],
    )
    monkeypatch.setattr(
        automation_monitoring_module.time,
        "sleep",
        lambda seconds: clock.__setitem__("now", clock["now"] + seconds),
    )

    with pytest.raises(WorkflowError) as raised:
        service._monitor_until_live_boot(  # noqa: SLF001
            vm,
            ResultBuilder("automation"),
            "bios",
            reboot_requested=True,
        )

    assert raised.value.step == "automation.live_installer_failure"
    assert raised.value.message == "CRASH_TEST: target filesystem failed"
    assert raised.value.details["rollback"] == "completed"
    assert probes == [capture]


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
    reboot_requests: list[str] = []
    monkeypatch.setattr(
        service,
        "_request_reboot_after_preparation",
        lambda selected_vm, _result: reboot_requests.append(selected_vm.name),
    )
    result = ResultBuilder("automation")

    service._monitor_until_live_boot(vm, result, firmware)  # type: ignore[arg-type]  # noqa: SLF001

    assert reboot_requests == ["vm3"]
    assert (
        len([step for step in result.steps if step.step == "automation.monitor_installation"]) == 3
    )
    assert result.steps[-1].step == "automation.installation_finished"


def test_installation_monitor_skips_three_identical_ai_analyses_then_rechecks(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    capture = tmp_path / "unchanged.png"
    Image.new("RGB", (320, 200), (15, 25, 35)).save(capture)
    capture_count = {"value": 0}
    verdicts = iter(
        (
            InstallProgressVerdict(
                iso_download_finished=False,
                installation_finished=False,
                reboot_prompt_visible=False,
                still_in_progress=True,
                error_visible=False,
                summary="Installation remains in progress.",
                visible_text="Extracting Linux system",
            ),
            InstallProgressVerdict(
                iso_download_finished=True,
                installation_finished=True,
                reboot_prompt_visible=False,
                still_in_progress=False,
                error_visible=False,
                summary="Installed boot menu.",
                visible_text=(
                    "Linux Mint 22.3 Cinnamon\nWindows Boot Manager\nShutdown\nAdvanced options"
                ),
            ),
        )
    )
    analyses = {"value": 0}

    def capture_screen(_vm: object, _label: str) -> Path:
        capture_count["value"] += 1
        return capture

    def analyze(*_args: object) -> InstallProgressVerdict:
        analyses["value"] += 1
        return next(verdicts)

    monkeypatch.setattr(automation_monitoring_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(service, "_capture_with_name", capture_screen)
    monkeypatch.setattr(service.vision_llm, "analyze_install_progress", analyze)
    result = ResultBuilder("automation")

    outcome = service._monitor_until_live_boot(vm, result, "bios")  # noqa: SLF001

    assert outcome == "boot-menu"
    assert capture_count["value"] == 5
    assert analyses["value"] == 2
    assert len([step for step in result.steps if step.step == "automation.monitor_unchanged"]) == 3


def test_installation_monitor_reports_a_visual_stall_with_its_capture(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    service = AutomationService(
        settings(
            automation_monitor_interval_seconds=0.2,
            automation_monitor_timeout_seconds=10,
            automation_stall_timeout_seconds=0.5,
        )
    )
    vm = service.validation.select_vms(["vm1"])[0]
    capture = tmp_path / "unchanged-live-installation.png"
    Image.new("RGB", (320, 200), (15, 25, 35)).save(capture)
    clock = {"now": 0.0}
    labels: list[str] = []

    def capture_screen(_vm: object, label: str) -> Path:
        labels.append(label)
        return capture

    monkeypatch.setattr(service, "_capture_with_name", capture_screen)
    monkeypatch.setattr(service, "_installed_grub_theme_visible", lambda _capture: False)
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda *_args: InstallProgressVerdict(
            iso_download_finished=True,
            installation_finished=False,
            reboot_prompt_visible=False,
            still_in_progress=True,
            error_visible=False,
            summary="Live installation remains active.",
            visible_text="Extracting Linux system",
        ),
    )
    monkeypatch.setattr(
        automation_monitoring_module.time,
        "monotonic",
        lambda: clock["now"],
    )
    monkeypatch.setattr(
        automation_monitoring_module.time,
        "sleep",
        lambda seconds: clock.__setitem__("now", clock["now"] + seconds),
    )

    with pytest.raises(WorkflowError) as raised:
        service._monitor_until_live_boot(  # noqa: SLF001
            vm,
            ResultBuilder("automation"),
            "bios",
            reboot_requested=True,
        )

    assert raised.value.step == "automation.progress_stalled"
    assert raised.value.details["phase"] == "bios-installation"
    assert raised.value.details["capture"] == str(capture)
    assert raised.value.details["stalled_seconds"] >= 0.5
    assert labels[-1] == "bios-monitor-004"


def test_reboot_request_uses_focused_default_controls_without_mouse_coordinates(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    keys: list[str] = []
    captures: list[str] = []
    delays: list[float] = []
    disconnected: list[bool] = []
    client = SimpleNamespace(
        keyPress=keys.append,
        disconnect=lambda: disconnected.append(True),
    )
    monkeypatch.setattr(service.vnc, "connect", lambda _address: client)
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda _client, _vm, label, _result: captures.append(label),
    )
    monkeypatch.setattr(automation_wizard_module.time, "sleep", delays.append)
    result = ResultBuilder("automation")

    service._request_reboot_after_preparation(vm, result)  # noqa: SLF001

    assert keys == ["enter", "enter"]
    assert delays == [
        automation_monitoring_module.REBOOT_DIALOG_DELAY_SECONDS,
        automation_monitoring_module.REBOOT_ACCEPT_DELAY_SECONDS,
    ]
    assert captures == ["reboot-ready", "reboot-confirm", "reboot-accepted"]
    assert disconnected == [True]
    assert result.steps[-1].step == "automation.reboot_requested"


def test_reboot_request_tolerates_vnc_loss_only_after_confirmation(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    keys: list[str] = []
    captures: list[str] = []
    client = SimpleNamespace(keyPress=keys.append, disconnect=lambda: None)

    def capture(_client: object, _vm: object, label: str, _result: object) -> None:
        captures.append(label)
        if label == "reboot-accepted":
            raise TimeoutError("VNC closed during reboot")

    monkeypatch.setattr(service.vnc, "connect", lambda _address: client)
    monkeypatch.setattr(service, "_capture_from_client", capture)
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)
    result = ResultBuilder("automation")

    service._request_reboot_after_preparation(vm, result)  # noqa: SLF001

    assert keys == ["enter", "enter"]
    assert captures == ["reboot-ready", "reboot-confirm", "reboot-accepted"]
    assert [step.step for step in result.steps[-2:]] == [
        "automation.reboot_transition",
        "automation.reboot_requested",
    ]


def test_client_capture_accepts_a_complete_image_written_before_vnc_timeout(
    tmp_path: Path,
) -> None:
    service = AutomationService(settings())
    service._capture_dir = tmp_path  # noqa: SLF001
    vm = service.validation.select_vms(["vm3"])[0]

    def write_then_timeout(path: str) -> None:
        Image.new("RGB", (64, 48), (10, 20, 30)).save(path)
        raise TimeoutError("VNC reply ended after framebuffer delivery")

    client = SimpleNamespace(captureScreen=write_then_timeout)
    result = ResultBuilder("automation")

    capture = service._capture_from_client(  # noqa: SLF001
        client, vm, "warning-ready", result
    )

    assert capture.is_file()
    assert result.steps[-1].step == "automation.capture"
    assert "after framebuffer delivery" in result.steps[-1].context["capture_transport_error"]


def test_automation_monitor_retries_a_restart_prompt_instead_of_calling_it_linux(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    capture = tmp_path / "restart-prompt.png"
    Image.new("RGB", (320, 200), (15, 25, 35)).save(capture)
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
    monitor_delays: list[float] = []
    monkeypatch.setattr(automation_monitoring_module.time, "sleep", monitor_delays.append)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, _label: capture,
    )
    monkeypatch.setattr(
        service.vision_llm,
        "analyze_install_progress",
        lambda _capture, _name, _os: next(verdicts),
    )
    reboot_requests: list[str] = []
    monkeypatch.setattr(
        service,
        "_request_reboot_after_preparation",
        lambda selected_vm, _result: reboot_requests.append(selected_vm.name),
    )
    result = ResultBuilder("automation")

    outcome = service._monitor_until_live_boot(vm, result, "bios")  # noqa: SLF001

    assert outcome == "boot-menu"
    assert reboot_requests == ["vm1", "vm1"]
    assert monitor_delays == [
        service.settings.automation_monitor_interval_seconds,
        automation_monitoring_module.REBOOT_RECHECK_INTERVAL_SECONDS,
        automation_monitoring_module.REBOOT_RECHECK_INTERVAL_SECONDS,
    ]
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
    monkeypatch.setattr(service, "_request_reboot_after_preparation", lambda _vm, _result: None)
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
    monkeypatch.setattr(service, "_request_reboot_after_preparation", lambda _vm, _result: None)
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
                summary="Installation is active but automatic rollback is starting.",
                visible_text=("Error during preparation; running automatic revert..."),
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
    preparation = uefi.split("private async Task ExecuteUefiInstallationAsync()", 1)[1]
    assert preparation.index("ArmUefiRecoveryAgent(recovery, powershell)") < preparation.index(
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
    options = AutomationOptions("test", "test-passphrase", True)

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
        "linux.first_boot_verification",
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
    assert len(sudo_calls) == 11
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


@pytest.mark.parametrize(
    ("entry", "expected_keys"),
    (
        ("linux", [("key", "home"), ("key_down", "enter"), ("key_up", "enter")]),
        (
            "windows",
            [
                ("key", "home"),
                ("key", "down"),
                ("key_down", "enter"),
                ("key_up", "enter"),
            ],
        ),
    ),
)
def test_post_install_grub_selection_uses_local_theme_detection_and_keyboard(
    monkeypatch: pytest.MonkeyPatch,
    entry: str,
    expected_keys: list[tuple[str, object]],
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    result = ResultBuilder("automation")

    class FakeVnc:
        def __init__(self) -> None:
            self.events: list[tuple[str, object]] = []

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
    monkeypatch.setattr(service, "_installed_grub_theme_visible", lambda _capture: True)
    monkeypatch.setattr(service.vnc, "connect", lambda _address: vnc)
    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)

    selected = service._select_grub_entry_if_visible(  # noqa: SLF001
        vm, result, entry, 3
    )

    assert selected is True
    assert vnc.events == [*expected_keys, ("disconnect", None)]
    assert result.steps[-1].context["phase"] == f"{entry}-boot"
    assert result.steps[-1].message == (f"Sent the {entry} selection from the installed GRUB menu")


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


def test_grub_ready_wait_types_as_soon_as_one_local_theme_frame_is_proven(
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
    theme_frames = iter((False, True))

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
    assert len(captures) == 2
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
            return CommandResult(stdout="LIBERTIX_REBOOT_ARMED", stderr="", exit_code=0)

    ssh = FakeSSH()
    options = AutomationOptions("test", "test-passphrase", True)

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
        def __init__(self) -> None:
            self.command = ""

        def run(self, command: str, **_kwargs) -> CommandResult:
            self.command = command
            return CommandResult(stdout="LIBERTIX_REBOOT_ARMED", stderr="", exit_code=0)

    ssh = FakeSSH()
    service._request_windows_boot(  # type: ignore[arg-type]  # noqa: SLF001
        ssh,
        vm,
        AutomationOptions("test", "test-passphrase", True),
        result,
        test_name="linux.final_windows_reboot",
    )

    assert result.steps[-1].context["test"] == "linux.final_windows_reboot"
    assert result.steps[-1].message == "linux.final_windows_reboot: OK"
    assert "systemd-run" in ssh.command
    assert "--on-active=5s" in ssh.command
    assert "LIBERTIX_REBOOT_ARMED" in ssh.command


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
        AutomationOptions("test", "test-passphrase", True),
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


def test_windows_to_linux_reboot_transport_failure_stops_the_flow() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]

    class BrokenSSH:
        def run(self, *_args, **_kwargs):
            raise WorkflowError(
                "ssh.command",
                "transport closed",
                details={"exception_type": "SSHException"},
            )

    with pytest.raises(WorkflowError) as captured:
        service._request_linux_boot_from_windows(  # noqa: SLF001
            BrokenSSH(),
            vm,
            ResultBuilder("automation"),
        )

    assert captured.value.step == "automation.linux_return_boot"
    assert "could not request" in captured.value.message


def test_windows_to_linux_reboot_rejection_stops_the_flow() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]

    class RejectingSSH:
        def run(self, *_args, **_kwargs):
            return CommandResult(stdout="", stderr="shutdown rejected", exit_code=5)

    with pytest.raises(WorkflowError) as captured:
        service._request_linux_boot_from_windows(  # noqa: SLF001
            RejectingSSH(),
            vm,
            ResultBuilder("automation"),
        )

    assert captured.value.step == "automation.linux_return_boot"
    assert captured.value.details["exit_code"] == 5


def test_post_install_flow_proves_windows_before_first_linux_boot(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    options = AutomationOptions(
        "test",
        "test-passphrase",
        True,
        distribution=load_distribution_profile("zorin"),
    )
    result = ResultBuilder("automation")
    events: list[str] = []
    artifacts = CrossOsArtifacts("windows.bin", "a" * 64, "linux.bin", "b" * 64)

    class FakeSSH:
        server_key_sha256 = "sha256:fake"

        def __exit__(self, *_args) -> None:
            events.append("ssh-close")

    def fake_wait_for_ssh(_vm, *, phase, grub_entry, **_kwargs):
        events.append(f"wait:{phase}:{grub_entry}")
        return FakeSSH()

    def fake_windows_script(_ssh, *, config, **_kwargs) -> CommandResult:
        events.append(f"windows-script:{config['check']}")
        return CommandResult(stdout="RESULT=OK", stderr="", exit_code=0)

    monkeypatch.setattr(service, "_wait_for_ssh", fake_wait_for_ssh)
    monkeypatch.setattr(service.validation, "run_windows_script", fake_windows_script)
    monkeypatch.setattr(
        service,
        "_request_linux_boot_from_windows",
        lambda *_args: events.append("request-linux"),
    )
    monkeypatch.setattr(
        service,
        "_request_windows_boot",
        lambda *_args, **_kwargs: events.append("request-windows"),
    )
    monkeypatch.setattr(
        service,
        "_prepare_windows_graphical_session",
        lambda *_args: events.append("prepare-windows-session"),
    )
    monkeypatch.setattr(
        service,
        "_wait_for_windows_filesystem_repair",
        lambda ssh, *_args: (events.append("windows-filesystem-ready"), ssh)[1],
    )
    monkeypatch.setattr(
        service,
        "_prepare_linux_graphical_session",
        lambda *_args: events.append("prepare-linux-session"),
    )
    monkeypatch.setattr(
        service,
        "_run_remote_check",
        lambda *_args, **_kwargs: events.append("linux-result-process"),
    )
    monkeypatch.setattr(
        service,
        "_wait_for_first_boot_verification",
        lambda *_args, **_kwargs: events.append("linux-verification-ready"),
    )
    monkeypatch.setattr(
        service,
        "_capture_and_dismiss_post_install_result",
        lambda _vm, _result, platform, _ssh: events.append(f"dialog:{platform}"),
    )
    monkeypatch.setattr(
        service,
        "_run_linux_checks",
        lambda *_args: events.append("linux-checks"),
    )
    monkeypatch.setattr(
        service,
        "_create_cross_os_artifacts",
        lambda *_args: (events.append("create-artifacts"), artifacts)[1],
    )
    monkeypatch.setattr(
        service,
        "_run_windows_checks",
        lambda *_args: events.append("windows-checks"),
    )
    monkeypatch.setattr(
        service,
        "_cleanup_windows_cross_os_artifact",
        lambda *_args: events.append("cleanup-windows-artifact"),
    )
    monkeypatch.setattr(
        service,
        "_cleanup_linux_cross_os_artifact",
        lambda *_args: events.append("cleanup-linux-artifact"),
    )

    service._run_post_install_validation(  # noqa: SLF001
        vm,
        options,
        result,
        "boot-menu",
    )

    assert events.index("wait:windows_before_linux:windows") < events.index(
        "windows-script:waiting_for_linux"
    )
    assert events.index("windows-script:waiting_for_linux") < events.index("request-linux")
    assert events.index("request-linux") < events.index("wait:linux_first:linux")
    assert events.index("prepare-linux-session") < events.index("dialog:linux")
    assert events.index("dialog:linux") < events.index("linux-checks")
    assert events.index("linux-checks") < events.index("request-windows")
    assert events.index("request-windows") < events.index("wait:windows:windows")
    assert events.index("wait:windows:windows") < events.index("prepare-windows-session")
    assert events.index("prepare-windows-session") < events.index("windows-checks")
    assert events.index("windows-checks") < events.index("dialog:windows")
    assert events.count("wait:windows_before_linux:windows") == 1
    assert events.count("wait:windows:windows") == 1
    assert events.count("wait:windows_final:windows") == 1
    assert events.count("prepare-windows-session") == 2


def test_post_install_flow_can_verify_linux_first_but_still_tests_both_systems(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    options = AutomationOptions(
        "test",
        "pass",
        True,
        distribution=load_distribution_profile("mint"),
        first_boot="linux",
    )
    result = ResultBuilder("automation")
    events: list[str] = []
    artifacts = CrossOsArtifacts("windows.bin", "a" * 64, "linux.bin", "b" * 64)

    class FakeSSH:
        server_key_sha256 = "sha256:fake"

        def __exit__(self, *_args: object) -> None:
            return None

    def wait_for_ssh(_vm: object, *, phase: str, grub_entry: str, **_kwargs: object):
        events.append(f"wait:{phase}:{grub_entry}")
        return FakeSSH()

    monkeypatch.setattr(service, "_wait_for_ssh", wait_for_ssh)
    monkeypatch.setattr(service, "_run_remote_check", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(service, "_wait_for_first_boot_verification", lambda *_args: None)
    monkeypatch.setattr(service, "_prepare_linux_graphical_session", lambda *_args: None)
    monkeypatch.setattr(
        service,
        "_prepare_windows_graphical_session",
        lambda *_args: events.append("prepare-windows-session"),
    )
    monkeypatch.setattr(
        service,
        "_wait_for_windows_filesystem_repair",
        lambda ssh, *_args: ssh,
    )
    monkeypatch.setattr(
        service,
        "_capture_and_dismiss_post_install_result",
        lambda _vm, _result, platform, _ssh: events.append(f"dialog:{platform}"),
    )
    monkeypatch.setattr(service, "_run_linux_checks", lambda *_args: None)
    monkeypatch.setattr(service, "_run_windows_checks", lambda *_args: None)
    monkeypatch.setattr(service, "_create_cross_os_artifacts", lambda *_args: artifacts)
    monkeypatch.setattr(service, "_cleanup_windows_cross_os_artifact", lambda *_args: None)
    monkeypatch.setattr(service, "_cleanup_linux_cross_os_artifact", lambda *_args: None)
    monkeypatch.setattr(service, "_request_windows_boot", lambda *_args, **_kwargs: None)
    monkeypatch.setattr(service, "_request_linux_boot_from_windows", lambda *_args: None)
    monkeypatch.setattr(
        service.validation,
        "run_windows_script",
        lambda *_args, **_kwargs: CommandResult(stdout="RESULT=OK", stderr="", exit_code=0),
    )

    service._run_post_install_validation(vm, options, result, "boot-menu")  # noqa: SLF001

    assert events[0] == "wait:linux_first:linux"
    assert "wait:windows_before_linux:windows" not in events
    assert events.count("wait:windows:windows") == 1
    assert events.count("wait:linux_return:linux") == 1
    assert events.count("wait:windows_final:windows") == 1
    assert events.count("prepare-windows-session") == 2
    assert events.count("dialog:linux") == 1
    assert events.count("dialog:windows") == 1


def test_windows_filesystem_repair_waits_for_reboot_then_resumes(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    options = AutomationOptions(
        "test",
        "test-passphrase",
        True,
        distribution=load_distribution_profile("mint"),
    )
    result = ResultBuilder("automation")
    closed: list[str] = []
    waits: list[str] = []

    class FakeSSH:
        def __init__(self, name: str) -> None:
            self.name = name

        def __exit__(self, *_args: object) -> None:
            closed.append(self.name)

    responses = iter(
        (
            CommandResult(
                stdout=(
                    "WINDOWS_FILESYSTEM_REPAIR_STATUS=waiting-reboot\n"
                    "WINDOWS_FILESYSTEM_REPAIR_ATTEMPT=1\n"
                    "WINDOWS_FILESYSTEM_REPAIR_SCHEDULED_BOOT=boot-1\n"
                    "WINDOWS_CURRENT_BOOT=boot-1\n"
                ),
                stderr="",
                exit_code=0,
            ),
            CommandResult(
                stdout=(
                    "WINDOWS_FILESYSTEM_REPAIR_STATUS=succeeded\n"
                    "WINDOWS_FILESYSTEM_REPAIR_ATTEMPT=1\n"
                    "WINDOWS_FILESYSTEM_REPAIR_SCHEDULED_BOOT=boot-1\n"
                    "WINDOWS_CURRENT_BOOT=boot-2\n"
                ),
                stderr="",
                exit_code=0,
            ),
        )
    )
    monkeypatch.setattr(
        service,
        "_run_windows_script_resiliently",
        lambda *_args, **_kwargs: next(responses),
    )
    monkeypatch.setattr(
        service,
        "_wait_for_ssh",
        lambda *_args, phase, **_kwargs: (waits.append(phase), FakeSSH("repaired"))[1],
    )
    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)

    repaired_ssh = service._wait_for_windows_filesystem_repair(  # noqa: SLF001
        FakeSSH("initial"),
        vm,
        options,
        result,
    )

    assert repaired_ssh.name == "repaired"
    assert closed == ["initial"]
    assert waits == ["windows_filesystem_repair"]
    assert [step.step for step in result.steps] == [
        "automation.windows_filesystem_repair_reboot",
        "automation.windows_filesystem_repair",
    ]


def test_first_boot_verification_failure_is_terminal_and_preserves_exact_reason() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    result = ResultBuilder("automation")

    class FakeSSH:
        def run(self, command: str, **kwargs: object) -> CommandResult:
            assert "first-boot-verification.json" in command
            assert kwargs["check"] is False
            return CommandResult(
                stdout=(
                    '{"status":"failed","error":"CRASH_TEST_CT06: forced failure",'
                    '"failedChecks":[]}'
                ),
                stderr="",
                exit_code=1,
            )

    with pytest.raises(WorkflowError) as caught:
        service._wait_for_first_boot_verification(  # type: ignore[arg-type]  # noqa: SLF001
            FakeSSH(), vm, result
        )

    assert caught.value.step == "automation.test.linux"
    assert caught.value.message == (
        "Linux first-boot verification failed: CRASH_TEST_CT06: forced failure"
    )
    assert caught.value.details["status"] == "failed"
    assert caught.value.details["state_path"].endswith("first-boot-verification.json")
    assert caught.value.details["log_path"].endswith("first-boot-resize.log")
    assert result.steps == []


def test_first_boot_verification_success_records_one_clean_result() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    result = ResultBuilder("automation")

    class FakeSSH:
        def run(self, _command: str, **_kwargs: object) -> CommandResult:
            return CommandResult(
                stdout='{"status":"succeeded","error":null,"failedChecks":[]}',
                stderr="",
                exit_code=0,
            )

    service._wait_for_first_boot_verification(  # type: ignore[arg-type]  # noqa: SLF001
        FakeSSH(), vm, result
    )

    assert len(result.steps) == 1
    assert result.steps[0].status == "ok"
    assert result.steps[0].message == "linux.first_boot_verification_ready: OK"


def test_linux_graphical_session_uses_loginctl_before_submitting_credentials(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    responses = iter(
        (
            CommandResult(stdout="LIBERTIX_GREETER_READY", stderr="", exit_code=0),
            CommandResult(stdout="LIBERTIX_DESKTOP_READY", stderr="", exit_code=0),
        )
    )
    keys: list[str] = []
    held_keys: list[tuple[str, str]] = []
    captures: list[str] = []
    typed: list[tuple[str, str]] = []
    disconnects: list[bool] = []

    def connect(_address: str) -> SimpleNamespace:
        return SimpleNamespace(
            keyPress=keys.append,
            keyDown=lambda key: held_keys.append(("down", key)),
            keyUp=lambda key: held_keys.append(("up", key)),
            disconnect=lambda: disconnects.append(True),
        )

    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"{label}.png"),
    )
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda _client, _vm, label, _result: captures.append(label) or Path(f"{label}.png"),
    )
    monkeypatch.setattr(service.vnc, "connect", connect)
    monkeypatch.setattr(
        service,
        "_type_text",
        lambda _client, text, layout: typed.append((text, layout)),
    )
    linux_ssh = SimpleNamespace(run=lambda *_args, **_kwargs: next(responses))
    result = ResultBuilder("automation")

    service._prepare_linux_graphical_session(  # noqa: SLF001
        linux_ssh,
        vm,
        result,
        "test",
        "test-passphrase",
    )

    assert typed == [("test-passphrase", vm.vnc_keyboard_layout)]
    select_all_key = "q" if vm.vnc_keyboard_layout == "fr" else "a"
    assert keys == [select_all_key, "bsp", "enter"]
    assert held_keys == [("down", "ctrl"), ("up", "ctrl")]
    assert captures == [
        "post-install-linux-login-01-ready",
        "post-install-linux-login-01-password-entered",
    ]
    assert len(disconnects) == 1
    assert [step.step for step in result.steps] == [
        "automation.linux_graphical_login",
        "automation.linux_graphical_session",
    ]


def test_bound_vnc_text_input_types_the_requested_password(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    keys: list[str] = []
    client = SimpleNamespace(keyPress=keys.append)
    monkeypatch.setattr(automation_wizard_module.time, "sleep", lambda _seconds: None)

    service._type_text(client, "azerty-4", "fr")  # noqa: SLF001

    expected = automation_wizard_module.azerty_to_qwerty("azerty-4")
    assert keys == ["minus" if char == "-" else char for char in expected]


def test_linux_graphical_session_retries_until_loginctl_proves_an_active_desktop(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    responses = iter(
        (
            CommandResult(stdout="", stderr="", exit_code=1),
            CommandResult(stdout="LIBERTIX_GREETER_READY", stderr="", exit_code=0),
            CommandResult(stdout="LIBERTIX_DESKTOP_READY", stderr="", exit_code=0),
        )
    )
    typed: list[tuple[str, str]] = []
    keys: list[str] = []
    held_keys: list[tuple[str, str]] = []

    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"{label}.png"),
    )
    monkeypatch.setattr(
        service.vnc,
        "connect",
        lambda _address: SimpleNamespace(
            keyPress=keys.append,
            keyDown=lambda key: held_keys.append(("down", key)),
            keyUp=lambda key: held_keys.append(("up", key)),
            disconnect=lambda: None,
        ),
    )
    monkeypatch.setattr(
        service,
        "_capture_from_client",
        lambda _client, _vm, label, _result: Path(f"{label}.png"),
    )
    monkeypatch.setattr(
        service,
        "_type_text",
        lambda _client, text, layout: typed.append((text, layout)),
    )
    linux_ssh = SimpleNamespace(run=lambda *_args, **_kwargs: next(responses))
    result = ResultBuilder("automation")

    service._prepare_linux_graphical_session(  # noqa: SLF001
        linux_ssh,
        vm,
        result,
        "test",
        "test-passphrase",
    )

    assert typed == [("test-passphrase", vm.vnc_keyboard_layout)]
    select_all_key = "q" if vm.vnc_keyboard_layout == "fr" else "a"
    assert keys == [select_all_key, "bsp", "enter"]
    assert held_keys == [("down", "ctrl"), ("up", "ctrl")]
    assert [step.step for step in result.steps] == [
        "automation.linux_graphical_session_wait",
        "automation.linux_graphical_login",
        "automation.linux_graphical_session",
    ]
    assert [step.context.get("attempt") for step in result.steps[:2]] == [1, 2]


def test_linux_graphical_session_reconnects_after_a_blank_vnc_capture(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    responses = iter(
        (
            CommandResult(stdout="LIBERTIX_GREETER_READY", stderr="", exit_code=0),
            CommandResult(stdout="LIBERTIX_GREETER_READY", stderr="", exit_code=0),
            CommandResult(stdout="LIBERTIX_DESKTOP_READY", stderr="", exit_code=0),
        )
    )
    connections: list[SimpleNamespace] = []
    capture_attempts = 0
    typed: list[str] = []

    def connect(_address: str) -> SimpleNamespace:
        connection = SimpleNamespace(
            keyPress=lambda _key: None,
            keyDown=lambda _key: None,
            keyUp=lambda _key: None,
            disconnect=lambda: None,
        )
        connections.append(connection)
        return connection

    def capture(
        _client: object,
        _vm: object,
        label: str,
        _result: ResultBuilder,
    ) -> Path:
        nonlocal capture_attempts
        capture_attempts += 1
        if capture_attempts == 1:
            raise WorkflowError(
                "automation.capture",
                "VNC capture is missing or empty",
                details={"label": label},
            )
        return Path(f"{label}.png")

    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"{label}.png"),
    )
    monkeypatch.setattr(service.vnc, "connect", connect)
    monkeypatch.setattr(service, "_capture_from_client", capture)
    monkeypatch.setattr(
        service,
        "_type_text",
        lambda _client, text, _layout: typed.append(text),
    )
    linux_ssh = SimpleNamespace(run=lambda *_args, **_kwargs: next(responses))
    result = ResultBuilder("automation")

    service._prepare_linux_graphical_session(  # noqa: SLF001
        linux_ssh,
        vm,
        result,
        "test",
        "test-passphrase",
    )

    assert len(connections) == 2
    assert typed == ["test-passphrase"]
    assert [step.step for step in result.steps] == [
        "automation.linux_graphical_capture_retry",
        "automation.linux_graphical_login",
        "automation.linux_graphical_session",
    ]
    assert result.steps[0].context["attempt"] == 1


def test_windows_post_install_checks_unlock_the_interactive_session(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    inspections = iter(
        (
            CommandResult(
                stdout=(
                    "EXPLORER_SESSION_READY=False\nSETUP_EXPERIENCE_PRESENT=False\n"
                    "LOGIN_SCREEN_PRESENT=False\nSESSION_ID=-1\n"
                ),
                stderr="",
                exit_code=0,
            ),
            CommandResult(
                stdout=(
                    "EXPLORER_SESSION_READY=False\nSETUP_EXPERIENCE_PRESENT=False\n"
                    "LOGIN_SCREEN_PRESENT=False\nSESSION_ID=-1\n"
                ),
                stderr="",
                exit_code=0,
            ),
            CommandResult(
                stdout=(
                    "EXPLORER_SESSION_READY=False\nSETUP_EXPERIENCE_PRESENT=False\n"
                    "LOGIN_SCREEN_PRESENT=True\nSESSION_ID=2\n"
                ),
                stderr="",
                exit_code=0,
            ),
            CommandResult(
                stdout=(
                    "EXPLORER_SESSION_READY=True\nSETUP_EXPERIENCE_PRESENT=False\n"
                    "LOGIN_SCREEN_PRESENT=False\nSESSION_ID=2\n"
                ),
                stderr="",
                exit_code=0,
            ),
        )
    )
    keys: list[str] = []
    typed: list[tuple[str, str]] = []
    disconnects: list[bool] = []

    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"{label}.png"),
    )
    monkeypatch.setattr(
        service.vnc,
        "connect",
        lambda _address: SimpleNamespace(
            keyPress=keys.append,
            disconnect=lambda: disconnects.append(True),
        ),
    )
    monkeypatch.setattr(
        service,
        "_type_text",
        lambda _client, text, layout: typed.append((text, layout)),
    )
    monkeypatch.setattr(
        service.validation,
        "run_windows_script",
        lambda *_args, **_kwargs: next(inspections),
    )
    result = ResultBuilder("automation")

    service._prepare_windows_graphical_session(object(), vm, result)  # noqa: SLF001

    assert keys == ["enter", "enter"]
    assert typed == [
        (service.settings.windows_ssh_password.get_secret_value(), vm.vnc_keyboard_layout)
    ]
    assert disconnects == [True]
    assert [step.step for step in result.steps] == [
        "automation.windows_graphical_session_wait",
        "automation.windows_graphical_session_wait",
        "automation.windows_graphical_login",
        "automation.windows_graphical_session",
    ]


def test_windows_post_install_dismisses_identified_setup_experience(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    scripts: list[str] = []
    inspection_count = {"value": 0}

    monkeypatch.setattr(automation_postinstall_module.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"{label}.png"),
    )

    def fake_run_windows_script(
        _ssh: object,
        *,
        script_name: str,
        **_kwargs: object,
    ) -> CommandResult:
        scripts.append(script_name)
        if script_name == "inspect_windows_graphical_session.ps1":
            inspection_count["value"] += 1
            return CommandResult(
                stdout=(
                    "EXPLORER_SESSION_READY="
                    + ("False" if inspection_count["value"] == 1 else "True")
                    + "\nSETUP_EXPERIENCE_PRESENT="
                    + ("True" if inspection_count["value"] == 1 else "False")
                    + "\nSESSION_ID=3\n"
                ),
                stderr="",
                exit_code=0,
            )
        return CommandResult(
            stdout=("WINDOWS_SETUP_EXPERIENCE_DISMISSED=True\nTERMINATED_PROCESS_COUNT=1\n"),
            stderr="",
            exit_code=0,
        )

    monkeypatch.setattr(service.validation, "run_windows_script", fake_run_windows_script)
    result = ResultBuilder("automation")

    service._prepare_windows_graphical_session(object(), vm, result)  # noqa: SLF001

    assert scripts == [
        "inspect_windows_graphical_session.ps1",
        "dismiss_windows_setup_experience.ps1",
        "inspect_windows_graphical_session.ps1",
    ]
    assert [step.step for step in result.steps] == [
        "automation.windows_setup_experience",
        "automation.windows_graphical_session",
    ]
    assert result.steps[0].context["terminated_process_count"] == 1


def test_linux_result_dialog_dismissal_requires_process_exit_and_acknowledgement(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm1"])[0]
    keys: list[str] = []
    commands: list[str] = []
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"{label}.png"),
    )
    monkeypatch.setattr(
        service.vnc,
        "connect",
        lambda _address: SimpleNamespace(
            keyPress=keys.append,
            disconnect=lambda: None,
        ),
    )

    class FakeSsh:
        def run(self, command: str, **kwargs: object) -> CommandResult:
            commands.append(command)
            assert kwargs["step"] in {
                "automation.linux_post_install_result_process",
                "automation.linux_post_install_result_dismissed",
            }
            return CommandResult(
                stdout=(
                    "4321\n"
                    if kwargs["step"] == "automation.linux_post_install_result_process"
                    else ""
                ),
                stderr="",
                exit_code=0,
            )

    linux_scripts: list[dict[str, object]] = []

    def fake_run_linux_script(_ssh: object, **kwargs: object) -> CommandResult:
        linux_scripts.append(dict(kwargs))
        return CommandResult(
            stdout=("PROCESS_ID=4321\nWINDOW_ID=0x1234\nACTIVE_WINDOW_PROVEN=True\nRESULT=OK\n"),
            stderr="",
            exit_code=0,
        )

    monkeypatch.setattr(service.validation, "run_linux_script", fake_run_linux_script)

    result = ResultBuilder("automation")
    service._capture_and_dismiss_post_install_result(  # noqa: SLF001
        vm,
        result,
        "linux",
        FakeSsh(),
    )

    assert keys == ["enter"]
    assert "pgrep -fo" in commands[0]
    assert "first-boot-result.py" in commands[0]
    assert "first-boot-result.py" in commands[1]
    assert "first-boot-result-ack.json" in commands[1]
    assert linux_scripts == [
        {
            "script_name": "focus_linux_post_install_result.py",
            "arguments": ("--pid", "4321", "--timeout", "15"),
            "step": "automation.linux_post_install_result_focused",
            "timeout": 30,
        }
    ]
    assert result.steps[-1].context["proof_source"] == ("guest-state-process-and-dismissal")


def test_windows_result_dialog_dismissal_requires_process_and_task_cleanup(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm2"])[0]
    observed: list[dict[str, object]] = []
    monkeypatch.setattr(
        service,
        "_capture_with_name",
        lambda _vm, label: Path(f"{label}.png"),
    )
    monkeypatch.setattr(
        service.vnc,
        "connect",
        lambda _address: SimpleNamespace(keyPress=lambda _key: None, disconnect=lambda: None),
    )

    def fake_run_windows_script(_ssh: object, **kwargs: object) -> CommandResult:
        observed.append(dict(kwargs))
        if kwargs["script_name"] == "focus_post_install_result.ps1":
            return CommandResult(stdout="RESULT=OK\n", stderr="", exit_code=0)
        if kwargs["config"]["check"] == "post_install_result_ui":
            return CommandResult(
                stdout="POST_INSTALL_RESULT_UI_PROCESS_ID=4567\nRESULT=OK\n",
                stderr="",
                exit_code=0,
            )
        return CommandResult(
            stdout="POST_INSTALL_RESULT_UI_DISMISSED=True\n",
            stderr="",
            exit_code=0,
        )

    monkeypatch.setattr(service.validation, "run_windows_script", fake_run_windows_script)
    result = ResultBuilder("automation")
    service._capture_and_dismiss_post_install_result(  # noqa: SLF001
        vm,
        result,
        "windows",
        object(),
    )

    assert [call["script_name"] for call in observed] == [
        "post_install_windows_check.ps1",
        "focus_post_install_result.ps1",
        "post_install_windows_check.ps1",
    ]
    assert observed[0]["config"] == {
        "check": "post_install_result_ui",
        "expected_firmware": "uefi",
    }
    assert observed[0]["step"] == "automation.windows_post_install_result_visible"
    assert observed[1]["config"] == {"process_id": 4567}
    assert observed[1]["step"] == "automation.windows_post_install_result_focused"
    assert observed[2]["config"] == {
        "check": "post_install_result_ui_dismissed",
        "expected_firmware": "uefi",
    }
    assert observed[2]["step"] == "automation.windows_post_install_result_dismissed"


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
    assert plan.base_config["partition_alignment_bytes"] == 1024 * 1024


def test_cross_os_artifacts_are_removed_after_their_checks() -> None:
    service = AutomationService(settings())
    vm = service.validation.select_vms(["vm3"])[0]
    result = ResultBuilder("automation")
    commands: list[str] = []

    class FakeSSH:
        def run(self, command: str, **_kwargs) -> CommandResult:
            commands.append(command)
            return CommandResult(stdout="", stderr="", exit_code=0)

    options = AutomationOptions("test", "test-passphrase", True)
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
        AutomationOptions("test", "test-passphrase", True),
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
        "waiting_for_linux",
        "filesystem_repair_state",
        "post_install_result_ui",
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
        "explorer_integration",
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


def test_windows_final_state_accepts_only_complete_preferred_uefi_path_evidence() -> None:
    script = read_repo("auto_tests/app/scripts/post_install_windows_check.ps1")
    verifier = script.split("function Assert-LibertixPostInstallResult", maxsplit=1)[1].split(
        "function Get-PlannedLinuxOffset", maxsplit=1
    )[0]

    assert '"uefi-preferred-windows-path"' in verifier
    assert '"/boot/efi/EFI/Libertix/preferred-boot-path.json"' in verifier
    assert '"/boot/efi/EFI/Libertix/secure-boot-chain.json"' in verifier
    for required_hash in (
        "bootmgfw.efi",
        "grubx64.efi",
        "mmx64.efi",
        "grub.cfg",
        "bootmgfw.libertix-windows.efi",
    ):
        assert f'"{required_hash}"' in verifier
    assert "The verified UEFI BootCurrent or preferred Windows-path proof is missing." in verifier
