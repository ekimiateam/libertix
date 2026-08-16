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

from app.api_runtime import (
    cleanup_operation_artifacts,
    create_capture_workspace,
    mark_capture_workspace_complete,
)
from app.clients.ssh import CommandResult, SSHClient
from app.clients.vnc import VNCClient
from app.config import Settings, VMConfig
from app.errors import WorkflowError
from app.models import OperationResult, SourceMode, StepResult
from app.published_release import download_published_dev_release
from app.services.common import ResultBuilder
from app.services.source_tree import LocalSourceTree

logger = logging.getLogger(__name__)


class ValidationService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self._capture_dir = Path(settings.capture_dir)
        self.vnc = VNCClient(settings.vnc_timeout_seconds)

    def run(
        self,
        vm_selectors: Sequence[str] | None = None,
        *,
        source: SourceMode = "remote",
        on_step: Callable[[StepResult], None] | None = None,
        run_workspace: Path | None = None,
    ) -> OperationResult:
        owns_workspace = run_workspace is None
        workspace = run_workspace or create_capture_workspace(self.settings, "validation")
        capture_dir = workspace / "captures"
        capture_dir.mkdir(mode=0o700, exist_ok=True)
        previous_capture_dir = self._capture_dir
        self._capture_dir = capture_dir
        result = ResultBuilder("validation", on_step=on_step)
        try:
            result.ok(
                "validation.run_workspace",
                "Validation run workspace initialized",
                path=str(workspace),
                capture_path=str(capture_dir),
            )
            selected_vms = self.select_vms(vm_selectors)
            executable = self.prepare_server(result, source=source)
            windows_path = self.to_windows_share_path(executable)
            result.ok("release.path", "Executable path resolved", path=str(windows_path))
            with ThreadPoolExecutor(max_workers=len(selected_vms)) as executor:
                futures = {
                    executor.submit(
                        self._validate_vm_isolated,
                        vm,
                        windows_path,
                        on_step,
                        use_default_filepool=source == "published",
                    ): vm
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
            if owns_workspace:
                mark_capture_workspace_complete(workspace)
                cleanup_operation_artifacts(self.settings)

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
                str(vm.vmid),
                f"vm{vm.vmid}",
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
                    "accepted_examples": [vm.name for vm in self.settings.vms],
                },
            )

        return tuple(selected)

    @staticmethod
    def _normalize_selector(value: str) -> str:
        return "".join(ch for ch in value.lower() if ch.isalnum())

    def ssh(
        self, host: str, username: str, password: str, *, remote_os: str = "linux"
    ) -> SSHClient:
        return SSHClient(
            host,
            username,
            password,
            known_hosts_path=self.settings.ssh_known_hosts,
            port=self.settings.ssh_port,
            connect_timeout=self.settings.ssh_timeout_seconds,
            remote_os=remote_os,
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

        try:
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
            return ssh.run(command, step=step, timeout=timeout, sensitive=True)
        finally:
            try:
                ssh.run(
                    cleanup_command,
                    step=f"{step}.cleanup_script",
                    timeout=30,
                    check=False,
                    sensitive=True,
                )
            except WorkflowError as exc:
                # A timed-out remote check can close its SSH transport. Cleanup
                # is best-effort and must not replace the diagnostic from the
                # check that actually failed.
                logger.warning(
                    "Temporary Windows test files could not be removed",
                    extra={"step": f"{step}.cleanup_script", "target": ssh.host},
                    exc_info=exc,
                )

    def run_linux_script(
        self,
        ssh: SSHClient,
        *,
        script_name: str,
        arguments: Sequence[str],
        step: str,
        timeout: float,
    ) -> CommandResult:
        """Upload, execute, then remove one repository-owned Linux helper."""

        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", script_name):
            raise WorkflowError(step, "Linux helper script name is invalid")
        script_path = Path(__file__).resolve().parents[1] / "scripts" / script_name
        if not script_path.is_file():
            raise WorkflowError(
                step,
                "Linux helper script not found",
                details={"path": str(script_path), "script": script_name},
            )

        run_id = uuid.uuid4().hex
        remote_script = f"/tmp/libertix-auto-tests-{run_id}-{script_path.name}"
        command = " ".join(
            ["python3", shlex.quote(remote_script), *(shlex.quote(value) for value in arguments)]
        )
        cleanup_command = (
            "python3 -c "
            + shlex.quote("import pathlib,sys; pathlib.Path(sys.argv[1]).unlink(missing_ok=True)")
            + " "
            + shlex.quote(remote_script)
        )
        try:
            ssh.upload_text(
                remote_script,
                script_path.read_text(encoding="utf-8"),
                step=f"{step}.upload_script",
            )
            return ssh.run(command, step=step, timeout=timeout)
        finally:
            try:
                ssh.run(
                    cleanup_command,
                    step=f"{step}.cleanup_script",
                    timeout=30,
                    check=False,
                )
            except WorkflowError as exc:
                logger.warning(
                    "Temporary Linux test helper could not be removed",
                    extra={"step": f"{step}.cleanup_script", "target": ssh.host},
                    exc_info=exc,
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
        published_executable: PurePosixPath | None = None
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
                f"The {s.smb_root} directory exists and is accessible",
                target=s.main_ssh_host,
            )

            if source == "published":
                published_executable = self._deploy_published_release_to_server(ssh, result)
            elif source == "remote":
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
                self._sync_local_filepool_to_server(ssh, result)

        if published_executable is not None:
            return published_executable
        return self._compile_release_on_build_vm(result)

    def _deploy_published_release_to_server(
        self,
        ssh: SSHClient,
        result: ResultBuilder,
    ) -> PurePosixPath:
        s = self.settings
        work_root = s.runtime_dir / "published-release"
        work_root.mkdir(parents=True, exist_ok=True)
        remote_archive: str | None = None
        with tempfile.TemporaryDirectory(prefix="dev-", dir=work_root) as temporary:
            temporary_path = Path(temporary)
            release = download_published_dev_release(
                metadata_base_url=s.published_dev_metadata_base_url,
                public_key_path=self._local_repository_root()
                / "Scripts/config/Libertix.CatalogPublicKey.xml",
                work_directory=temporary_path,
                timeout_seconds=max(s.command_timeout_seconds, 180),
            )
            archive = temporary_path / f"Libertix-wpf-{release.tag}.tar.gz"
            with tarfile.open(archive, "w:gz") as tar:
                for path in sorted(release.directory.rglob("*")):
                    tar.add(path, arcname=path.relative_to(release.directory), recursive=False)

            remote_archive = str(PurePosixPath(s.smb_root) / f".{archive.name}")
            ssh.upload_file(archive, remote_archive, step="published_release.upload")
            release_path = f"{s.smb_root}/{s.release_dir_name}"
            install_script = (
                "set -eu; "
                f"dest={shlex.quote(release_path)}; archive={shlex.quote(remote_archive)}; "
                f"root={shlex.quote(s.smb_root)}; "
                'root=$(realpath -m -- "$root"); dest=$(realpath -m -- "$dest"); '
                'case "$dest" in "$root"/*) ;; *) '
                'echo "Destination refusee: $dest" >&2; exit 22;; esac; '
                'rm -rf "$dest"; mkdir -p "$dest"; '
                'tar -xzf "$archive" -C "$dest"; rm -f "$archive"; '
                'test -s "$dest/Libertix.exe"'
            )
            try:
                ssh.run(
                    install_script,
                    step="published_release.publish",
                    timeout=max(s.command_timeout_seconds, 300),
                )
                remote_archive = None
            finally:
                if remote_archive is not None:
                    ssh.run(
                        f"rm -f -- {shlex.quote(remote_archive)}",
                        step="published_release.cleanup_archive",
                        timeout=30,
                        check=False,
                    )

        result.ok(
            "published_release.publish",
            "Latest signed dev WPF release downloaded, verified and published to Samba",
            target=s.main_ssh_host,
            source="published",
            tag=release.tag,
            commit=release.commit,
            executable_sha256=release.sha256,
        )
        return PurePosixPath(f"{s.smb_root}/{s.release_dir_name}/Libertix.exe")

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

        archive_directory = s.runtime_dir / "source-archives"
        archive_directory.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            prefix="libertix-source-",
            suffix=".tar.gz",
            dir=archive_directory,
            delete=False,
        ) as tmp:
            archive = Path(tmp.name)
        try:
            with tarfile.open(archive, "w:gz") as tar:
                for path in self._local_source_files(root):
                    tar.add(path, arcname=path.relative_to(root), recursive=False)

            digest = hashlib.sha256()
            with archive.open("rb") as archive_stream:
                for chunk in iter(lambda: archive_stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            archive_sha256 = digest.hexdigest()

            remote_archive = str(PurePosixPath(s.smb_root) / f".{archive.name}")
            ssh.upload_file(archive, remote_archive, step="server.copy_local_source.upload")
            # The destination is removed only inside the configured Samba root.
            # This avoids accidentally deleting an arbitrary server path.
            install_script = (
                "set -eu; "
                f"dest={shlex.quote(source_path)}; archive={shlex.quote(remote_archive)}; "
                f"root={shlex.quote(s.smb_root)}; "
                'root=$(realpath -m -- "$root"); dest=$(realpath -m -- "$dest"); '
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
            if "remote_archive" in locals():
                try:
                    ssh.run(
                        f"rm -f -- {shlex.quote(remote_archive)}",
                        step="server.copy_local_source.cleanup_remote_archive",
                        timeout=30,
                        check=False,
                    )
                except WorkflowError as exc:
                    logger.warning(
                        "Remote source archive could not be removed",
                        extra={
                            "step": "server.copy_local_source.cleanup_remote_archive",
                            "target": ssh.host,
                        },
                        exc_info=exc,
                    )

    def _sync_local_filepool_to_server(
        self,
        ssh: SSHClient,
        result: ResultBuilder,
    ) -> None:
        s = self.settings
        local_filepool = self._local_repository_root() / "auto_tests" / "app" / "filepool"
        if not local_filepool.is_dir():
            raise WorkflowError(
                "server.filepool_sync",
                "The local development filepool directory is missing",
                details={"path": str(local_filepool)},
            )

        artifacts = {
            path.name: path
            for path in local_filepool.iterdir()
            if path.is_file() and not path.is_symlink()
        }
        runtime_catalog = s.runtime_dir / "filepool" / "catalog.json"
        if runtime_catalog.is_file() and not runtime_catalog.is_symlink():
            artifacts["catalog.json"] = runtime_catalog
        required = {
            "catalog.json",
            "libertix-installer-bios.iso",
            "libertix-installer-uefi.iso",
        }
        missing = sorted(required - artifacts.keys())
        if missing:
            raise WorkflowError(
                "server.filepool_sync",
                "The local development filepool is incomplete",
                details={"missing": missing, "path": str(local_filepool)},
            )

        remote_root = PurePosixPath(s.smb_root) / s.filepool_dir_name
        prepare = (
            "set -eu; "
            f"root={shlex.quote(s.smb_root)}; dest={shlex.quote(str(remote_root))}; "
            'root=$(realpath -m -- "$root"); dest=$(realpath -m -- "$dest"); '
            'case "$dest" in "$root"/*) ;; *) '
            'echo "Filepool destination is outside SMB_ROOT" >&2; exit 22;; esac; '
            'mkdir -p -- "$dest"'
        )
        ssh.run(
            prepare,
            step="server.filepool_prepare",
            timeout=s.command_timeout_seconds,
        )

        copied = 0
        reused = 0
        manifest: dict[str, dict[str, object]] = {}
        for name, local_path in sorted(artifacts.items()):
            digest = hashlib.sha256()
            with local_path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            sha256 = digest.hexdigest()
            size = local_path.stat().st_size
            remote_path = remote_root / name
            remote_digest = ssh.run(
                "if [ -f {path} ]; then sha256sum -- {path} | cut -d' ' -f1; fi".format(
                    path=shlex.quote(str(remote_path))
                ),
                step="server.filepool_hash",
                timeout=max(s.command_timeout_seconds, 300),
                check=False,
            ).stdout.strip()
            if remote_digest == sha256:
                reused += 1
            else:
                temporary_path = remote_root / f".{name}.{uuid.uuid4().hex}.tmp"
                try:
                    ssh.upload_file(
                        local_path,
                        str(temporary_path),
                        step="server.filepool_upload",
                    )
                    publish = (
                        "set -eu; "
                        f"tmp={shlex.quote(str(temporary_path))}; "
                        f"dest={shlex.quote(str(remote_path))}; "
                        f"expected_hash={shlex.quote(sha256)}; "
                        f"expected_size={size}; "
                        'actual_hash=$(sha256sum -- "$tmp" | cut -d" " -f1); '
                        'actual_size=$(stat -c %s -- "$tmp"); '
                        '[ "$actual_hash" = "$expected_hash" ]; '
                        '[ "$actual_size" = "$expected_size" ]; '
                        'mv -f -- "$tmp" "$dest"'
                    )
                    ssh.run(
                        publish,
                        step="server.filepool_publish",
                        timeout=max(s.command_timeout_seconds, 300),
                    )
                    copied += 1
                finally:
                    ssh.run(
                        f"rm -f -- {shlex.quote(str(temporary_path))}",
                        step="server.filepool_cleanup_temporary",
                        timeout=30,
                        check=False,
                    )
            manifest[name] = {"size": size, "sha256": sha256}

        catalog_url = s.filepool_base_url.rstrip("/") + "/catalog.json"
        ssh.run(
            f"curl -fsS --max-time 15 --range 0-0 -- {shlex.quote(catalog_url)} >/dev/null",
            step="server.filepool_http_probe",
            timeout=30,
        )
        result.ok(
            "server.filepool_sync",
            "Local development filepool synchronized and reachable",
            target=s.main_ssh_host,
            remote_path=str(remote_root),
            copied=copied,
            reused=reused,
            files=manifest,
        )

    @staticmethod
    def _local_repository_root() -> Path:
        return LocalSourceTree.repository_root()

    @staticmethod
    def _local_source_files(root: Path) -> tuple[Path, ...]:
        return LocalSourceTree.selected_files(root)

    def _compile_release_on_build_vm(self, result: ResultBuilder) -> PurePosixPath:
        s = self.settings
        config = {
            "share": s.samba_unc,
            "source": str(PureWindowsPath(s.samba_unc) / s.source_dir_name),
            "release": str(PureWindowsPath(s.samba_unc) / s.release_dir_name),
            "source_dir_name": s.source_dir_name,
            "release_dir_name": s.release_dir_name,
            "samba_username": s.samba_username,
            "samba_password": s.samba_password.get_secret_value(),
        }

        with self.ssh(
            s.build_vm_host,
            s.build_vm_user,
            s.build_vm_password.get_secret_value(),
            remote_os="windows",
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
                "PSSCRIPTANALYZER",
                "PESTER",
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
            psscriptanalyzer=values.get("PSSCRIPTANALYZER"),
            pester=values.get("PESTER"),
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
            raise WorkflowError(
                "release.path",
                f"Executable is outside {self.settings.smb_root}",
            ) from exc
        return PureWindowsPath("Z:/") / PureWindowsPath(*relative.parts)

    def _validate_vm(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        result: ResultBuilder,
        *,
        use_default_filepool: bool = False,
    ) -> None:
        local_executable = self.deploy_to_documents(vm, executable)
        result.ok(
            "vm.deploy",
            "Release copied from Samba to the Documents directory",
            target=vm.host,
            vm=vm.name,
            executable=str(local_executable),
        )
        launch = self._launch_interactive(
            vm,
            local_executable,
            result,
            use_default_filepool=use_default_filepool,
        )
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
        if not capture.is_file() or capture.stat().st_size == 0:
            raise WorkflowError(
                "vnc.capture",
                "VNC did not produce a non-empty validation capture",
                details={"vm": vm.name, "target": vm.vnc, "path": str(capture)},
            )
        result.ok(
            "vnc.capture",
            "Libertix process, interactive main window, and non-empty VNC capture confirmed",
            target=vm.vnc,
            vm=vm.name,
            path=str(capture),
            window_handle=launch["window_handle"],
            window_title=launch["window_title"],
            proof_source="uia-visible-window-and-vnc-capture",
        )

    def _validate_vm_isolated(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        on_step: Callable[[StepResult], None] | None = None,
        *,
        use_default_filepool: bool = False,
    ) -> OperationResult:
        result = ResultBuilder("validation", on_step=on_step)
        try:
            self._validate_vm(
                vm,
                executable,
                result,
                use_default_filepool=use_default_filepool,
            )
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
            vm.host,
            vm.username,
            self.settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
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
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        result: ResultBuilder,
        *,
        use_default_filepool: bool = False,
    ) -> dict[str, object]:
        del result
        task_name = f"LibertixValidation_{vm.name}"
        values = self.launch_elevated_process(
            vm,
            executable,
            task_name=task_name,
            step="vm.launch_elevated",
            use_default_filepool=use_default_filepool,
        )
        return {
            "pid": int(values["PID"]),
            "session_id": int(values["SESSION_ID"]),
            "window_handle": int(values["WINDOW_HANDLE"]),
            "window_title": values["WINDOW_TITLE"],
            "window_visible": values["WINDOW_VISIBLE"] == "True",
            "task_name": values.get("TASK_NAME", task_name),
            "launch_method": "scheduled_task_elevated",
            "visual_confirmation": "uia_visible_window_and_vnc_capture",
        }

    def launch_elevated_process(
        self,
        vm: VMConfig,
        executable: PureWindowsPath,
        *,
        task_name: str,
        step: str,
        use_default_filepool: bool = False,
        force_offline_ntfs_resize: bool = False,
        unattended_config: dict[str, object] | None = None,
    ) -> dict[str, str]:
        def has_interactive_window_proof(parsed: dict[str, str]) -> bool:
            handle = parsed.get("WINDOW_HANDLE", "")
            return (
                parsed.get("PID", "").isdigit()
                and parsed.get("SESSION_ID", "").isdigit()
                and handle.isdigit()
                and int(handle) > 0
                and parsed.get("WINDOW_TITLE", "").strip() == "Libertix"
                and parsed.get("WINDOW_VISIBLE", "") == "True"
            )

        with self.ssh(
            vm.host,
            vm.username,
            self.settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
        ) as ssh:
            response = self.run_windows_script(
                ssh,
                script_name="launch_libertix_elevated.ps1",
                config={
                    "executable": str(executable),
                    "task_name": task_name,
                    "filepool_base_url": (
                        None if use_default_filepool else self.settings.filepool_base_url
                    ),
                    "development_static_ipv4": vm.host,
                    "development_static_ipv4_prefix_length": (
                        self.settings.development_static_ipv4_prefix_length
                    ),
                    "development_static_ipv4_gateway": (
                        self.settings.development_static_ipv4_gateway
                    ),
                    "development_dns_servers": list(self.settings.development_dns_servers),
                    "force_offline_ntfs_resize": force_offline_ntfs_resize,
                    "unattended": unattended_config,
                },
                step=step,
                timeout=90,
            )
            values = self.parse_powershell_results(
                response.stdout,
                prefixes=(
                    "PID",
                    "SESSION_ID",
                    "TASK_NAME",
                    "EXECUTABLE",
                    "WINDOW_HANDLE",
                    "WINDOW_TITLE",
                    "WINDOW_VISIBLE",
                    "UNATTENDED_STATUS_PATH",
                    "UNATTENDED_ACKNOWLEDGEMENT_PATH",
                ),
            )
            if not has_interactive_window_proof(values):
                confirmation = self.run_windows_script(
                    ssh,
                    script_name="confirm_libertix_process.ps1",
                    config={"executable": str(executable), "task_name": task_name},
                    step=f"{step}.confirm_process",
                    timeout=60,
                )
                confirmation_values = self.parse_powershell_results(
                    confirmation.stdout,
                    prefixes=(
                        "PID",
                        "SESSION_ID",
                        "TASK_NAME",
                        "EXECUTABLE",
                        "WINDOW_HANDLE",
                        "WINDOW_TITLE",
                        "WINDOW_VISIBLE",
                    ),
                )
                values.update(confirmation_values)
                if not has_interactive_window_proof(values):
                    raise WorkflowError(
                        step,
                        "Elevated Libertix process and interactive window were not confirmed",
                        details={
                            "vm": vm.name,
                            "host": vm.host,
                            "launch_stdout": response.stdout[-4000:],
                            "launch_stderr": response.stderr[-4000:],
                            "confirmation_stdout": confirmation.stdout[-4000:],
                            "confirmation_stderr": confirmation.stderr[-4000:],
                        },
                    )
        if PureWindowsPath(values.get("EXECUTABLE", "")) != executable:
            raise WorkflowError(
                step,
                "The launched process does not match the deployed executable",
                details={"vm": vm.name, "expected": str(executable)},
            )
        return values
