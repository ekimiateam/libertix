from __future__ import annotations

import fcntl
import logging
import os
import shutil
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
        try:
            self._file = self._path.open("a+", encoding="ascii")
            flags = fcntl.LOCK_EX | (0 if blocking else fcntl.LOCK_NB)
            fcntl.flock(self._file.fileno(), flags)
            self._file.seek(0)
            self._file.truncate()
            self._file.write(f"pid={os.getpid()}\n")
            self._file.flush()
            return True
        except (BlockingIOError, OSError):
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


def cleanup_capture_workspaces(settings: Settings) -> None:
    """Remove capture workspaces left behind by an interrupted API process."""

    for path in settings.capture_dir.iterdir():
        try:
            if path.is_dir():
                shutil.rmtree(path)
            else:
                path.unlink()
        except OSError:
            logger.warning(
                "Impossible de supprimer un ancien espace de captures",
                extra={"step": "capture.cleanup", "target": str(path)},
            )
