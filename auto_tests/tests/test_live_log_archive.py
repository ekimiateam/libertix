from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ARCHIVER = ROOT / "assets/live/libertix-log-archive.py"


def test_archive_after_abrupt_exit_excludes_secrets_probes_and_symlinks(tmp_path: Path) -> None:
    logs = tmp_path / "libertix"
    logs.mkdir()
    private = tmp_path / "libertix-private"
    private.mkdir(mode=0o700)
    secret = b"synthetic-wifi-secret-must-not-be-archived"
    (private / "windows-preferences.secret.json").write_bytes(secret)
    (logs / "windows-preferences.secret.json").write_bytes(secret)
    probe = logs / "plan-candidates.interrupted"
    probe.mkdir()
    (probe / "preferences.secret.json").write_bytes(secret)
    (logs / "linked.log").symlink_to(private / "windows-preferences.secret.json")
    (logs / "nested.log").mkdir()
    (logs / "nested.log" / "private").write_bytes(secret)
    public = {
        "install.log": b"installer interrupted",
        "Xorg.0.log.old": b"Xorg diagnostics",
        "installation-state.json": b'{"status":"running"}',
        "failure": b"signal=KILL",
        "010-read-config.started": b"",
        "mbr-before-grub.bin": bytes(range(256)) * 2,
    }
    for name, content in public.items():
        (logs / name).write_bytes(content)
    archive = tmp_path / "archive"
    latest = tmp_path / "latest"
    for source, destination in ((logs, archive), (archive, latest)):
        subprocess.run(
            [sys.executable, str(ARCHIVER), str(source), str(destination)],
            check=True,
            capture_output=True,
            text=True,
        )
        assert {path.name: path.read_bytes() for path in destination.iterdir()} == public
        assert all(secret not in path.read_bytes() for path in destination.iterdir())
    assert (private / "windows-preferences.secret.json").read_bytes() == secret


def test_archive_refuses_destination_symlink(tmp_path: Path) -> None:
    logs = tmp_path / "logs"
    archive = tmp_path / "archive"
    logs.mkdir()
    archive.mkdir()
    (logs / "install.log").write_text("diagnostic")
    victim = tmp_path / "unrelated"
    victim.write_text("preserve")
    (archive / "install.log").symlink_to(victim)
    result = subprocess.run(
        [sys.executable, str(ARCHIVER), str(logs), str(archive)],
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode != 0
    assert victim.read_text() == "preserve"
