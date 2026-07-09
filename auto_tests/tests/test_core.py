from pathlib import Path, PurePosixPath, PureWindowsPath
import threading
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

import app.services.automation as automation_module
import app.services.validation as validation_module
from app.clients.vnc import VNCClient
from app.config import Settings
from app.models import ValidationRequest
from app.services.automation import AutomationOptions, AutomationService
from app.services.common import ResultBuilder
from app.services.reset import RESET_SNAPSHOT, RESET_VM_IDS, ResetService
from app.services.validation import ValidationService


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
            },
            {
                "name": "vm2",
                "host": "192.168.1.241",
                "os": "Windows 10 UEFI",
                "vnc": "192.168.1.166:11",
                "screen_width": 1280,
                "screen_height": 800,
            },
            {
                "name": "vm3",
                "host": "192.168.1.242",
                "os": "Windows 11 UEFI",
                "vnc": "192.168.1.166:12",
                "screen_width": 1280,
                "screen_height": 800,
            },
        ),
        "_env_file": None,
    }
    values.update(overrides)
    return Settings(**values)


def test_share_path_translation() -> None:
    service = ValidationService(settings())
    actual = service._to_windows_share_path(  # noqa: SLF001
        PurePosixPath("/root/smb/Libertix-release/folder/Libertix.exe")
    )
    assert actual == PureWindowsPath("Z:/Libertix-release/folder/Libertix.exe")


def test_smb_root_is_strictly_guarded() -> None:
    with pytest.raises(ValidationError):
        settings(smb_root="/")


def test_reset_scope_is_exact() -> None:
    assert RESET_VM_IDS == (500, 501, 502)
    assert RESET_SNAPSHOT == "clean2"


def test_reset_selector_uses_configured_vm_names() -> None:
    service = ResetService(settings())

    assert service._selected_vmids(["vm3", "win11-uefi", "502"]) == (502,)  # noqa: SLF001


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

    for path in (allowed, allowed_aria2, blocked_env, blocked_named_env, blocked_filepool, blocked_other_exe):
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


def test_validation_source_defaults_to_remote() -> None:
    assert ValidationRequest().source == "remote"


def test_validation_source_accepts_local() -> None:
    assert ValidationRequest(source="local").source == "local"


def test_validation_vm_selector_accepts_aliases() -> None:
    service = ValidationService(settings())

    selected = service._select_vms(["10 uefi"])  # noqa: SLF001

    assert [vm.name for vm in selected] == ["vm2"]


def test_validation_vm_selector_rejects_unknown() -> None:
    service = ValidationService(settings())

    with pytest.raises(Exception, match="Sélecteur VM inconnu"):
        service._select_vms(["not-a-vm"])  # noqa: SLF001


def test_launch_interactive_accepts_zero_window_handle(monkeypatch: pytest.MonkeyPatch) -> None:
    class FakeSshContext:
        def __enter__(self) -> object:
            return object()

        def __exit__(self, *_args: object) -> None:
            return None

    class FakeVnc:
        def launch_desktop_shortcut(self, *_args: object, **_kwargs: object) -> None:
            return None

    service = ValidationService(settings())
    service.vnc = FakeVnc()  # type: ignore[assignment]

    def fake_run_windows_script(*_args: object, step: str, **_kwargs: object) -> object:
        if step == "vm.prepare_launch":
            return SimpleNamespace(stdout="SESSION_ID=2\n")
        return SimpleNamespace(stdout="PID=1234\nSESSION_ID=2\nWINDOW_HANDLE=0\n")

    monkeypatch.setattr(service, "_ssh", lambda *_args, **_kwargs: FakeSshContext())
    monkeypatch.setattr(service, "_run_windows_script", fake_run_windows_script)
    monkeypatch.setattr(validation_module.time, "sleep", lambda _seconds: None)

    vm = service._select_vms(["vm1"])[0]  # noqa: SLF001
    result = ResultBuilder("validation")
    launch = service._launch_interactive(  # noqa: SLF001
        vm,
        PureWindowsPath("Z:/Libertix-release/Libertix.exe"),
        result,
    )

    assert launch["pid"] == 1234
    assert launch["session_id"] == 2
    assert launch["window_handle"] == 0


def test_automation_scope_accepts_only_vm500() -> None:
    service = AutomationService(settings())
    selected = service.validation._select_vms(["vm1"])  # noqa: SLF001

    service._assert_autoclick_scope(selected, ["vm1"])  # noqa: SLF001


def test_automation_scope_accepts_vm502_uefi() -> None:
    service = AutomationService(settings())
    selected = service.validation._select_vms(["vm3"])  # noqa: SLF001

    service._assert_autoclick_scope(selected, ["vm3"])  # noqa: SLF001


def test_automation_scope_accepts_vm501_uefi() -> None:
    service = AutomationService(settings())
    selected = service.validation._select_vms(["vm2"])  # noqa: SLF001

    service._assert_autoclick_scope(selected, ["vm2"])  # noqa: SLF001


def test_automation_scope_accepts_all_validated_vms() -> None:
    service = AutomationService(settings())
    selected = service.validation._select_vms(["vm1", "vm2", "vm3"])  # noqa: SLF001

    profiles = service._automation_profiles(selected, ["vm1", "vm2", "vm3"])  # noqa: SLF001

    assert {name: profile.vmid for name, profile in profiles.items()} == {
        "vm1": 500,
        "vm2": 501,
        "vm3": 502,
    }


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
                },
                {
                    "name": "vm4",
                    "host": "192.168.1.244",
                    "os": "Windows experimental",
                    "vnc": "192.168.1.166:14",
                    "screen_width": 1024,
                    "screen_height": 768,
                },
            )
        )
    )
    selected = service.validation._select_vms(["vm1", "vm4"])  # noqa: SLF001

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

    result = ResultBuilder("automation")
    service._restore_clean_snapshot(result, service.BIOS_PROFILE)  # noqa: SLF001

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

    result = ResultBuilder("automation")
    service._restore_clean_snapshot(result, service.UEFI_PROFILE)  # noqa: SLF001

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

    result = ResultBuilder("automation")
    service._restore_clean_snapshot(result, service.WIN10_UEFI_PROFILE)  # noqa: SLF001

    assert calls == [
        ("locate", 501, None),
        ("assert", 501, RESET_SNAPSHOT),
        ("rollback", 501, RESET_SNAPSHOT),
    ]
    assert result.steps[-1].step == "automation.reset_vm_done"
    assert "Reset VM501 terminé" in result.steps[-1].message


def test_automation_apply_false_only_launches_ui(
    monkeypatch: pytest.MonkeyPatch, tmp_path
) -> None:
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
    vm = service.validation._select_vms(["vm1"])[0]  # noqa: SLF001
    result = ResultBuilder("automation")

    service._click_wizard(  # noqa: SLF001
        vm,
        AutomationOptions(
            apply=False, linux_username="test", linux_password="linux", monitor_iso=True
        ),
        service.BIOS_PROFILE,
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


def test_automation_uefi_monitor_stops_on_live_boot_not_windows_progress() -> None:
    service = AutomationService(settings())

    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Downloading Mint ISO... 60%",
            "Windows desktop with Libertix wizard and active progress bar",
        )
        is False
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Windows Boot Manager with Windows 10 highlighted",
            "Gestionnaire de démarrage Windows; no Libertix installer visible",
        )
        is False
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Libertix installer is creating the UEFI installer partition",
            "Appliquer les modifications Creating UEFI installer partition "
            "C:\\LibertixTools\\downloads\\mint.iso",
        )
        is False
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Fallback LLM: active installer progress detected from visible evidence.",
            "Appliquer les modifications Copying UEFI installer... "
            "Mounting ISO... Copying ISO contents to X:... Libertix UEFI installer copied.",
        )
        is False
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Linux boot process showing kernel and initramfs loading",
            "vmlinuz initrd squashfs",
        )
        is True
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Libertix Installer",
            "Installation automatique Code: 120-unsquashfs F12: mode terminal",
        )
        is True
    )


def test_bios_final_grub_waits_for_manual_selection() -> None:
    grub_defaults = Path("../iso/target/configure-target.sh").read_text(encoding="utf-8")

    assert "GRUB_TIMEOUT=-1" in grub_defaults
    assert "GRUB_RECORDFAIL_TIMEOUT=-1" in grub_defaults
    assert "GRUB_TIMEOUT=10" not in grub_defaults


def test_uefi_recovery_guard_uses_normalized_geometry_and_long_retry() -> None:
    installer = Path("../iso-uefi/live/install-mint.sh").read_text(encoding="utf-8")

    assert "normalize_recovery_geometry()" in installer
    assert 'for attempt in $(seq 1 30); do' in installer
    assert 'current_key="$(normalize_recovery_geometry "$current")"' in installer
    assert "Recovery geometry raw format changed but normalized geometry is identical" in installer


def test_uefi_bitlocker_wait_uses_monotonic_timer() -> None:
    script = Path("../Scripts/libertix-uefi-install.ps1").read_text(encoding="utf-8")

    assert "[System.Diagnostics.Stopwatch]::StartNew()" in script
    assert "$decryptionTimer.Elapsed -lt $maxDecryptionWait" in script
    assert "(Get-Date).AddHours(6)" not in script
