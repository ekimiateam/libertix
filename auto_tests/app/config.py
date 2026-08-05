from __future__ import annotations

from pathlib import Path
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class VMConfig(BaseModel):
    name: str
    host: str
    os: str
    vnc: str
    username: str = "admin"
    screen_width: int = Field(gt=0)
    screen_height: int = Field(gt=0)
    vmid: int = Field(gt=0)
    firmware: Literal["bios", "uefi"]
    vnc_keyboard_layout: Literal["fr", "us"] = "us"
    disable_defender_for_automation: bool = False
    automation_enabled: bool = False


class Settings(BaseSettings):
    """Runtime configuration loaded from .env.

    This class deliberately describes the expected schema only. Hosts, VM list,
    URLs and credentials are environment data, so they stay in `.env` instead of
    being hardcoded in Python.
    """

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    main_ssh_host: str
    main_ssh_user: str
    main_ssh_password: SecretStr
    windows_ssh_password: SecretStr
    samba_unc: str
    samba_username: str
    samba_password: SecretStr
    build_vm_host: str
    build_vm_user: str
    build_vm_password: SecretStr
    ssh_port: int = 22
    ssh_timeout_seconds: float = 15
    ssh_known_hosts: Path
    command_timeout_seconds: float = 180
    repository_url: str
    repository_branch: str = "dev"
    smb_root: str
    source_dir_name: str = "Libertix-source"
    release_dir_name: str = "Libertix-release"
    filepool_base_url: str

    llm_api_url: str
    llm_api_key: SecretStr
    llm_model: str
    llm_reasoning_effort: Literal["minimal", "low", "medium", "high"] | None = None
    llm_timeout_seconds: float = 180
    llm_max_attempts: int = 3
    llm_retry_base_seconds: float = 3

    proxmox_url: str
    proxmox_token_id: str
    proxmox_token_secret: SecretStr
    proxmox_verify_tls: bool = True
    proxmox_ca_bundle: Path | None = None
    proxmox_timeout_seconds: float = 30
    proxmox_task_timeout_seconds: float = 300

    capture_dir: Path = Path("/tmp/libertix-auto-tests-captures")
    operation_log_dir: Path = Path(__file__).resolve().parents[1] / "logs"
    launch_wait_seconds: float = 2
    automation_monitor_interval_seconds: float = 30
    automation_monitor_timeout_seconds: float = 23400
    post_install_boot_timeout_seconds: float = 1200
    post_install_poll_interval_seconds: float = 10
    log_level: str = "INFO"
    api_access_token: SecretStr

    vms: tuple[VMConfig, ...]

    @field_validator("smb_root")
    @classmethod
    def validate_smb_root(cls, value: str) -> str:
        if value.rstrip("/") != "/root/smb":
            raise ValueError("smb_root doit rester strictement /root/smb")
        return "/root/smb"

    @field_validator("filepool_base_url")
    @classmethod
    def validate_filepool_base_url(cls, value: str) -> str:
        parsed = urlsplit(value)
        if (
            parsed.scheme not in {"http", "https"}
            or not parsed.netloc
            or parsed.username is not None
            or parsed.password is not None
            or parsed.query
            or parsed.fragment
        ):
            raise ValueError(
                "filepool_base_url must be an absolute HTTP(S) URL without credentials, "
                "a query or a fragment"
            )
        return value.rstrip("/")

    @model_validator(mode="after")
    def validate_vm_identity(self) -> Settings:
        names = [vm.name.casefold() for vm in self.vms]
        vmids = [vm.vmid for vm in self.vms]
        if len(names) != len(set(names)):
            raise ValueError("VM names must be unique")
        if len(vmids) != len(set(vmids)):
            raise ValueError("VM IDs must be unique")
        if not set(vmids).issubset({500, 501, 502}):
            raise ValueError("Only Proxmox VM IDs 500, 501 and 502 are allowed")
        return self


def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
