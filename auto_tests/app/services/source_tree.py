from __future__ import annotations

import subprocess
from pathlib import Path


class LocalSourceTree:
    """Policy for selecting files copied by source=local."""

    @staticmethod
    def repository_root() -> Path:
        return Path(__file__).resolve().parents[3]

    @staticmethod
    def selected_files(root: Path) -> tuple[Path, ...]:
        """Return tracked and non-ignored files from the current Git worktree."""

        completed = subprocess.run(
            [
                "git",
                "-C",
                str(root),
                "ls-files",
                "--cached",
                "--others",
                "--exclude-standard",
                "-z",
            ],
            check=False,
            capture_output=True,
        )
        if completed.returncode != 0:
            diagnostic = completed.stderr.decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"Git could not enumerate the local source tree: {diagnostic}")

        selected: list[Path] = []
        for raw_relative in completed.stdout.split(b"\0"):
            if not raw_relative:
                continue
            relative = Path(raw_relative.decode("utf-8", errors="strict"))
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(f"Git returned an unsafe source path: {relative}")
            path = root / relative
            if path.is_file() or path.is_symlink():
                selected.append(path)
        return tuple(sorted(selected, key=lambda path: path.as_posix()))
