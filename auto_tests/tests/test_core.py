import subprocess
import threading
from pathlib import Path, PurePosixPath, PureWindowsPath
from types import SimpleNamespace

import pytest
from pydantic import ValidationError

import app.services.automation as automation_module
import app.services.validation as validation_module
from app.clients.vnc import VNCClient
from app.config import Settings
from app.errors import WorkflowError
from app.models import ValidationRequest
from app.services.automation import AutomationOptions, AutomationService, Point
from app.services.common import ResultBuilder
from app.services.reset import RESET_SNAPSHOT, ResetService
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


def test_share_path_translation() -> None:
    service = ValidationService(settings())
    actual = service.to_windows_share_path(
        PurePosixPath("/root/smb/Libertix-release/folder/Libertix.exe")
    )
    assert actual == PureWindowsPath("Z:/Libertix-release/folder/Libertix.exe")


def test_smb_root_is_strictly_guarded() -> None:
    with pytest.raises(ValidationError):
        settings(smb_root="/")


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

    assert final.status == "problème"
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


def test_validation_source_defaults_to_remote() -> None:
    assert ValidationRequest().source == "remote"


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

    monkeypatch.setattr(service, "ssh", lambda *_args, **_kwargs: FakeSshContext())
    monkeypatch.setattr(service, "run_windows_script", fake_run_windows_script)
    monkeypatch.setattr(validation_module.time, "sleep", lambda _seconds: None)

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


def test_automation_scope_accepts_only_vm500() -> None:
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

    assert result.status == "problème"
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


def test_automation_uefi_monitor_stops_on_live_boot_not_windows_progress() -> None:
    service = AutomationService(settings())

    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Downloading Mint ISO... 60% Windows desktop with Libertix wizard",
        )
        is False
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Gestionnaire de démarrage Windows; no Libertix installer visible",
        )
        is False
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Appliquer les modifications Creating UEFI installer partition "
            "C:\\LibertixTools\\downloads\\mint.iso",
        )
        is False
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Appliquer les modifications Copying UEFI installer... "
            "Mounting ISO... Copying ISO contents to X:... Libertix UEFI installer copied.",
        )
        is False
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "vmlinuz initrd squashfs",
        )
        is False
    )
    assert (
        service._uefi_reboot_or_live_started(  # noqa: SLF001
            "Installation automatique Code: 120-unsquashfs F12: mode terminal",
        )
        is True
    )


def test_bios_final_grub_waits_for_manual_selection() -> None:
    grub_defaults = Path("../iso/target/configure-target.sh").read_text(encoding="utf-8")

    assert "GRUB_TIMEOUT=-1" in grub_defaults
    assert "GRUB_RECORDFAIL_TIMEOUT=-1" in grub_defaults
    assert "GRUB_TIMEOUT=10" not in grub_defaults


def test_bios_installer_keeps_windows_boot_partition_active() -> None:
    installer = Path("../iso/live/install-mint.sh").read_text(encoding="utf-8")
    preflight = Path("../Scripts/libertix-storage-preflight.ps1").read_text(encoding="utf-8")

    assert "WINDOWS_BOOT_PARTITION_OFFSET_BYTES" in installer
    assert 'set "$NEW_PART_NUM" boot off' in installer
    assert 'set "$WINDOWS_BOOT_PART_NUM" boot on' in installer
    assert 'set "$NEW_PART_NUM" boot on' not in installer
    assert "final verify: Windows boot partition is not active" in installer
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
    installer = Path("../iso-uefi/live/install-mint.sh").read_text(encoding="utf-8")

    assert 'partition_at_offset "$DISK" "$RECOVERY_PARTITION_OFFSET_BYTES"' in installer
    assert 'recovery_size=$(blockdev --getsize64 "$recovery_part"' in installer
    assert 'recovery_size" = "$RECOVERY_PARTITION_SIZE_BYTES' in installer
    assert "Windows recovery partition changed" not in installer


def test_uefi_bitlocker_wait_uses_monotonic_timer() -> None:
    script = Path("../Scripts/libertix-uefi-install.ps1").read_text(encoding="utf-8")

    assert "[System.Diagnostics.Stopwatch]::StartNew()" in script
    assert "$decryptionTimer.Elapsed -lt $maxDecryptionWait" in script
    assert "(Get-Date).AddHours(6)" not in script


def test_live_installers_require_exact_disk_and_recovery_manifest() -> None:
    for path in ("../iso/live/install-mint.sh", "../iso-uefi/live/install-mint.sh"):
        installer = Path(path).read_text(encoding="utf-8")
        assert "resolve_target_disk_from_manifest" in installer
        assert "WINDOWS_PARTITION_OFFSET_BYTES" in installer
        assert "INSTALLER_PARTITION_OFFSET_BYTES" in installer
        assert "RECOVERY_PARTITION_OFFSET_BYTES" in installer
        assert "RECOVERY_PARTITION_SIZE_BYTES" in installer
        assert "ntfsresize failed; the partition table was not changed" in installer
        assert "WARNING: ntfsresize failed, continuing" not in installer


def test_uefi_one_shot_does_not_reorder_bootorder() -> None:
    script = Path("../Scripts/libertix-uefi-install.ps1").read_text(encoding="utf-8")
    function_body = script.split("function Set-NativeUefiBootOrderOnce", 1)[1].split(
        "function Get-FirmwareBootNumberByDescription", 1
    )[0]

    assert 'Set-FirmwareVariable -Name "BootOrder"' not in function_body
    assert 'Set-FirmwareVariable -Name "BootNext"' in script


def test_uefi_recovery_tasks_are_not_clock_boundary_dependent() -> None:
    script = Path("../Scripts/libertix-register-uefi-recovery-tasks.ps1").read_text(
        encoding="utf-8"
    )
    source = Path("../Pages/ApplyChanges.xaml.cs").read_text(encoding="utf-8")

    assert "New-ScheduledTaskTrigger -AtStartup" in script
    assert "New-ScheduledTaskTrigger -AtLogOn" in script
    assert "-StartWhenAvailable" in script
    assert "StartBoundary" not in script
    assert "libertix-register-uefi-recovery-tasks.ps1" in source
    method_start = source.index("private void InstallUefiRecoveryAgent")
    method_end = source.index("private static void DeleteUefiRecoverySession", method_start)
    assert '"/SC ONSTART /RU SYSTEM' not in source[method_start:method_end]


def test_wpf_storage_preflight_fails_closed() -> None:
    source = Path("../Pages/ApplyChanges.xaml.cs").read_text(encoding="utf-8")
    preflight = Path("../Scripts/libertix-storage-preflight.ps1").read_text(encoding="utf-8")

    assert "DetectFirmwareTypeOrThrow" in source
    assert "Installation was stopped before any disk change" in source
    assert "SYSTEM_DISK_NUMBER" in preflight
    assert "BITLOCKER_SAFE" in preflight
    assert "Exactly one Windows recovery partition is required" in preflight
