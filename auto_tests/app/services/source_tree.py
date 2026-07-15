from __future__ import annotations

from pathlib import Path


class LocalSourceTree:
    """Policy for selecting files copied by source=local."""

    @staticmethod
    def repository_root() -> Path:
        return Path(__file__).resolve().parents[3]

    @staticmethod
    def include(root: Path, path: Path) -> bool:
        relative = path.relative_to(root)
        parts = set(relative.parts)
        excluded_dirs = {
            ".git",
            ".venv",
            ".pytest_cache",
            ".ruff_cache",
            "__pycache__",
            "bin",
            "obj",
            "captures",
            "filepool",
        }
        if parts & excluded_dirs:
            return False
        if len(relative.parts) >= 2 and relative.parts[:2] == ("auto_tests", "captures"):
            return False
        if len(relative.parts) >= 3 and relative.parts[:3] == (
            "auto_tests",
            "app",
            "filepool",
        ):
            return False
        if path.is_dir():
            return True
        if path.name != ".env.example" and (path.name == ".env" or path.name.startswith(".env.")):
            return False
        if relative.parts == ("Tools", "aria2", "aria2c.exe"):
            return True
        if path.suffix.lower() in {
            ".cache",
            ".dll",
            ".exe",
            ".iso",
            ".pdb",
            ".pyc",
            ".tar",
            ".gz",
            ".zip",
        }:
            return False
        return path.name not in {"uv.lock"}
