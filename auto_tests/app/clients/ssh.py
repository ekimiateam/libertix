from __future__ import annotations

import base64
import hashlib
import logging
import math
import shlex
import time
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

import paramiko

from app.errors import WorkflowError

logger = logging.getLogger(__name__)

SUPPORTED_HOST_KEY_TYPES = {
    "ssh-ed25519",
    "ecdsa-sha2-nistp256",
    "ecdsa-sha2-nistp384",
    "ecdsa-sha2-nistp521",
    "ssh-rsa",
}
MAX_COMMAND_OUTPUT_BYTES = 8 * 1024 * 1024
SSH_CONNECT_ATTEMPTS = 3
SSH_CONNECT_RETRY_SECONDS = 2
POWERSHELL_CLIXML_MARKER = "#< CLIXML"


class PersistAuthenticatedHostKeyPolicy(paramiko.MissingHostKeyPolicy):
    """Persist a first-seen key only after authentication succeeds."""

    def __init__(self, known_hosts_path: Path) -> None:
        self.known_hosts_path = known_hosts_path
        self._candidate: tuple[str, paramiko.PKey] | None = None

    def missing_host_key(
        self,
        client: paramiko.SSHClient,
        hostname: str,
        key: paramiko.PKey,
    ) -> None:
        key_type = key.get_name()
        if key_type not in SUPPORTED_HOST_KEY_TYPES:
            raise paramiko.SSHException(f"Unsupported SSH host key type: {key_type}")

        self._candidate = (hostname, key)

    def persist_authenticated_key(self, client: paramiko.SSHClient) -> None:
        if self._candidate is None:
            return
        hostname, key = self._candidate
        self.known_hosts_path.parent.mkdir(parents=True, exist_ok=True)
        client.get_host_keys().add(hostname, key.get_name(), key)
        client.save_host_keys(str(self.known_hosts_path))
        self.known_hosts_path.chmod(0o600)


@dataclass(frozen=True)
class CommandResult:
    stdout: str
    stderr: str
    exit_code: int


class SSHClient:
    def __init__(
        self,
        host: str,
        username: str,
        password: str,
        *,
        known_hosts_path: str | Path,
        port: int = 22,
        connect_timeout: float = 15,
        trust_on_first_use: bool = False,
        remote_os: str = "linux",
    ) -> None:
        self.host = host
        self.username = username
        self.password = password
        self.known_hosts_path = Path(known_hosts_path)
        self.port = port
        self.connect_timeout = connect_timeout
        self.trust_on_first_use = trust_on_first_use
        if remote_os not in {"linux", "windows"}:
            raise ValueError("remote_os must be 'linux' or 'windows'")
        self.remote_os = remote_os
        self._client: paramiko.SSHClient | None = None
        self.server_key_sha256: str | None = None

    def __enter__(self) -> SSHClient:
        logger.info("SSH connection attempt", extra={"step": "ssh.connect", "target": self.host})
        last_error: Exception | None = None
        attempts_made = 0
        for attempt in range(1, SSH_CONNECT_ATTEMPTS + 1):
            attempts_made = attempt
            client = paramiko.SSHClient()
            authenticated_key_policy: PersistAuthenticatedHostKeyPolicy | None = None
            try:
                # Automation controls disks and boot state, so a first-seen host key
                # must never be trusted implicitly. The operator owns this file and
                # must update it deliberately when a VM or server key changes.
                if not self.trust_on_first_use:
                    client.load_host_keys(str(self.known_hosts_path))
                    client.set_missing_host_key_policy(paramiko.RejectPolicy())
                else:
                    # A reinstall creates a new Linux host key. Record the first
                    # authenticated key in this run's isolated workspace. The
                    # other OS can answer briefly on the same IP during a reboot,
                    # so persisting before authentication would pin the wrong OS.
                    if self.known_hosts_path.is_file():
                        client.load_host_keys(str(self.known_hosts_path))
                    authenticated_key_policy = PersistAuthenticatedHostKeyPolicy(
                        self.known_hosts_path
                    )
                    client.set_missing_host_key_policy(authenticated_key_policy)
                client.connect(
                    self.host,
                    port=self.port,
                    username=self.username,
                    password=self.password,
                    timeout=self.connect_timeout,
                    banner_timeout=self.connect_timeout,
                    auth_timeout=self.connect_timeout,
                    look_for_keys=False,
                    allow_agent=False,
                )
                if authenticated_key_policy is not None:
                    authenticated_key_policy.persist_authenticated_key(client)
                transport = client.get_transport()
                if transport is not None:
                    self.server_key_sha256 = hashlib.sha256(
                        transport.get_remote_server_key().asbytes()
                    ).hexdigest()
                self._client = client
                logger.info(
                    "SSH connection established",
                    extra={"step": "ssh.connect", "target": self.host},
                )
                return self
            except paramiko.BadHostKeyException as exc:
                client.close()
                last_error = exc
                break
            except (EOFError, TimeoutError, paramiko.SSHException, OSError) as exc:
                client.close()
                last_error = exc
                if attempt < SSH_CONNECT_ATTEMPTS:
                    logger.warning(
                        "SSH connection attempt %s/%s failed; retrying",
                        attempt,
                        SSH_CONNECT_ATTEMPTS,
                        extra={"step": "ssh.connect_retry", "target": self.host},
                    )
                    time.sleep(SSH_CONNECT_RETRY_SECONDS)

        assert last_error is not None
        raise WorkflowError(
            "ssh.connect",
            "SSH connection failed",
            details={
                "host": self.host,
                "attempts": attempts_made,
                "exception_type": type(last_error).__name__,
                "error": str(last_error),
            },
        ) from last_error

    def __exit__(self, *_args: object) -> None:
        if self._client:
            self._client.close()
            logger.info("SSH connection closed", extra={"step": "ssh.close", "target": self.host})

    def run(
        self,
        command: str,
        *,
        step: str,
        timeout: float,
        check: bool = True,
        sensitive: bool = False,
        stdin_data: str | None = None,
    ) -> CommandResult:
        if not self._client:
            raise WorkflowError(step, "SSH client is not connected", details={"host": self.host})
        logger.info("Remote command started", extra={"step": step, "target": self.host})
        remote_command = self._remote_timeout_command(command, timeout)
        transport_timeout = timeout + 30
        try:
            stdin, stdout, stderr = self._client.exec_command(
                remote_command, timeout=transport_timeout
            )
            if stdin_data is not None:
                stdin.write(stdin_data)
                stdin.flush()
                stdin.channel.shutdown_write()
            channel = stdout.channel
            deadline = time.monotonic() + transport_timeout
            out_buffer = bytearray()
            err_buffer = bytearray()
            out_truncated = False
            err_truncated = False
            while True:
                while channel.recv_ready():
                    out_truncated |= self._append_bounded(out_buffer, channel.recv(65536))
                while channel.recv_stderr_ready():
                    err_truncated |= self._append_bounded(err_buffer, channel.recv_stderr(65536))
                if (
                    channel.exit_status_ready()
                    and not channel.recv_ready()
                    and not channel.recv_stderr_ready()
                ):
                    break
                if time.monotonic() >= deadline:
                    channel.close()
                    raise TimeoutError(f"SSH command timed out after {timeout} seconds")
                time.sleep(0.02)
            exit_code = channel.recv_exit_status()
            out = self._decode_bounded(out_buffer, out_truncated)
            err = self._decode_bounded(err_buffer, err_truncated)
        except (EOFError, TimeoutError, paramiko.SSHException, OSError) as exc:
            raise WorkflowError(
                step,
                "Remote command execution failed",
                details={
                    "host": self.host,
                    "command": "[SENSITIVE COMMAND REDACTED]" if sensitive else command,
                    "exception_type": type(exc).__name__,
                    "error": str(exc),
                },
            ) from exc
        logger.info(
            "Remote command completed (code=%s)",
            exit_code,
            extra={"step": step, "target": self.host},
        )
        if check and exit_code != 0:
            raise WorkflowError(
                step,
                "Remote command failed",
                details={
                    "host": self.host,
                    "command": "[SENSITIVE COMMAND REDACTED]" if sensitive else command,
                    "exit_code": exit_code,
                    "stdout": out[-4000:],
                    "stderr": err[-4000:],
                },
            )
        return CommandResult(out, err, exit_code)

    @staticmethod
    def _append_bounded(buffer: bytearray, chunk: bytes) -> bool:
        buffer.extend(chunk)
        if len(buffer) <= MAX_COMMAND_OUTPUT_BYTES:
            return False
        del buffer[: len(buffer) - MAX_COMMAND_OUTPUT_BYTES]
        return True

    @staticmethod
    def _decode_bounded(buffer: bytearray, truncated: bool) -> str:
        text = bytes(buffer).decode("utf-8", errors="replace").strip()
        text = SSHClient._strip_progress_clixml(text)
        if truncated:
            return "[earlier remote output truncated]\n" + text
        return text

    @staticmethod
    def _strip_progress_clixml(text: str) -> str:
        marker_index = text.find(POWERSHELL_CLIXML_MARKER)
        if marker_index < 0:
            return text

        xml_text = text[marker_index + len(POWERSHELL_CLIXML_MARKER) :].strip()
        try:
            root = ET.fromstring(xml_text)
        except ET.ParseError:
            return text

        records = list(root)
        if not records or any(record.attrib.get("S") != "progress" for record in records):
            return text
        return text[:marker_index].rstrip()

    def _remote_timeout_command(self, command: str, timeout: float) -> str:
        timeout_seconds = max(1, math.ceil(timeout))
        if self.remote_os == "linux":
            return (
                f"timeout --signal=TERM --kill-after=10s {timeout_seconds}s "
                f"sh -c {shlex.quote(command)}"
            )

        payload = base64.b64encode(command.encode("utf-8")).decode("ascii")
        script = f"""
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$utf8NoBom = New-Object Text.UTF8Encoding($false)
[Console]::InputEncoding = $utf8NoBom
[Console]::OutputEncoding = $utf8NoBom
$OutputEncoding = $utf8NoBom
$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{payload}'))
$root = Join-Path $env:TEMP ('libertix-ssh-' + [Guid]::NewGuid().ToString('N'))
$commandPath = $root + '.cmd'
$stdoutPath = $root + '.out'
$stderrPath = $root + '.err'
$statusPath = $root + '.status'
$exitCode = 1
try {{
    $commandText = (
        "@echo off`r`n" +
        "chcp 65001 >nul`r`n" +
        $payload +
        "`r`necho %ERRORLEVEL% > `"$statusPath`"`r`n"
    )
    [IO.File]::WriteAllText($commandPath, $commandText, [Text.Encoding]::Default)
    $startArguments = @{{
        FilePath = $env:ComSpec
        ArgumentList = @('/d', '/s', '/c', ('"' + $commandPath + '"'))
        PassThru = $true
        WindowStyle = 'Hidden'
        RedirectStandardOutput = $stdoutPath
        RedirectStandardError = $stderrPath
    }}
    $process = Start-Process @startArguments
    if (-not $process.WaitForExit({timeout_seconds * 1000})) {{
        & (Join-Path $env:SystemRoot 'System32\taskkill.exe') /PID $process.Id /T /F 2>&1 | Out-Null
        $taskkillExitCode = $LASTEXITCODE
        $process.WaitForExit(10000) | Out-Null
        if ($taskkillExitCode -ne 0 -or -not $process.HasExited) {{
            $exitCode = 125
        }} else {{
            $exitCode = 124
        }}
    }} else {{
        $reportedExitCode = 0
        $statusText = if (Test-Path -LiteralPath $statusPath) {{
            (Get-Content -LiteralPath $statusPath -Raw).Trim()
        }} else {{
            ''
        }}
        if (-not [int]::TryParse($statusText, [ref]$reportedExitCode)) {{
            $exitCode = 126
        }} else {{
            $exitCode = $reportedExitCode
        }}
    }}
    if (Test-Path -LiteralPath $stdoutPath) {{
        [Console]::Out.Write([IO.File]::ReadAllText($stdoutPath, $utf8NoBom))
    }}
    if (Test-Path -LiteralPath $stderrPath) {{
        [Console]::Error.Write([IO.File]::ReadAllText($stderrPath, $utf8NoBom))
    }}
}} finally {{
    $temporaryPaths = @($commandPath, $stdoutPath, $stderrPath, $statusPath)
    Remove-Item -LiteralPath $temporaryPaths -Force -ErrorAction SilentlyContinue
}}
exit $exitCode
""".strip()
        encoded = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        return f"powershell.exe -NoProfile -NonInteractive -EncodedCommand {encoded}"

    def upload_text(self, remote_path: str, content: str, *, step: str) -> None:
        if not self._client:
            raise WorkflowError(step, "SSH client is not connected", details={"host": self.host})
        logger.info("SSH text upload started", extra={"step": step, "target": self.host})
        try:
            with self._client.open_sftp() as sftp, sftp.open(remote_path, "wb") as remote:
                # PowerShell 5 requires a BOM for non-ASCII UTF-8 scripts. A
                # source file may already contain U+FEFF, so normalize it
                # before encoding to guarantee exactly one leading BOM.
                remote.write(content.removeprefix("\ufeff").encode("utf-8-sig"))
        except (TimeoutError, paramiko.SSHException, OSError) as exc:
            raise WorkflowError(
                step,
                "SSH text upload failed",
                details={
                    "host": self.host,
                    "remote_path": remote_path,
                    "exception_type": type(exc).__name__,
                    "error": str(exc),
                },
            ) from exc
        logger.info("SSH text upload completed", extra={"step": step, "target": self.host})

    def upload_file(self, local_path: str | Path, remote_path: str, *, step: str) -> None:
        if not self._client:
            raise WorkflowError(step, "SSH client is not connected", details={"host": self.host})
        local = Path(local_path)
        logger.info("SSH file upload started", extra={"step": step, "target": self.host})
        try:
            with self._client.open_sftp() as sftp:
                sftp.put(str(local), remote_path)
        except (TimeoutError, paramiko.SSHException, OSError) as exc:
            raise WorkflowError(
                step,
                "SSH file upload failed",
                details={
                    "host": self.host,
                    "local_path": str(local),
                    "remote_path": remote_path,
                    "exception_type": type(exc).__name__,
                    "error": str(exc),
                },
            ) from exc
        logger.info("SSH file upload completed", extra={"step": step, "target": self.host})
