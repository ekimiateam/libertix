from __future__ import annotations

import hashlib
import json
import re
import shlex
import stat
import time
import uuid
from collections.abc import Callable, Sequence
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath

import paramiko

from app.clients.ssh import SSHClient
from app.config import Settings, VMConfig
from app.errors import WorkflowError
from app.services.automation_types import AutomationOptions

WINDOWS_LOG_ROOTS = (
    "/LibertixInstallLogs",
    "/LibertixInstallRecovery",
    "/LibertixTools",
    "/ProgramData/Libertix/UefiRecovery",
    "/ProgramData/Libertix/WindowsShare",
    "/ProgramData/Libertix/BootGuardian",
    "/ProgramData/Libertix/Automation",
)
LINUX_LOG_ROOTS = (
    "/var/log/libertix",
    "/var/log/apt",
    "/var/log/unattended-upgrades",
    "/var/lib/libertix",
    "/etc/libertix",
    "/run/libertix",
    "/mnt/windows/LibertixInstallLogs",
    "/run/libertix-first-boot-windows/LibertixInstallLogs",
)
PUBLIC_STATE_FILES = {
    "installation-plan.json",
    "installation-state.json",
    "installed-linux-boot.json",
    "post-install-verification.json",
    "uninstall-verification.json",
    "first-boot-verification.json",
    "first-boot-service-state.json",
    "storage-before-installation.json",
    "source-encryption-original.json",
    "uefi-transaction.json",
    "recovery-operations.json",
    "state.json",
    "mount-status.json",
    "windows-filesystem-repair.json",
    "firmware-boot-bypass.json",
    "pending.env",
    "install-success.env",
    "live-started.env",
    "live-failed.env",
    "stage",
    "failure",
    "result.env",
    "context-load-error",
    "tty1-screen",
    "tty1-screen.last",
}


def is_diagnostic_file(name: str) -> bool:
    lowered = name.lower()
    # One-use unattended and preference files contain credentials, unlike public states.
    if any(word in lowered for word in ("password", "secret", "credential", "private")):
        return False
    return (
        lowered in PUBLIC_STATE_FILES
        or lowered.endswith((".status.json", ".result.json"))
        or bool(re.fullmatch(r"[a-z0-9_.-]+\.(?:log(?:\.[a-z0-9_-]+)*|txt)", lowered))
    )


def download_diagnostics(
    sftp: paramiko.SFTPClient, root: str, destination: Path, records: list[dict]
) -> None:
    try:
        attributes = sftp.lstat(root)
        if not stat.S_ISDIR(attributes.st_mode or 0):
            records.append({"remote_path": root, "status": "not-a-directory"})
            return
        entries = sftp.listdir_attr(root)
    except FileNotFoundError:
        records.append({"remote_path": root, "status": "absent"})
        return
    except (OSError, EOFError, paramiko.SSHException) as exc:
        records.append({"remote_path": root, "status": "error", "error": str(exc)})
        return
    for entry in entries:
        name = entry.filename
        if name in {".", ".."} or "/" in name or "\\" in name:
            continue
        remote_path = str(PurePosixPath(root) / name)
        local_path = destination / name
        if stat.S_ISDIR(entry.st_mode or 0):
            download_diagnostics(sftp, remote_path, local_path, records)
        elif stat.S_ISREG(entry.st_mode or 0) and is_diagnostic_file(name):
            record = {"remote_path": remote_path, "local_path": str(local_path)}
            records.append(record)
            try:
                local_path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                digest = hashlib.sha256()
                size = 0
                with sftp.open(remote_path, "rb") as incoming, local_path.open("xb") as outgoing:
                    local_path.chmod(0o600)
                    initial_size = incoming.stat().st_size
                    # Bound a still-growing log to its size when opened, not to an arbitrary cap.
                    while size < initial_size:
                        chunk = incoming.read(min(65536, initial_size - size))
                        if not chunk:
                            raise OSError("The remote log was truncated during collection")
                        outgoing.write(chunk)
                        digest.update(chunk)
                        size += len(chunk)
                    final_size = incoming.stat().st_size
                record.update(
                    status="copied" if initial_size == final_size else "changed-during-copy",
                    bytes=size,
                    remote_bytes_after=final_size,
                    sha256=digest.hexdigest(),
                )
            except (OSError, EOFError, paramiko.SSHException) as exc:
                record.update(status="error", error=str(exc))
        else:
            records.append({"remote_path": remote_path, "status": "excluded"})


def collect_failure_diagnostics(
    settings: Settings,
    vm: VMConfig,
    options: AutomationOptions,
    capture_dir: Path,
    errors: Sequence[dict],
    capture: Callable[[Path], None],
) -> Path:
    failed_at = datetime.now(UTC).isoformat()
    stamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%S%fZ")
    step = re.sub(r"[^A-Za-z0-9_.-]", "-", str(errors[-1]["step"]))
    bundle = capture_dir.parent / "diagnostics" / f"{stamp}-{vm.name}-VM{vm.vmid}-{step}"
    bundle.mkdir(mode=0o700, parents=True)
    attempt_dir = capture_dir.parent
    attempt_match = re.fullmatch(r"attempt-(\d+)(?:-run-(\d+))?", attempt_dir.name)
    scenario_dir = attempt_dir
    if attempt_match:
        scenario_dir = attempt_dir.parent
        if attempt_match.group(2):
            scenario_dir = scenario_dir.parent
    manifest = {
        "failed_at": failed_at,
        "vm": vm.name,
        "vmid": vm.vmid,
        "host": vm.host,
        "scenario": scenario_dir.name,
        "attempt": int(attempt_match.group(1)) if attempt_match else 1,
        "distribution": options.distribution.id,
        "first_boot": options.first_boot,
        "errors": list(errors),
        "files": [],
        "connection_errors": [],
        "status": "waiting",
    }
    manifest_path = bundle / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    manifest_path.chmod(0o600)
    try:
        capture(bundle / "screen.png")
        manifest["screenshot"] = "screen.png"
    except Exception as exc:
        manifest["screenshot_error"] = f"{type(exc).__name__}: {exc}"
    time.sleep(15)
    if "screenshot" not in manifest:
        try:
            capture(bundle / "screen.png")
            manifest["screenshot"] = "screen.png"
        except Exception as exc:
            manifest["screenshot_retry_error"] = f"{type(exc).__name__}: {exc}"
    manifest["collection_started_at"] = datetime.now(UTC).isoformat()
    for remote_os, username, password, known_hosts, roots in (
        (
            "windows",
            vm.username,
            settings.windows_ssh_password.get_secret_value(),
            settings.ssh_known_hosts,
            WINDOWS_LOG_ROOTS,
        ),
        (
            "linux",
            options.linux_username,
            options.linux_password,
            capture_dir / f"{vm.name}-linux-known-hosts",
            LINUX_LOG_ROOTS,
        ),
    ):
        try:
            with SSHClient(
                vm.host,
                username,
                password,
                known_hosts_path=known_hosts,
                port=settings.ssh_port,
                connect_timeout=settings.ssh_timeout_seconds,
                trust_on_first_use=remote_os == "linux",
                remote_os=remote_os,
            ) as ssh:
                manifest["remote_os"] = remote_os
                try:
                    with ssh._text_sftp(300) as sftp:  # noqa: SLF001
                        for root in roots:
                            destination = bundle / remote_os / root.lstrip("/")
                            download_diagnostics(sftp, root, destination, manifest["files"])
                except (WorkflowError, OSError, EOFError, paramiko.SSHException) as exc:
                    # SFTP and command execution use separate channels; try both for evidence.
                    manifest["files"].append(
                        {"status": "error", "phase": "sftp", **diagnostic_error(exc)}
                    )
                collect_system_context(ssh, remote_os, bundle, manifest, password)
            break
        except (WorkflowError, OSError, EOFError, paramiko.SSHException) as exc:
            manifest["connection_errors"].append({"remote_os": remote_os, **diagnostic_error(exc)})
    manifest["collection_finished_at"] = datetime.now(UTC).isoformat()
    before_deployment = (
        manifest.get("remote_os") == "windows"
        and all(
            error["step"] in {"automation.prepare_vm", "automation.local_filepool.download"}
            for error in errors
        )
        and bool(manifest["files"])
        and all(item["status"] == "absent" for item in manifest["files"])
    )
    if before_deployment:
        manifest["product_logs_status"] = "not-created-before-deployment"
    manifest["status"] = (
        "collected"
        if (before_deployment or any(item["status"] == "copied" for item in manifest["files"]))
        and manifest.get("system_context", {}).get("status") == "collected"
        and "screenshot" in manifest
        and not any(
            item["status"] in {"error", "changed-during-copy", "not-a-directory"}
            for item in manifest["files"]
        )
        else "incomplete"
    )
    manifest_path.write_text(json.dumps(manifest, indent=2, ensure_ascii=False), encoding="utf-8")
    return manifest_path


def diagnostic_error(exc: Exception) -> dict[str, object]:
    details: dict[str, object] = {"error": str(exc), "exception_type": type(exc).__name__}
    if isinstance(exc, WorkflowError):
        details["failure"] = exc.as_dict()
    return details


def collect_system_context(
    ssh: SSHClient, remote_os: str, bundle: Path, manifest: dict, password: str
) -> None:
    scripts = Path(__file__).resolve().parents[1] / "scripts"
    context = manifest["system_context"] = {"status": "incomplete", "phase": "prepare"}
    started = time.monotonic()
    remote_script = None
    try:
        if remote_os == "windows":
            source = (scripts / "collect_windows_diagnostics.ps1").read_text(encoding="utf-8")
            remote_script = f"C:/Windows/Temp/libertix-diagnostics-{uuid.uuid4().hex}.ps1"
            context["phase"] = "upload_script"
            ssh.upload_text(
                remote_script,
                source,
                step="automation.diagnostics.upload_script",
                replay_safe=True,
            )
            # The timeout wrapper still uses cmd.exe; encoding the whole script
            # as an argument exceeds its limit even when the outer wrapper is compressed.
            command = (
                "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass "
                f'-File "{remote_script}"'
            )
        else:
            source = (scripts / "collect_linux_diagnostics.sh").read_text(encoding="utf-8")
            command = "sh -c " + shlex.quote(source)
        context["phase"] = "execute"
        result = ssh.run(
            command,
            step="automation.diagnostics.context",
            timeout=240,
            check=False,
            replay_safe=True,
        )
        context["phase"] = "save_output"
        report = bundle / remote_os / "system-context.txt"
        report.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        with report.open("x", encoding="utf-8") as output:
            report.chmod(0o600)
            output.write(result.stdout + "\nSTDERR:\n" + result.stderr)
        context.update(
            status="collected"
            if result.exit_code == 0
            and (
                remote_os != "windows"
                or "LIBERTIX_DIAGNOSTICS_COMPLETED" in result.stdout.splitlines()
            )
            and not any(
                value.startswith("[earlier remote output truncated]")
                for value in (result.stdout, result.stderr)
            )
            else "incomplete",
            exit_code=result.exit_code,
            path=str(report),
            phase="finished",
        )
    except Exception as exc:
        context.update(diagnostic_error(exc))
    finally:
        context["elapsed_seconds"] = round(time.monotonic() - started, 3)
        if remote_script is not None:
            try:
                ssh.run(
                    "powershell.exe -NoProfile -NonInteractive -Command "
                    f"\"Remove-Item -LiteralPath '{remote_script}' -Force -ErrorAction Stop\"",
                    step="automation.diagnostics.cleanup_script",
                    timeout=30,
                    replay_safe=True,
                )
            except Exception as exc:
                context["cleanup_error"] = f"{type(exc).__name__}: {exc}"
                context["cleanup_failure"] = diagnostic_error(exc)
    if remote_os != "linux":
        return
    # Read the root-owned boot log without changing its ownership or access policy.
    for record in manifest["files"]:
        if (
            record.get("remote_path") != "/var/log/libertix/boot-maintenance.log"
            or record["status"] != "error"
        ):
            continue
        try:
            result = ssh.run(
                "sudo -S -p '' -- cat -- /var/log/libertix/boot-maintenance.log",
                step="automation.diagnostics.boot_log",
                timeout=60,
                check=True,
                sensitive=True,
                stdin_data=password + "\n",
                replay_safe=True,
            )
            destination = Path(record["local_path"]).with_name("boot-maintenance.privileged.log")
            with destination.open("x", encoding="utf-8") as output:
                destination.chmod(0o600)
                output.write(result.stdout)
            if result.stdout.startswith("[earlier remote output truncated]"):
                raise OSError("The privileged boot log exceeded the SSH output limit")
            record.update(
                status="copied",
                local_path=str(destination),
                bytes=destination.stat().st_size,
                sha256=hashlib.sha256(destination.read_bytes()).hexdigest(),
            )
            record.pop("error", None)
        except Exception as exc:
            record["privileged_read_error"] = f"{type(exc).__name__}: {exc}"
