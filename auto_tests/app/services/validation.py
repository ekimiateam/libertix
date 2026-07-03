from __future__ import annotations

import json
import logging
import shlex
import time
import uuid
from collections.abc import Callable, Sequence
from concurrent.futures import ThreadPoolExecutor
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath, PureWindowsPath
from typing import Any

from app.clients.ssh import CommandResult, SSHClient
from app.clients.vision_llm import VisionLLMClient
from app.clients.vnc import VNCClient
from app.config import Settings, VMConfig
from app.errors import WorkflowError
from app.models import OperationResult, StepResult
from app.services.common import ResultBuilder

logger = logging.getLogger(__name__)


class ValidationService:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings
        self.vision_llm = VisionLLMClient(
            settings.llm_api_key.get_secret_value(),
            settings.llm_api_url,
            settings.llm_model,
            settings.llm_timeout_seconds,
            max_attempts=settings.llm_max_attempts,
            retry_base_seconds=settings.llm_retry_base_seconds,
        )
        self.vnc = VNCClient()

    def run(
        self,
        vm_selectors: Sequence[str] | None = None,
        on_step: Callable[[StepResult], None] | None = None,
    ) -> OperationResult:
        result = ResultBuilder("validation", on_step=on_step)
        try:
            selected_vms = self._select_vms(vm_selectors)
            executable = self._prepare_server(result)
            windows_path = self._to_windows_share_path(executable)
            result.ok("release.path", "Chemin de l'exécutable résolu", path=str(windows_path))
            with ThreadPoolExecutor(max_workers=len(selected_vms)) as executor:
                futures = [
                    executor.submit(self._validate_vm_isolated, vm, windows_path, on_step)
                    for vm in selected_vms
                ]
                for future in futures:
                    vm_result = future.result()
                    result.steps.extend(vm_result.steps)
                    if vm_result.status == "problème":
                        return OperationResult(
                            status="problème",
                            operation="validation",
                            message=vm_result.message,
                            steps=result.steps,
                        )
            count = len(selected_vms)
            plural = "s" if count > 1 else ""
            return result.success(f"Validation terminée avec succès sur {count} VM{plural}")
        except WorkflowError as exc:
            return result.failure(exc)
        except Exception as exc:
            logger.exception("Erreur interne inattendue")
            return result.failure(
                WorkflowError(
                    "internal", "Erreur interne inattendue", details={"type": type(exc).__name__}
                )
            )

    def _select_vms(self, selectors: Sequence[str] | None) -> tuple[VMConfig, ...]:
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
                "Sélecteur VM inconnu",
                details={
                    "unknown": unknown,
                    "accepted_examples": [
                        "vm1",
                        "vm2",
                        "vm3",
                        "win10-bios",
                        "win10-uefi",
                        "win11-uefi",
                        "192.168.1.241",
                    ],
                },
            )
        return tuple(selected)

    @staticmethod
    def _normalize_selector(value: str) -> str:
        return "".join(ch for ch in value.lower() if ch.isalnum())

    def _ssh(self, host: str, username: str, password: str) -> SSHClient:
        return SSHClient(
            host,
            username,
            password,
            port=self.settings.ssh_port,
            connect_timeout=self.settings.ssh_timeout_seconds,
        )

    def _run_windows_script(
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
                "Script PowerShell introuvable",
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
    def _parse_powershell_results(stdout: str, *, prefixes: Sequence[str]) -> dict[str, str]:
        """Extract NAME=VALUE lines emitted intentionally by our .ps1 scripts."""

        accepted = tuple(f"{prefix}=" for prefix in prefixes)
        return dict(line.split("=", 1) for line in stdout.splitlines() if line.startswith(accepted))

    def _prepare_server(self, result: ResultBuilder) -> PurePosixPath:
        s = self.settings
        password = s.main_ssh_password.get_secret_value()
        source = f"{s.smb_root}/{s.source_dir_name}"
        with self._ssh(s.main_ssh_host, s.main_ssh_user, password) as ssh:
            ssh.run(
                "set -eu; "
                f"p={shlex.quote(s.smb_root)}; "
                'if [ ! -e "$p" ]; then echo "Chemin absent: $p" >&2; exit 10; fi; '
                'if [ ! -d "$p" ]; then echo "Pas un dossier: $p" >&2; exit 11; fi; '
                'if [ ! -w "$p" ]; then '
                'echo "Dossier non inscriptible: $p" >&2; exit 12; fi',
                step="server.check_smb",
                timeout=s.command_timeout_seconds,
            )
            result.ok(
                "server.check_smb",
                "Le dossier /root/smb existe et est accessible",
                target=s.main_ssh_host,
            )

            ssh.run(
                "set -eu; missing=''; "
                'for tool in git; do command -v "$tool" >/dev/null 2>&1 || '
                "missing=1; done; "
                'if [ -n "$missing" ]; then export DEBIAN_FRONTEND=noninteractive; '
                "apt-get update; apt-get install -y --no-install-recommends git; fi; "
                'for tool in git; do command -v "$tool" >/dev/null; done',
                step="server.ensure_tools",
                timeout=max(s.command_timeout_seconds, 600),
            )
            result.ok(
                "server.ensure_tools",
                "Prérequis git installé ou déjà présent",
                target=s.main_ssh_host,
            )

            clone_script = (
                "set -eu; "
                f"if [ -d {shlex.quote(source + '/.git')} ]; then "
                f"git -C {shlex.quote(source)} remote get-url origin | "
                f"grep -Fx {shlex.quote(s.repository_url)}; "
                f"git -C {shlex.quote(source)} fetch origin {shlex.quote(s.repository_branch)}; "
                f"git -C {shlex.quote(source)} checkout -B {shlex.quote(s.repository_branch)} "
                f"origin/{shlex.quote(s.repository_branch)}; "
                f"elif [ -e {shlex.quote(source)} ]; then exit 21; "
                f"else git clone --branch {shlex.quote(s.repository_branch)} -- "
                f"{shlex.quote(s.repository_url)} {shlex.quote(source)}; fi"
            )
            ssh.run(clone_script, step="server.clone", timeout=s.command_timeout_seconds)
            result.ok(
                "server.clone",
                "Clone Libertix présent, origine et branche vérifiées",
                target=s.main_ssh_host,
                branch=s.repository_branch,
            )

        return self._compile_release_on_build_vm(result)

    def _compile_release_on_build_vm(self, result: ResultBuilder) -> PurePosixPath:
        s = self.settings
        config = {
            "share": s.samba_unc,
            "source": str(PureWindowsPath(s.samba_unc) / s.source_dir_name),
            "release": str(PureWindowsPath(s.samba_unc) / s.release_dir_name),
            "samba_username": s.samba_username,
            "samba_password": s.samba_password.get_secret_value(),
        }

        with self._ssh(
            s.build_vm_host,
            s.build_vm_user,
            s.build_vm_password.get_secret_value(),
        ) as ssh:
            response = self._run_windows_script(
                ssh,
                script_name="build_libertix.ps1",
                config=config,
                step="build_vm.compile",
                timeout=max(s.command_timeout_seconds, 900),
            )

        values = self._parse_powershell_results(
            response.stdout, prefixes=("MSBUILD", "TEMP_BUILD_DIR", "FINAL_EXE")
        )
        final_exe = values.get("FINAL_EXE")
        if not final_exe:
            raise WorkflowError(
                "build_vm.compile",
                "La VM de compilation n'a pas confirmé le chemin final",
                details={"target": s.build_vm_host},
            )
        result.ok(
            "build_vm.compile",
            "Libertix compilé sur la VM Windows et copié vers Samba",
            target=s.build_vm_host,
            msbuild=values.get("MSBUILD"),
            temp_build_dir=values.get("TEMP_BUILD_DIR"),
            cleanup="dossier temporaire, script et config supprimés en fin de commande",
        )
        return PurePosixPath(f"{s.smb_root}/{s.release_dir_name}/Libertix.exe")

    def _to_windows_share_path(self, path: PurePosixPath) -> PureWindowsPath:
        root = PurePosixPath(self.settings.smb_root)
        try:
            relative = path.relative_to(root)
        except ValueError as exc:
            raise WorkflowError("release.path", "Exécutable situé hors de /root/smb") from exc
        return PureWindowsPath("Z:/") / PureWindowsPath(*relative.parts)

    def _validate_vm(
        self, vm: VMConfig, executable: PureWindowsPath, result: ResultBuilder
    ) -> None:
        local_executable = self._deploy_to_documents(vm, executable)
        result.ok(
            "vm.deploy",
            "Release copiée depuis Samba vers le dossier Documents",
            target=vm.host,
            vm=vm.name,
            executable=str(local_executable),
        )
        launch = self._launch_interactive(vm, local_executable, result)
        result.ok(
            "vm.launch",
            "Libertix lancé dans la session graphique et processus confirmé",
            target=vm.host,
            vm=vm.name,
            **launch,
        )
        logger.info("Attente avant capture", extra={"step": "vm.wait", "target": vm.host})
        time.sleep(self.settings.launch_wait_seconds)
        result.ok(
            "vm.wait",
            "Attente post-lancement terminée",
            target=vm.host,
            seconds=self.settings.launch_wait_seconds,
        )

        stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
        capture = Path(self.settings.capture_dir) / f"{vm.name}-{stamp}.png"
        self.vnc.capture(vm.vnc, capture)
        result.ok("vnc.capture", "Capture VNC enregistrée", target=vm.vnc, path=str(capture))

        verdict = self.vision_llm.analyze(capture, vm.name, vm.os)
        context = verdict.model_dump()
        if not verdict.valid:
            raise WorkflowError(
                "llm.verdict",
                "La validation visuelle signale un problème",
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
            return result.success(f"Validation terminée avec succès sur {vm.name}")
        except WorkflowError as exc:
            return result.failure(exc)

    def _deploy_to_documents(self, vm: VMConfig, executable: PureWindowsPath) -> PureWindowsPath:
        share_release = PureWindowsPath("Z:/") / self.settings.release_dir_name
        try:
            relative_executable = executable.relative_to(share_release)
        except ValueError as exc:
            raise WorkflowError(
                "vm.deploy",
                "L'exécutable n'est pas situé dans le dossier de release Samba",
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
        with self._ssh(
            vm.host, vm.username, self.settings.windows_ssh_password.get_secret_value()
        ) as ssh:
            response = self._run_windows_script(
                ssh,
                script_name="deploy_libertix.ps1",
                config=config,
                step="vm.deploy",
                timeout=max(self.settings.command_timeout_seconds, 300),
            )
        values = self._parse_powershell_results(response.stdout, prefixes=("LOCAL_EXE",))
        if not values.get("LOCAL_EXE"):
            raise WorkflowError(
                "vm.deploy",
                "Le chemin local de Libertix n'a pas été confirmé",
                details={"vm": vm.name, "host": vm.host},
            )
        return PureWindowsPath(values["LOCAL_EXE"])

    def _launch_interactive(
        self, vm: VMConfig, executable: PureWindowsPath, result: ResultBuilder
    ) -> dict[str, object]:
        prepare_config = {
            "mode": "prepare",
            "executable": str(executable),
            "username": vm.username,
        }
        with self._ssh(
            vm.host, vm.username, self.settings.windows_ssh_password.get_secret_value()
        ) as ssh:
            prepared = self._run_windows_script(
                ssh,
                script_name="launch_libertix.ps1",
                config=prepare_config,
                step="vm.prepare_launch",
                timeout=60,
            )
        prepared_values = self._parse_powershell_results(prepared.stdout, prefixes=("SESSION_ID",))
        session_id = prepared_values.get("SESSION_ID")
        if not session_id or not session_id.isdigit():
            raise WorkflowError(
                "vm.prepare_launch",
                "Session graphique non confirmée",
                details={"vm": vm.name, "host": vm.host, "stdout": prepared.stdout[-4000:]},
            )
        result.ok(
            "vm.prepare_launch",
            "Raccourci de lancement Libertix préparé dans la session graphique",
            target=vm.host,
            vm=vm.name,
            session_id=int(session_id),
            launch_shortcut="Desktop\\Libertix.lnk",
            cleanup="raccourci et clé RUNASINVOKER supprimés après vérification",
        )

        time.sleep(2)
        self.vnc.launch_desktop_shortcut(vm.vnc, width=vm.screen_width, height=vm.screen_height)
        result.ok(
            "vnc.launch",
            "Raccourci Libertix activé dans la session graphique via VNC",
            target=vm.vnc,
            vm=vm.name,
        )

        verify_config = {
            "mode": "verify",
            "executable": str(executable),
            "session_id": int(session_id),
        }
        with self._ssh(
            vm.host, vm.username, self.settings.windows_ssh_password.get_secret_value()
        ) as ssh:
            response = self._run_windows_script(
                ssh,
                script_name="launch_libertix.ps1",
                config=verify_config,
                step="vm.launch",
                timeout=60,
            )
        values = self._parse_powershell_results(
            response.stdout, prefixes=("PID", "SESSION_ID", "WINDOW_HANDLE")
        )
        required = ("PID", "SESSION_ID", "WINDOW_HANDLE")
        if not all(values.get(key, "").isdigit() for key in required):
            raise WorkflowError(
                "vm.launch",
                "PID ou session interactive Libertix non confirmé",
                details={"vm": vm.name, "host": vm.host},
            )
        return {
            "pid": int(values["PID"]),
            "session_id": int(values["SESSION_ID"]),
            "window_handle": int(values["WINDOW_HANDLE"]),
            "launch_method": "desktop_shortcut_vnc",
            "visual_confirmation": "capture_vnc_et_llm",
        }
