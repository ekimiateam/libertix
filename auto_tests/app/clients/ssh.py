from __future__ import annotations

import logging
from dataclasses import dataclass

import paramiko

from app.errors import WorkflowError

logger = logging.getLogger(__name__)


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
        port: int = 22,
        connect_timeout: float = 15,
    ) -> None:
        self.host = host
        self.username = username
        self.password = password
        self.port = port
        self.connect_timeout = connect_timeout
        self._client: paramiko.SSHClient | None = None

    def __enter__(self) -> SSHClient:
        logger.info("Connexion SSH", extra={"step": "ssh.connect", "target": self.host})
        client = paramiko.SSHClient()
        client.load_system_host_keys()
        client.set_missing_host_key_policy(paramiko.AutoAddPolicy())
        try:
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
        except (TimeoutError, paramiko.SSHException, OSError) as exc:
            client.close()
            raise WorkflowError(
                "ssh.connect",
                "Connexion SSH impossible",
                details={
                    "host": self.host,
                    "exception_type": type(exc).__name__,
                    "error": str(exc),
                },
            ) from exc
        self._client = client
        logger.info("Connexion SSH établie", extra={"step": "ssh.connect", "target": self.host})
        return self

    def __exit__(self, *_args: object) -> None:
        if self._client:
            self._client.close()
            logger.info("Connexion SSH fermée", extra={"step": "ssh.close", "target": self.host})

    def run(
        self,
        command: str,
        *,
        step: str,
        timeout: float,
        check: bool = True,
        sensitive: bool = False,
    ) -> CommandResult:
        if not self._client:
            raise WorkflowError(step, "Client SSH non connecté", details={"host": self.host})
        logger.info("Commande distante démarrée", extra={"step": step, "target": self.host})
        try:
            _stdin, stdout, stderr = self._client.exec_command(command, timeout=timeout)
            exit_code = stdout.channel.recv_exit_status()
            out = stdout.read().decode("utf-8", errors="replace").strip()
            err = stderr.read().decode("utf-8", errors="replace").strip()
        except (TimeoutError, paramiko.SSHException, OSError) as exc:
            raise WorkflowError(
                step,
                "Échec d'exécution de la commande distante",
                details={
                    "host": self.host,
                    "command": "[COMMANDE SENSIBLE MASQUÉE]" if sensitive else command,
                    "exception_type": type(exc).__name__,
                    "error": str(exc),
                },
            ) from exc
        logger.info(
            "Commande distante terminée (code=%s)",
            exit_code,
            extra={"step": step, "target": self.host},
        )
        if check and exit_code != 0:
            raise WorkflowError(
                step,
                "La commande distante a échoué",
                details={
                    "host": self.host,
                    "command": "[COMMANDE SENSIBLE MASQUÉE]" if sensitive else command,
                    "exit_code": exit_code,
                    "stdout": out[-4000:],
                    "stderr": err[-4000:],
                },
            )
        return CommandResult(out, err, exit_code)

    def upload_text(self, remote_path: str, content: str, *, step: str) -> None:
        if not self._client:
            raise WorkflowError(step, "Client SSH non connecté", details={"host": self.host})
        logger.info("Upload texte SSH démarré", extra={"step": step, "target": self.host})
        try:
            with self._client.open_sftp() as sftp, sftp.open(remote_path, "wb") as remote:
                remote.write(content.encode("utf-8-sig"))
        except (TimeoutError, paramiko.SSHException, OSError) as exc:
            raise WorkflowError(
                step,
                "Upload texte SSH impossible",
                details={
                    "host": self.host,
                    "remote_path": remote_path,
                    "exception_type": type(exc).__name__,
                    "error": str(exc),
                },
            ) from exc
        logger.info("Upload texte SSH terminé", extra={"step": step, "target": self.host})
