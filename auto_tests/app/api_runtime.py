from __future__ import annotations

import fcntl
import logging
import os
import re
import shutil
import stat
import threading
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from multiprocessing.process import BaseProcess
from pathlib import Path
from threading import Lock

from app.config import Settings

logger = logging.getLogger(__name__)

_OPERATION_ARTIFACT_PATTERN = re.compile(
    r"^(automation|validation|reset)-(\d{8}T\d{6}Z)-([0-9a-f]{8})$"
)


class ProcessOperationLock:
    """Serialize destructive operations across threads and Uvicorn processes."""

    def __init__(self, path: Path) -> None:
        self._thread_lock = Lock()
        self._path = path
        self._file = None

    def acquire(self, *, blocking: bool = False) -> bool:
        if not self._thread_lock.acquire(blocking=blocking):
            return False
        descriptor: int | None = None
        try:
            descriptor = os.open(
                self._path,
                os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW,
                0o600,
            )
            metadata = os.fstat(descriptor)
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_uid != os.getuid()
                or metadata.st_nlink != 1
            ):
                raise OSError(
                    "Operation lock must be a single-link regular file owned by this user"
                )
            os.fchmod(descriptor, 0o600)
            self._file = os.fdopen(descriptor, "r+", encoding="ascii")
            descriptor = None
            flags = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
            fcntl.flock(self._file.fileno(), flags)
            self._file.seek(0)
            self._file.truncate()
            self._file.write(f"pid={os.getpid()}\n")
            self._file.flush()
            return True
        except BlockingIOError:
            if descriptor is not None:
                os.close(descriptor)
            if self._file is not None:
                self._file.close()
                self._file = None
            self._thread_lock.release()
            return False
        except BaseException:
            if descriptor is not None:
                os.close(descriptor)
            if self._file is not None:
                self._file.close()
                self._file = None
            self._thread_lock.release()
            raise

    def release(self) -> None:
        if self._file is not None:
            fcntl.flock(self._file.fileno(), fcntl.LOCK_UN)
            self._file.close()
            self._file = None
        self._thread_lock.release()


operation_lock = ProcessOperationLock(Path("/tmp/libertix-auto-tests.lock"))


@dataclass(frozen=True)
class KilledOperation:
    operation: str
    pid: int


class ActiveOperationProcess:
    """Track and forcibly terminate only the isolated operation process."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._process: BaseProcess | None = None
        self._operation: str | None = None

    def register(self, process: BaseProcess, operation: str) -> None:
        with self._lock:
            if self._process is not None and self._process.is_alive():
                raise RuntimeError("An operation process is already active")
            self._process = process
            self._operation = operation

    def clear(self, process: BaseProcess) -> None:
        with self._lock:
            if self._process is process:
                self._process = None
                self._operation = None

    def kill_active(self) -> KilledOperation | None:
        with self._lock:
            process = self._process
            operation = self._operation
            if process is None or operation is None or not process.is_alive():
                return None
            if process.pid is None:
                return None
            killed = KilledOperation(operation=operation, pid=process.pid)
            process.kill()
            return killed


def mark_capture_workspace_owned(path: Path) -> None:
    (path / ".owner-pid").write_text(f"{os.getpid()}\n", encoding="ascii")


def create_capture_workspace(settings: Settings, operation: str) -> Path:
    if operation not in {"automation", "validation", "reset"}:
        raise ValueError("Unsupported operation workspace type")
    settings.capture_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    path = settings.capture_dir / f"{operation}-{timestamp}-{uuid.uuid4().hex[:8]}"
    path.mkdir(mode=0o700)
    mark_capture_workspace_owned(path)
    return path


def mark_capture_workspace_complete(path: Path) -> None:
    (path / ".completed").write_text(
        datetime.now(UTC).isoformat().replace("+00:00", "Z") + "\n",
        encoding="ascii",
    )


def _workspace_owner_is_alive(path: Path) -> bool:
    if (path / ".completed").is_file():
        return False
    try:
        owner_pid = int((path / ".owner-pid").read_text(encoding="ascii").strip())
        os.kill(owner_pid, 0)
        return True
    except (FileNotFoundError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True


@dataclass(frozen=True)
class OperationArtifact:
    operation: str
    path: Path
    is_workspace: bool
    modified_ns: int


def _operation_artifacts(settings: Settings) -> list[OperationArtifact]:
    artifacts: list[OperationArtifact] = []
    if settings.capture_dir.is_dir():
        for path in settings.capture_dir.iterdir():
            match = _OPERATION_ARTIFACT_PATTERN.fullmatch(path.name)
            if match is None:
                continue
            try:
                if path.is_symlink() or not path.is_dir():
                    logger.warning(
                        "Refusing to retain an operation entry that is not a real "
                        "workspace directory",
                        extra={"step": "capture.cleanup", "target": str(path)},
                    )
                    continue
                if _workspace_owner_is_alive(path):
                    continue
                artifacts.append(
                    OperationArtifact(
                        operation=match.group(1),
                        path=path,
                        is_workspace=True,
                        modified_ns=path.stat(follow_symlinks=False).st_mtime_ns,
                    )
                )
            except OSError:
                logger.warning(
                    "Failed to inspect an operation workspace",
                    extra={"step": "capture.retention", "target": str(path)},
                )

    if settings.operation_log_dir.is_dir():
        for path in settings.operation_log_dir.iterdir():
            match = _OPERATION_ARTIFACT_PATTERN.fullmatch(path.stem)
            if match is None or path.suffix != ".txt":
                continue
            try:
                metadata = path.lstat()
                if (
                    path.is_symlink()
                    or not stat.S_ISREG(metadata.st_mode)
                    or metadata.st_uid != os.getuid()
                    or metadata.st_nlink != 1
                ):
                    logger.warning(
                        "Refusing to retain an operation log that is not a private regular file",
                        extra={"step": "capture.cleanup", "target": str(path)},
                    )
                    continue
                artifacts.append(
                    OperationArtifact(
                        operation=match.group(1),
                        path=path,
                        is_workspace=False,
                        modified_ns=metadata.st_mtime_ns,
                    )
                )
            except OSError:
                logger.warning(
                    "Failed to inspect a legacy operation log",
                    extra={"step": "capture.retention", "target": str(path)},
                )
    return artifacts


def operation_artifact_cleanup_candidates(
    settings: Settings, keep: int = 3
) -> list[OperationArtifact]:
    """Return generated operation artifacts older than the retention window."""

    if keep < 1:
        raise ValueError("At least one operation run must be retained")

    grouped: dict[str, list[OperationArtifact]] = {
        name: [] for name in ("automation", "validation", "reset")
    }
    for artifact in _operation_artifacts(settings):
        grouped[artifact.operation].append(artifact)

    candidates: list[OperationArtifact] = []
    for artifacts in grouped.values():
        artifacts.sort(key=lambda item: (item.modified_ns, item.path.name), reverse=True)
        candidates.extend(artifacts[keep:])
    return sorted(candidates, key=lambda item: str(item.path))


def capture_workspace_cleanup_candidates(settings: Settings, keep: int = 3) -> list[Path]:
    """Return old generated workspace directories eligible for cleanup."""

    return [
        artifact.path
        for artifact in operation_artifact_cleanup_candidates(settings, keep=keep)
        if artifact.is_workspace
    ]


def cleanup_operation_artifacts(settings: Settings, keep: int = 3) -> None:
    """Retain the latest runs across current workspaces and legacy logs."""

    for artifact in operation_artifact_cleanup_candidates(settings, keep=keep):
        try:
            if artifact.is_workspace:
                shutil.rmtree(artifact.path)
            else:
                artifact.path.unlink()
        except OSError:
            logger.warning(
                "Failed to remove an old operation artifact",
                extra={"step": "capture.retention", "target": str(artifact.path)},
            )
