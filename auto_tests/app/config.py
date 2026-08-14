from __future__ import annotations

import ipaddress
import re
from pathlib import Path, PurePosixPath
from typing import Literal
from urllib.parse import urlsplit

from pydantic import BaseModel, Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class VMConfig(BaseModel):
    name: str = Field(
        min_length=1,
        max_length=57,
        pattern=r"^[A-Za-z0-9](?:[A-Za-z0-9-]{0,55}[A-Za-z0-9])?$",
    )
    host: str
    os: str
    vnc: str
    username: str = "admin"
    screen_width: int = Field(gt=0, le=16384)
    screen_height: int = Field(gt=0, le=16384)
    vmid: int = Field(gt=0)
    firmware: Literal["bios", "uefi"]
    vnc_keyboard_layout: Literal["fr", "us"] = "us"
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
    ssh_port: int = Field(default=22, ge=1, le=65535)
    ssh_timeout_seconds: float = Field(default=15, gt=0)
    ssh_known_hosts: Path
    command_timeout_seconds: float = Field(default=180, gt=0)
    repository_url: str
    repository_branch: str = "dev"
    smb_root: str
    allowed_smb_roots: tuple[str, ...] = Field(min_length=1)
    allowed_proxmox_vmids: tuple[int, ...] = Field(min_length=1)
    reset_snapshot: str = "clean2"
    proxmox_storage: str = "local-lvm"
    proxmox_storage_min_free_gib: int = Field(default=20, ge=0)
    proxmox_storage_min_free_per_vm_gib: int = Field(default=20, ge=0)
    source_dir_name: str = "Libertix-source"
    release_dir_name: str = "Libertix-release"
    filepool_dir_name: str = "Libertix-filepool"
    filepool_base_url: str
    published_dev_metadata_base_url: str = "https://ekimiateam.github.io/libertix/dev"
    development_static_ipv4_prefix_length: int = Field(ge=1, le=30)
    development_static_ipv4_gateway: str
    development_dns_servers: tuple[str, ...] = Field(min_length=1)

    llm_api_url: str
    llm_api_key: SecretStr
    llm_model: str
    llm_reasoning_effort: Literal["minimal", "low", "medium", "high"] | None = None
    llm_timeout_seconds: float = Field(default=180, gt=0)
    llm_max_attempts: int = Field(default=3, ge=1, le=10)
    llm_retry_base_seconds: float = Field(default=3, gt=0, le=60)

    proxmox_url: str
    proxmox_token_id: str
    proxmox_token_secret: SecretStr
    proxmox_verify_tls: bool = True
    proxmox_ca_bundle: Path | None = None
    proxmox_timeout_seconds: float = Field(default=30, gt=0)
    proxmox_task_timeout_seconds: float = Field(default=300, gt=0)

    runtime_dir: Path = Path(__file__).resolve().parents[1] / "runtime"
    capture_dir: Path = Path(__file__).resolve().parents[1] / "runtime" / "captures"
    operation_log_dir: Path = Path(__file__).resolve().parents[1] / "logs"
    vnc_timeout_seconds: float = Field(default=15, gt=0)
    launch_wait_seconds: float = Field(default=2, gt=0)
    automation_monitor_interval_seconds: float = Field(default=30, gt=0)
    automation_monitor_timeout_seconds: float = Field(default=23400, gt=0)
    post_install_boot_timeout_seconds: float = Field(default=1200, gt=0)
    post_install_poll_interval_seconds: float = Field(default=10, gt=0)
    post_install_grub_detection_timeout_seconds: float = Field(default=20, gt=0)
    post_install_grub_detection_interval_seconds: float = Field(default=1, gt=0)
    log_level: str = "INFO"
    vms: tuple[VMConfig, ...] = Field(min_length=1)

    @field_validator("smb_root")
    @classmethod
    def validate_smb_root(cls, value: str) -> str:
        normalized = str(PurePosixPath(value))
        if not normalized.startswith("/") or len(PurePosixPath(normalized).parts) < 3:
            raise ValueError("smb_root must be an absolute, dedicated subdirectory")
        return normalized

    @field_validator("allowed_smb_roots")
    @classmethod
    def validate_allowed_smb_roots(cls, values: tuple[str, ...]) -> tuple[str, ...]:
        normalized = tuple(str(PurePosixPath(value)) for value in values)
        if any(
            not value.startswith("/") or len(PurePosixPath(value).parts) < 3 for value in normalized
        ):
            raise ValueError("allowed_smb_roots must contain only dedicated absolute paths")
        if len(normalized) != len(set(normalized)):
            raise ValueError("allowed_smb_roots must not contain duplicates")
        return normalized

    @field_validator("allowed_proxmox_vmids")
    @classmethod
    def validate_allowed_proxmox_vmids(cls, values: tuple[int, ...]) -> tuple[int, ...]:
        if any(value <= 0 for value in values):
            raise ValueError("allowed_proxmox_vmids must contain only positive VM IDs")
        if len(values) != len(set(values)):
            raise ValueError("allowed_proxmox_vmids must not contain duplicates")
        return values

    @field_validator("filepool_base_url", "published_dev_metadata_base_url")
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
                "metadata URLs must be absolute HTTP(S) URLs without credentials, "
                "a query or a fragment"
            )
        return value.rstrip("/")

    @field_validator("reset_snapshot", "proxmox_storage")
    @classmethod
    def validate_proxmox_identifier(cls, value: str) -> str:
        normalized = value.strip()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", normalized):
            raise ValueError(
                "Proxmox identifiers must use only letters, digits, dot, underscore or dash"
            )
        return normalized

    @field_validator("source_dir_name", "release_dir_name", "filepool_dir_name")
    @classmethod
    def validate_workspace_directory_name(cls, value: str) -> str:
        normalized = value.strip()
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", normalized):
            raise ValueError(
                "source_dir_name, release_dir_name and filepool_dir_name "
                "must be simple directory names"
            )
        return normalized

    @field_validator("development_static_ipv4_gateway")
    @classmethod
    def validate_development_gateway(cls, value: str) -> str:
        try:
            address = ipaddress.IPv4Address(value)
        except ipaddress.AddressValueError as error:
            raise ValueError("development_static_ipv4_gateway must be IPv4") from error
        if not cls._is_configurable_ipv4(address):
            raise ValueError("development_static_ipv4_gateway is not a configurable unicast IPv4")
        return str(address)

    @field_validator("development_dns_servers")
    @classmethod
    def validate_development_dns_servers(cls, values: tuple[str, ...]) -> tuple[str, ...]:
        try:
            addresses = tuple(ipaddress.IPv4Address(value) for value in values)
        except ipaddress.AddressValueError as error:
            raise ValueError("development_dns_servers must contain only IPv4 addresses") from error
        if any(not cls._is_configurable_ipv4(address) for address in addresses):
            raise ValueError("development_dns_servers contains a non-configurable IPv4 address")
        normalized = tuple(str(address) for address in addresses)
        if len(normalized) != len(set(normalized)):
            raise ValueError("development_dns_servers must not contain duplicates")
        return normalized

    @staticmethod
    def _is_configurable_ipv4(address: ipaddress.IPv4Address) -> bool:
        return not (
            address.is_unspecified
            or address.is_loopback
            or address.is_link_local
            or address.is_multicast
            or address.is_reserved
        )

    @model_validator(mode="after")
    def validate_vm_identity(self) -> Settings:
        names = [vm.name.casefold() for vm in self.vms]
        vmids = [vm.vmid for vm in self.vms]
        if len(names) != len(set(names)):
            raise ValueError("VM names must be unique")
        if len(vmids) != len(set(vmids)):
            raise ValueError("VM IDs must be unique")
        if self.smb_root not in self.allowed_smb_roots:
            raise ValueError("smb_root is outside allowed_smb_roots")
        if not set(vmids).issubset(set(self.allowed_proxmox_vmids)):
            raise ValueError("A configured VM ID is outside allowed_proxmox_vmids")
        runtime_dir = self.runtime_dir.resolve()
        capture_dir = self.capture_dir.resolve()
        if capture_dir == runtime_dir or runtime_dir not in capture_dir.parents:
            raise ValueError("capture_dir must be a strict child of runtime_dir")
        return self


def get_settings() -> Settings:
    return Settings()  # type: ignore[call-arg]
