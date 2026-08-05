from __future__ import annotations

import hashlib
import json
import logging
import re
import shlex
import tarfile
import tempfile
import time
import uuid
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any

from app.clients.ssh import CommandResult, SSHClient
from app.clients.vision_llm import VisionLLMClient
from app.clients.vnc import VNCClient
from app.config import Settings, VMConfig
from app.errors import WorkflowError
from app.models import OperationResult, SourceMode, StepResult
from app.services.common import ResultBuilder
from app.services.source_tree import LocalSourceTree

logger = logging.getLogger(__name__)


class ValidationService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._capture_dir = Path(settings.capture_dir)
        self.vision_llm = VisionLLMClient(
            settings.llm_api_key.get_secret_value(),
            settings.llm_api_url,
            settings.llm_model,
            settings.llm_timeout_seconds,
            reasoning_effort=settings.llm_reasoning_effort,
            max_attempts=settings.llm_max_attempts,
            retry_base_seconds=settings.llm_retry_base_seconds,
        )
        self.vnc = VNCClient()

    def run(
        self,
        vm_selectors: Sequence[str] | None = None,
        *,
        source: SourceMode = "remote",
        on_step: Callable[[StepResult], None] | None = None,
    ) -> OperationResult:
        self.settings.capture_dir.mkdir(parents=True, exist_ok=True)
        capture_workspace = tempfile.TemporaryDirectory(
            prefix="validation-", dir=self.settings.capture_dir
        )
        previous_capture_dir = self._capture_dir
        self._capture_dir = Path(capture_workspace.name)
        result = ResultBuilder("validation", on_step=on_step)
        try:
            selected_vms = self.select_vms(vm_selectors)
            executable = self.prepare_server(result, source=source)
            windows_path = self.to_windows_share_path(executable)
            result.ok("release.path", "Executable path resolved", path=str(windows_path))
            with ThreadPoolExecutor(max_workers=len(selected_vms)) as executor:
                futures = {
                    executor.submit(self._validate_vm_isolated, vm, windows_path, on_step): vm
                    for vm in selected_vms
                }
                failures: list[OperationResult] = []
                for future in as_completed(futures):
                    vm_result = future.result()
                    result.steps.extend(vm_result.steps)
                    if vm_result.status == "error":
                        failures.append(vm_result)
                if failures:
                    return OperationResult(
                        status="error",
                        operation="validation",
                        message="; ".join(item.message for item in failures),
                        steps=result.steps,
                    )
            count = len(selected_vms)
            plural = "s" if count > 1 else ""
            return result.success(f"Validation completed successfully on {count} VM{plural}")
        except WorkflowError as exc:
            return result.failure(exc)
        except Exception as exc:
            logger.exception("Unexpected internal error")
            return result.failure(
                WorkflowError(
                    "internal", "Unexpected internal error", details={"type": type(exc).__name__}
                )
            )
        finally:
            self._capture_dir = previous_capture_dir
            capture_workspace.cleanup()

    def select_vms(self, selectors: Sequence[str] | None) -> tuple[VMConfig, ...]:
        if not selectors:
            return self.settings.vms

        by_alias: dict[str, VMConfig] = {}
        for vm in self.settings.vms:
            aliases = {
                vm.name,
                vm.host,
                vm.os,
                vm.os.replace("Windows ", "win"),
                vm.os.replace("Windows ", ""),
            }
            if "Windows 10 BIOS" in vm.os:
                aliases.update({"bios", "win10-bios", "10-bios", "windows10-bios"})
            if "Windows 10 UEFI" in vm.os:
                aliases.update({"win10-uefi", "10-uefi", "windows10-uefi", "10 uefi"})
            if "Windows 11 UEFI" in vm.os:
                aliases.update({"win11", "win11-uefi", "11-uefi", "windows11-uefi", "11 uefi"})
            for alias in aliases:
                by_alias[self._normalize_selector(alias)] = vm

        selected: list[VMConfig] = []
        unknown: list[str] = []
        for selector in selectors:
            vm = by_alias.get(self._normalize_selector(selector))
            if not vm:
                unknown.append(selector)
                continue
            if vm not in selected:
                selected.append(vm)

        if unknown:
            raise WorkflowError(
                "validation.select_vms",
                "Unknown VM selector",
                details={
                    "unknown": unknown,
                    "accepted_examples": [
                        "vm1",
                        "vm2",
                        "vm3",
                        "win10-bios",
                        "win10-uefi",
                        "win11-uefi",
                    ],
                },
            )
        return tuple(selected)

    @staticmethod
    def _normalize_selector(value: str) -> str:
        return "".join(ch for ch in value.lower() if ch.isalnum())

    def ssh(self, host: str, username: str, password: str) -> SSHClient:
        return SSHClient(
            host,
            username,
            password,
            known_hosts_path=self.settings.ssh_known_hosts,
            port=self.settings.ssh_port,
            connect_timeout=self.settings.ssh_timeout_seconds,
        )

    def run_windows_script(
        self,
        ssh: SSHClient,
        *,
        script_name: str,
        config: dict[str, Any],
        step: str,
        timeout: float,
    ) -> CommandResult:
        """Upload, execute, then remove one repository-owned PowerShell script.

        Python keeps only orchestration and structured logging. Windows-specific
        actions live in app/scripts/*.ps1 with a small JSON config file uploaded
        for the current run. This avoids unreadable inline PowerShell and keeps
        passwords out of command lines.
        """

        script_path = Path(__file__).resolve().parents[1] / "scripts" / script_name
        if not script_path.is_file():
            raise WorkflowError(
                step,
                "PowerShell script not found",
                details={"path": str(script_path), "script": script_name},
            )

        run_id = uuid.uuid4().hex
        stem = script_path.stem.replace("_", "-")
        remote_script_sftp = f"C:/Windows/Temp/auto-tests-{stem}-{run_id}.ps1"
        remote_config_sftp = f"C:/Windows/Temp/auto-tests-{stem}-{run_id}.json"
        remote_script_ps = remote_script_sftp.replace("/", "\\")
        remote_config_ps = remote_config_sftp.replace("/", "\\")

        command = (
            "powershell.exe -NoLogo -NoProfile -NonInteractive "
            f'-ExecutionPolicy Bypass -File "{remote_script_ps}" -ConfigPath "{remote_config_ps}"'
        )
        cleanup_command = (
            "powershell.exe -NoLogo -NoProfile -NonInteractive "
            f"-Command \"Remove-Item -LiteralPath '{remote_script_ps}','{remote_config_ps}' "
            '-Force -ErrorAction SilentlyContinue"'
        )

        ssh.upload_text(
            remote_script_sftp,
            script_path.read_text(encoding="utf-8"),
            step=f"{step}.upload_script",
        )
        ssh.upload_text(
            remote_config_sftp,
            json.dumps(config, ensure_ascii=False),
            step=f"{step}.upload_config",
        )
        try:
            return ssh.run(command, step=step, timeout=timeout, sensitive=True)
        finally:
            ssh.run(
                cleanup_command,
                step=f"{step}.cleanup_script",
                timeout=30,
                check=False,
                sensitive=True,
            )

    @staticmethod
    def parse_powershell_results(stdout: str, *, prefixes: Sequence[str]) -> dict[str, str]:
        """Extract NAME=VALUE lines emitted intentionally by our .ps1 scripts."""

        accepted = tuple(f"{prefix}=" for prefix in prefixes)
        return dict(line.split("=", 1) for line in stdout.splitlines() if line.startswith(accepted))

    def prepare_server(
        self, result: ResultBuilder, *, source: SourceMode = "remote"
    ) -> PurePosixPath:
        s = self.settings
        password = s.main_ssh_password.get_secret_value()
        source_path = f"{s.smb_root}/{s.source_dir_name}"
        with self.ssh(s.main_ssh_host, s.main_ssh_user, password) as ssh:
            ssh.run(
                "set -eu; "
                f"p={shlex.quote(s.smb_root)}; "
                'if [ ! -e "$p" ]; then echo "Path is missing: $p" >&2; exit 10; fi; '
                'if [ ! -d "$p" ]; then echo "Not a directory: $p" >&2; exit 11; fi; '
                'if [ ! -w "$p" ]; then '
                'echo "Dossier non inscriptible: $p" >&2; exit 12; fi',
                step="server.check_smb",
                timeout=s.command_timeout_seconds,
            )
            result.ok(
                "server.check_smb",
                "The /root/smb directory exists and is accessible",
                target=s.main_ssh_host,
            )

            if source == "remote":
                # Remote mode is the production-like path: clone the configured
                # branch on the Samba host before compiling on the Windows build VM.
                ssh.run(
                    "set -eu; "
                    "command -v git >/dev/null 2>&1 || { "
                    'echo "git is required on the Samba host; '
                    'install it explicitly before remote-source builds" >&2; '
                    "exit 127; }",
                    step="server.ensure_tools",
                    timeout=s.command_timeout_seconds,
                )
                result.ok(
                    "server.ensure_tools",
                    "Git prerequisite available",
                    target=s.main_ssh_host,
                    source="remote",
                )

                clone_script = (
                    "set -eu; "
                    f"if [ -d {shlex.quote(source_path + '/.git')} ]; then "
                    f"git -C {shlex.quote(source_path)} remote get-url origin | "
                    f"grep -Fx {shlex.quote(s.repository_url)}; "
                    f"git -C {shlex.quote(source_path)} fetch origin "
                    f"{shlex.quote(s.repository_branch)}; "
                    f"git -C {shlex.quote(source_path)} checkout -B "
                    f"{shlex.quote(s.repository_branch)} "
                    f"origin/{shlex.quote(s.repository_branch)}; "
                    f"git -C {shlex.quote(source_path)} reset --hard "
                    f"origin/{shlex.quote(s.repository_branch)}; "
                    f"git -C {shlex.quote(source_path)} clean -ffdqx; "
                    f"elif [ -e {shlex.quote(source_path)} ]; then exit 21; "
                    f"else git clone --branch {shlex.quote(s.repository_branch)} -- "
                    f"{shlex.quote(s.repository_url)} {shlex.quote(source_path)}; fi"
                )
                ssh.run(clone_script, step="server.clone", timeout=s.command_timeout_seconds)
                revision = ssh.run(
                    f"git -C {shlex.quote(source_path)} rev-parse HEAD",
                    step="server.source_revision",
                    timeout=s.command_timeout_seconds,
                ).stdout.strip()
                if not re.fullmatch(r"[0-9a-f]{40}", revision):
                    raise WorkflowError(
                        "server.source_revision",
                        "Invalid source Git revision",
                        details={"revision": revision},
                    )
                result.ok(
                    "server.clone",
                    "Libertix clone present with verified origin and branch",
                    target=s.main_ssh_host,
                    branch=s.repository_branch,
                    revision=revision,
                    source="remote",
                )
            else:
                # Local mode is for validating unpushed changes. It archives this
                # working tree and expands it directly into the Samba source folder.
                self._copy_local_source_to_server(ssh, result, source_path)

        return self._compile_release_on_build_vm(result)

    def _copy_local_source_to_server(
        self, ssh: SSHClient, result: ResultBuilder, source_path: str
    ) -> None:
        s = self.settings
        root = self._local_repository_root()
        if not (root / "Libertix.sln").is_file() or not (root / "Libertix.csproj").is_file():
            raise WorkflowError(
                "server.copy_local_source",
                "The local working tree does not contain the expected Libertix project files",
                details={"path": str(root)},
            )

        with tempfile.NamedTemporaryFile(
            prefix="libertix-source-", suffix=".tar.gz", delete=False
        ) as tmp:
            archive = Path(tmp.name)
        try:
            with tarfile.open(archive, "w:gz") as tar:
                for path in sorted(root.rglob("*")):
                    if not self._include_local_source_path(root, path):
                        continue
                    tar.add(path, arcname=path.relative_to(root), recursive=False)

            archive_sha256 = hashlib.sha256(archive.read_bytes()).hexdigest()

            remote_archive = f"/tmp/{archive.name}"
            ssh.upload_file(archive, remote_archive, step="server.copy_local_source.upload")
            # The destination is removed only inside the configured Samba root.
            # This avoids accidentally deleting an arbitrary server path.
            install_script = (
                "set -eu; "
                f"dest={shlex.quote(source_path)}; archive={shlex.quote(remote_archive)}; "
                f"root={shlex.quote(s.smb_root)}; "
                'case "$dest" in "$root"/*) ;; *) '
                'echo "Destination refusee: $dest" >&2; exit 22;; esac; '
                'rm -rf "$dest"; mkdir -p "$dest"; '
                'tar -xzf "$archive" -C "$dest"; rm -f "$archive"; '
                'test -f "$dest/Libertix.sln"; test -f "$dest/Libertix.csproj"'
            )
            ssh.run(
                install_script,
                step="server.copy_local_source",
                timeout=max(s.command_timeout_seconds, 600),
            )
            result.ok(
                "server.copy_local_source",
                "Local working tree copied to Samba",
                target=s.main_ssh_host,
                source="local",
                local_path=str(root),
                remote_path=source_path,
                archive_size=archive.stat().st_size,
                archive_sha256=archive_sha256,
            )
        finally:
            archive.unlink(missing_ok=True)

    @staticmethod
    def _local_repository_root() -> Path:
        return LocalSourceTree.repository_root()

    @staticmethod
    def _include_local_source_path(root: Path, path: Path) -> bool:
        return LocalSourceTree.include(root, path)

    def _compile_release_on_build_vm(self, result: ResultBuilder) -> PurePosixPath:
        s = self.settings
        config = {
            "share": s.samba_unc,
            "source": str(PureWindowsPath(s.samba_unc) / s.source_dir_name),
            "release": str(PureWindowsPath(s.samba_unc) / s.release_dir_name),
            "samba_username": s.samba_username,
            "samba_password": s.samba_password.get_secret_value(),
        }

        with self.ssh(
            s.build_vm_host,
            s.build_vm_user,
            s.build_vm_password.get_secret_value(),
        ) as ssh:
            response = self.run_windows_script(
                ssh,
                script_name="build_libertix.ps1",
                config=config,
                step="build_vm.compile",
                timeout=max(s.command_timeout_seconds, 900),
            )

        values = self.parse_powershell_results(
            response.stdout,
            prefixes=(
                "MSBUILD",
                "VSTEST",
                "TEMP_BUILD_DIR",
                "FINAL_EXE",
                "FINAL_EXE_SHA256",
            ),
        )
        final_exe = values.get("FINAL_EXE")
        if not final_exe:
            raise WorkflowError(
                "build_vm.compile",
                "The build VM did not confirm the final path",
                details={"target": s.build_vm_host},
            )
        result.ok(
            "build_vm.compile",
            "Libertix compiled on the Windows VM and copied to Samba",
            target=s.build_vm_host,
            msbuild=values.get("MSBUILD"),
            vstest=values.get("VSTEST"),
            executable_sha256=values.get("FINAL_EXE_SHA256"),
            temp_build_dir=values.get("TEMP_BUILD_DIR"),
            cleanup="temporary directory, script, and config removed after the command",
        )
        return PurePosixPath(f"{s.smb_root}/{s.release_dir_name}/Libertix.exe")

    def to_windows_share_path(self, path: PurePosixPath) -> PureWindowsPath:
        root = PurePosixPath(self.settings.smb_root)
        try:
            relative = path.relative_to(root)
        except ValueError as exc:
            raise WorkflowError("release.path", "Executable is outside /root/smb") from exc
        return PureWindowsPath("Z:/") / PureWindowsPath(*relative.parts)

    def _validate_vm(
        self, vm: VMConfig, executable: PureWindowsPath, result: ResultBuilder
    ) -> None:
        local_executable = self.deploy_to_documents(vm, executable)
        result.ok(
            "vm.deploy",
            "Release copied from Samba to the Documents directory",
            target=vm.host,
            vm=vm.name,
            executable=str(local_executable),
        )
        launch = self._launch_interactive(vm, local_executable, result)
        result.ok(
            "vm.launch",
            "Libertix launched in the graphical session and process confirmed",
            target=vm.host,
            vm=vm.name,
            **launch,
        )
        logger.info("Waiting before capture", extra={"step": "vm.wait", "target": vm.host})
        time.sleep(self.settings.launch_wait_seconds)
        result.ok(
            "vm.wait",
            "Post-launch wait completed",
            target=vm.host,
            seconds=self.settings.launch_wait_seconds,
        )

        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
        capture = self._capture_dir / f"{vm.name}-{stamp}.png"
        self.vnc.capture(vm.vnc, capture)
        result.ok("vnc.capture", "VNC capture saved", target=vm.vnc, path=str(capture))

        verdict = self.vision_llm.analyze(capture, vm.name, vm.os)
        context = verdict.model_dump()
        if not verdict.valid:
            raise WorkflowError(
                "llm.verdict",
                "Visual validation reported a problem",
                details={"vm": vm.name, **context},
            )
        result.ok("llm.verdict", "Validation visuelle positive", target=vm.name, **context)

    def _validate_vm_isolated(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        on_step: Callable[[StepResult], None] | None = None,
    ) -> OperationResult:
        result = ResultBuilder("validation", on_step=on_step)
        try:
            self._validate_vm(vm, executable, result)
            return result.success(f"Validation completed successfully on {vm.name}")
        except WorkflowError as exc:
            return result.failure(exc)
        except Exception as exc:
            return result.failure(
                WorkflowError(
                    "vm.validation.internal_error",
                    f"Unexpected error while validating {vm.name}",
                    details={
                        "vm": vm.name,
                        "host": vm.host,
                        "exception_type": type(exc).__name__,
                        "error": str(exc),
                    },
                )
            )

    def deploy_to_documents(self, vm: VMConfig, executable: PureWindowsPath) -> PureWindowsPath:
        share_release = PureWindowsPath("Z:/") / self.settings.release_dir_name
        try:
            relative_executable = executable.relative_to(share_release)
        except ValueError as exc:
            raise WorkflowError(
                "vm.deploy",
                "The executable is not inside the Samba release directory",
                details={"executable": str(executable)},
            ) from exc

        config = {
            "samba_unc": self.settings.samba_unc,
            "samba_username": self.settings.samba_username,
            "samba_password": self.settings.samba_password.get_secret_value(),
            "source": str(
                PureWindowsPath(self.settings.samba_unc) / self.settings.release_dir_name
            ),
            "release_dir_name": self.settings.release_dir_name,
            "relative_executable": str(relative_executable),
        }
        with self.ssh(
            vm.host, vm.username, self.settings.windows_ssh_password.get_secret_value()
        ) as ssh:
            response = self.run_windows_script(
                ssh,
                script_name="deploy_libertix.ps1",
                config=config,
                step="vm.deploy",
                timeout=max(self.settings.command_timeout_seconds, 300),
            )
        values = self.parse_powershell_results(
            response.stdout, prefixes=("LOCAL_EXE", "LOCAL_EXE_SHA256")
        )
        if not values.get("LOCAL_EXE") or not re.fullmatch(
            r"[0-9a-f]{64}", values.get("LOCAL_EXE_SHA256", "")
        ):
            raise WorkflowError(
                "vm.deploy",
                "The local Libertix path was not confirmed",
                details={"vm": vm.name, "host": vm.host},
            )
        return PureWindowsPath(values["LOCAL_EXE"])

    def _launch_interactive(
        self, vm: VMConfig, executable: PureWindowsPath, result: ResultBuilder
    ) -> dict[str, object]:
        del result
        task_name = f"LibertixValidation_{vm.name}"
        with self.ssh(
            vm.host, vm.username, self.settings.windows_ssh_password.get_secret_value()
        ) as ssh:
            response = self.run_windows_script(
                ssh,
                script_name="launch_libertix_elevated.ps1",
                config={
                    "executable": str(executable),
                    "task_name": task_name,
                    "filepool_base_url": self.settings.filepool_base_url,
                    "development_static_ipv4": vm.host,
                    "development_static_ipv4_prefix_length": (
                        self.settings.development_static_ipv4_prefix_length
                    ),
                    "development_static_ipv4_gateway": (
                        self.settings.development_static_ipv4_gateway
                    ),
                    "development_dns_servers": list(self.settings.development_dns_servers),
                },
                step="vm.launch_elevated",
                timeout=90,
            )
        values = self.parse_powershell_results(
            response.stdout, prefixes=("PID", "SESSION_ID", "TASK_NAME", "EXECUTABLE")
        )
        if not values.get("PID", "").isdigit() or not values.get("SESSION_ID", "").isdigit():
            raise WorkflowError(
                "vm.launch_elevated",
                "Elevated Libertix process was not confirmed",
                details={"vm": vm.name, "host": vm.host, "stdout": response.stdout[-4000:]},
            )
        if PureWindowsPath(values.get("EXECUTABLE", "")) != executable:
            raise WorkflowError(
                "vm.launch_elevated",
                "The launched process does not match the deployed executable",
                details={"vm": vm.name, "expected": str(executable)},
            )
        return {
            "pid": int(values["PID"]),
            "session_id": int(values["SESSION_ID"]),
            "window_handle": 0,
            "task_name": values.get("TASK_NAME", task_name),
            "launch_method": "scheduled_task_elevated",
            "visual_confirmation": "capture_vnc_et_llm",
        }
