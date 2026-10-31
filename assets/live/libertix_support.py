"""Build a local, reviewable support report without collecting plans or secrets."""

from __future__ import annotations

import getpass
import json
import os
import platform
import re
import socket
from datetime import UTC, datetime
from pathlib import Path

ISSUE_URL = "https://github.com/ekimiateam/libertix/issues/new?template=bug_report.md"
MAX_LOG_FILES = 24
MAX_FILE_BYTES = 256 * 1024


def labels(language: str) -> dict[str, str]:
    adjacent = Path(__file__).with_name("Libertix.Translations.json")
    source = Path(__file__).resolve().parents[2] / "Resources/Libertix.Translations.json"
    catalogue = json.loads((adjacent if adjacent.is_file() else source).read_text())
    selected = language if language in catalogue["supportedLanguages"] else "en"
    return catalogue["languages"][selected]["support"]


def redact(value: str) -> str:
    text = re.sub(
        r"-----BEGIN [^-]*PRIVATE KEY-----[\s\S]*?-----END [^-]*PRIVATE KEY-----",
        "[private key hidden]",
        value,
    )
    text = re.sub(
        r"""(?im)^.*(?:password|passwd|passwordHash|secret|token|authorization|credential|\bpsk\b|keyMaterial)\s*["']?\s*[:=].*$""",
        "[sensitive line hidden]",
        text,
    )
    text = re.sub(
        r"""(?i)\bBearer\s+\S+|\bgh[pousr]_[A-Za-z0-9]+|\bsk-[A-Za-z0-9_-]{16,}|\$6\$[^\s"']+""",
        "[secret hidden]",
        text,
    )
    text = re.sub(
        r"(?is)<keyMaterial>.*?</keyMaterial>", "<keyMaterial>[hidden]</keyMaterial>", text
    )
    text = re.sub(r"(?i)(https?://)[^/\s@]+@", r"\1[credentials hidden]@", text)
    text = re.sub(
        r"""(?i)(--?(?:password|passwd|token|secret)\s+)(?:"[^"]*"|'[^']*'|\S+)""",
        r"\1[hidden]",
        text,
    )
    for name in (str(Path.home()), getpass.getuser(), socket.gethostname()):
        if name:
            text = re.sub(re.escape(name), "[hidden]", text, flags=re.IGNORECASE)
    return text


def create(context: str, details: str, roots: tuple[Path, ...]) -> str:
    build_path = Path("/etc/libertix-build-id")
    try:
        version = build_path.read_text(encoding="utf-8").strip()
    except OSError:
        version = "unavailable"
    lines = [
        "Libertix support report",
        f"UTC: {datetime.now(UTC).isoformat()}",
        f"Version: {version}",
        f"System: {platform.platform()}",
        f"Context: {context}",
        details,
        f"Logs: newest {MAX_LOG_FILES} files maximum; last {MAX_FILE_BYTES} bytes per file.",
    ]
    files: set[Path] = set()
    for root in roots:
        if root.is_symlink():
            continue
        if root.is_file():
            if root.suffix.lower() in (".log", ".txt"):
                files.add(root)
            continue
        for directory, children, names in os.walk(root, followlinks=False):
            children[:] = [name for name in children if not (Path(directory) / name).is_symlink()]
            for name in names:
                path = Path(directory) / name
                if not path.is_symlink() and path.suffix in (".log", ".txt"):
                    files.add(path)
    readable = []
    for path in files:
        try:
            readable.append((path.stat().st_mtime, path))
        except OSError as error:
            lines.append(f"[log unavailable: {error}]")
    for _, path in sorted(readable, reverse=True)[:MAX_LOG_FILES]:
        lines.append(f"\n=== {path} ===")
        try:
            with path.open("rb") as stream:
                size = path.stat().st_size
                if size > MAX_FILE_BYTES:
                    stream.seek(-MAX_FILE_BYTES, 2)
                    lines.append("[earlier log content omitted]")
                lines.append(stream.read(MAX_FILE_BYTES).decode("utf-8", errors="replace"))
        except OSError as error:
            lines.append(f"[log unavailable: {error}]")
    return redact("\n".join(lines))
