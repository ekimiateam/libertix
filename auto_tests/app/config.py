from __future__ import annotations

from pathlib import Path

from pydantic import BaseModel, SecretStr, field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class VMConfig(BaseModel):
    name: str
    host: str
    os: str
    vnc: str
    username: str = "admin"
    screen_width: int
    screen_height: int


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
    command_timeout_seconds: float = 180

    repository_url: str
    smb_root: str
    source_dir_name: str = "LinuxGate-source"
    release_dir_name: str = "LinuxGate-release"

    llm_api_url: str
    llm_api_key: SecretStr
    llm_model: str
    llm_timeout_seconds: float = 180
    llm_max_attempts: int = 3
    llm_retry_base_seconds: float = 3

    proxmox_url: str
    proxmox_token_id: str
    proxmox_token_secret: SecretStr
    proxmox_verify_tls: bool = False
    proxmox_timeout_seconds: float = 30
    proxmox_task_timeout_seconds: float = 300

    capture_dir: Path = Path("captures")
    launch_wait_seconds: float = 2
    log_level: str = "INFO"
    api_access_token: SecretStr

    vms: tuple[VMConfig, ...]

    @field_validator("smb_root")
    @classmethod
    def validate_smb_root(cls, value: str) -> str:
        if value.rstrip("/") != "/root/smb":
            raise ValueError("smb_root doit rester strictement /root/smb")
        return "/root/smb"


def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
