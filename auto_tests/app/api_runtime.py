from __future__ import annotations

import fcntl
import logging
import os
import shutil
import stat
import threading
from dataclasses import dataclass
from multiprocessing.process import BaseProcess
from pathlib import Path
from threading import Lock

from app.config import Settings

logger = logging.getLogger(__name__)


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
        except (BlockingIOError, OSError):
            if descriptor is not None:
                os.close(descriptor)
            if self._file is not None:
                self._file.close()
                self._file = None
            self._thread_lock.release()
            return False

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


def _workspace_owner_is_alive(path: Path) -> bool:
    try:
        owner_pid = int((path / ".owner-pid").read_text(encoding="ascii").strip())
        os.kill(owner_pid, 0)
        return True
    except (FileNotFoundError, ValueError, ProcessLookupError):
        return False
    except PermissionError:
        return True


def cleanup_capture_workspaces(settings: Settings) -> None:
    """Remove capture workspaces left behind by an interrupted API process."""

    for path in settings.capture_dir.iterdir():
        try:
            if not path.name.startswith(("automation-", "validation-")):
                continue
            if path.is_symlink() or not path.is_dir():
                logger.warning(
                    "Refusing to remove a capture entry that is not a real workspace directory",
                    extra={"step": "capture.cleanup", "target": str(path)},
                )
                continue
            if path.is_dir() and _workspace_owner_is_alive(path):
                continue
            shutil.rmtree(path)
        except OSError:
            logger.warning(
                "Failed to remove a stale capture workspace",
                extra={"step": "capture.cleanup", "target": str(path)},
            )
