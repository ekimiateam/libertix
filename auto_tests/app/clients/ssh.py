from __future__ import annotations

import hashlib
import logging
import time
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
    ) -> None:
        self.host = host
        self.username = username
        self.password = password
        self.known_hosts_path = Path(known_hosts_path)
        self.port = port
        self.connect_timeout = connect_timeout
        self.trust_on_first_use = trust_on_first_use
        self._client: paramiko.SSHClient | None = None
        self.server_key_sha256: str | None = None

    def __enter__(self) -> SSHClient:
        logger.info("SSH connection attempt", extra={"step": "ssh.connect", "target": self.host})
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
                authenticated_key_policy = PersistAuthenticatedHostKeyPolicy(self.known_hosts_path)
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
        except (EOFError, TimeoutError, paramiko.SSHException, OSError) as exc:
            client.close()
            raise WorkflowError(
                "ssh.connect",
                "SSH connection failed",
                details={
                    "host": self.host,
                    "exception_type": type(exc).__name__,
                    "error": str(exc),
                },
            ) from exc
        self._client = client
        logger.info(
            "SSH connection established", extra={"step": "ssh.connect", "target": self.host}
        )
        return self

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
        try:
            stdin, stdout, stderr = self._client.exec_command(command, timeout=timeout)
            if stdin_data is not None:
                stdin.write(stdin_data)
                stdin.flush()
                stdin.channel.shutdown_write()
            channel = stdout.channel
            deadline = time.monotonic() + timeout
            out_chunks: list[bytes] = []
            err_chunks: list[bytes] = []
            while True:
                while channel.recv_ready():
                    out_chunks.append(channel.recv(65536))
                while channel.recv_stderr_ready():
                    err_chunks.append(channel.recv_stderr(65536))
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
            out = b"".join(out_chunks).decode("utf-8", errors="replace").strip()
            err = b"".join(err_chunks).decode("utf-8", errors="replace").strip()
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

    def upload_text(self, remote_path: str, content: str, *, step: str) -> None:
        if not self._client:
            raise WorkflowError(step, "SSH client is not connected", details={"host": self.host})
        logger.info("SSH text upload started", extra={"step": step, "target": self.host})
        try:
            with self._client.open_sftp() as sftp, sftp.open(remote_path, "wb") as remote:
                remote.write(content.encode("utf-8-sig"))
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
