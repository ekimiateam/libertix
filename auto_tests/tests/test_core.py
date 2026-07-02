from pathlib import PurePosixPath, PureWindowsPath

import pytest
from pydantic import ValidationError

from app.clients.vnc import VNCClient
from app.config import Settings
from app.services.automation import AutomationService
from app.services.reset import RESET_SNAPSHOT, RESET_VM_IDS
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
        "repository_url": "https://github.com/felix068/LinuxGate.git",
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
        PurePosixPath("/root/smb/LinuxGate-release/folder/LinuxGate.exe")
    )
    assert actual == PureWindowsPath("Z:/LinuxGate-release/folder/LinuxGate.exe")


def test_smb_root_is_strictly_guarded() -> None:
    with pytest.raises(ValidationError):
        settings(smb_root="/")


def test_reset_scope_is_exact() -> None:
    assert RESET_VM_IDS == (500, 501, 502)
    assert RESET_SNAPSHOT == "clean2"


def test_vnc_display_is_converted_to_tcp_port() -> None:
    assert VNCClient._vncdotool_address("192.168.1.166:10") == "192.168.1.166::5910"


def test_validation_vm_selector_accepts_aliases() -> None:
    service = ValidationService(settings())

    selected = service._select_vms(["10 uefi"])  # noqa: SLF001

    assert [vm.name for vm in selected] == ["vm2"]


def test_validation_vm_selector_rejects_unknown() -> None:
    service = ValidationService(settings())

    with pytest.raises(Exception, match="Sélecteur VM inconnu"):
        service._select_vms(["not-a-vm"])  # noqa: SLF001


def test_automation_scope_accepts_only_vm500() -> None:
    service = AutomationService(settings())
    selected = service.validation._select_vms(["vm1"])  # noqa: SLF001

    service._assert_autoclick_scope(selected, ["vm1"])  # noqa: SLF001


def test_automation_scope_rejects_implicit_all_vms() -> None:
    service = AutomationService(settings())
    selected = service.validation._select_vms(None)  # noqa: SLF001

    with pytest.raises(Exception, match="Auto-click LinuxGate refusé"):
        service._assert_autoclick_scope(selected, None)  # noqa: SLF001


def test_automation_scope_rejects_uefi_vm() -> None:
    service = AutomationService(settings())
    selected = service.validation._select_vms(["vm2"])  # noqa: SLF001

    with pytest.raises(Exception, match="VM500"):
        service._assert_autoclick_scope(selected, ["vm2"])  # noqa: SLF001
