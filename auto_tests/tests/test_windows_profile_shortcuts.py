from __future__ import annotations

import base64
import importlib.util
import json
import os
import stat
import subprocess
from pathlib import Path
from types import SimpleNamespace

import pytest

ROOT = Path(__file__).resolve().parents[2]


def test_generated_bookmark_encodes_spaces_unicode_and_uri_delimiters(tmp_path: Path) -> None:
    source = (ROOT / "assets/live/configure-target-main.sh").read_text()
    body = source.split("configure_windows_profile_shortcuts() {", 1)[1].split("\n}\n", 1)[0]
    body = body.replace('home_dir="/home/$USERNAME"', 'home_dir="$TEST_HOME"')
    profiles = ["Alice Smith", "Caf\u00e9 #100%"]
    script = (
        "set -euo pipefail\nchown() { :; }\nconfigure_windows_profile_shortcuts() {"
        + body
        + "\n}\nconfigure_windows_profile_shortcuts"
    )
    environment = {
        **os.environ,
        "TEST_HOME": str(tmp_path),
        "USERNAME": "test",
        "SHARE_WINDOWS_FILES_IN_LINUX": "true",
        "WINDOWS_PROFILES_JSON_BASE64": base64.b64encode(json.dumps(profiles).encode()).decode(),
    }
    subprocess.run(["bash", "-c", script], env=environment, check=True, capture_output=True)
    bookmarks = (tmp_path / ".config/gtk-3.0/bookmarks").read_text().splitlines()
    for profile in profiles:
        shortcut = tmp_path / f"User_{profile}"
        assert os.readlink(shortcut) == f"/mnt/windows/Users/{profile}"
        assert f"{shortcut.as_uri()} User_{profile}" in bookmarks


@pytest.mark.parametrize("fault", [None, "partition", "target", "missing", "uri", "access"])
def test_verifier_checks_actual_partition_profile_target_and_access(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, fault: str | None
) -> None:
    spec = importlib.util.spec_from_file_location(
        "sharing_verifier", ROOT / "assets/live/libertix-first-boot-verify.py"
    )
    assert spec and spec.loader
    verifier = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(verifier)
    home = tmp_path / "home"
    mount = tmp_path / "windows"
    profile = "Alice #1"
    target = mount / "Users" / profile
    target.mkdir(parents=True)
    (home / ".config/gtk-3.0").mkdir(parents=True)
    shortcut = home / f"User_{profile}"
    shortcut.symlink_to(target if fault != "target" else tmp_path)
    if fault == "missing":
        target.rename(target.with_name("moved"))
    uri = shortcut.as_uri() if fault != "uri" else f"file://{shortcut}"
    (home / ".config/gtk-3.0/bookmarks").write_text(f"{uri} User_{profile}\n")
    monkeypatch.setattr(verifier, "WINDOWS_SHARED_MOUNT_PATH", mount)
    monkeypatch.setattr(
        verifier.pwd, "getpwnam", lambda _: SimpleNamespace(pw_dir=str(home), pw_uid=os.getuid())
    )
    expected = tmp_path / "expected-device"
    source = tmp_path / "actual-device"
    real_stat = Path.stat

    def device_stat(path: Path, **kwargs: object) -> object:
        if path in (expected, source):
            return SimpleNamespace(
                st_mode=stat.S_IFBLK, st_rdev=2 if path == source and fault == "partition" else 1
            )
        return real_stat(path, **kwargs)

    monkeypatch.setattr(Path, "stat", device_stat)
    accesses: list[tuple[str, ...]] = []

    def run(*args: str) -> str:
        if args[0] == "findmnt":
            return json.dumps(
                {"filesystems": [{"source": str(source), "fstype": "fuseblk", "options": "rw"}]}
            )
        accesses.append(args)
        if fault == "access":
            raise verifier.VerificationError("Access refused")
        return ""

    monkeypatch.setattr(verifier, "run", run)
    plan = {
        "account": {"username": "test"},
        "features": {
            "shareWindowsFilesInLinux": True,
            "windowsProfilesJsonBase64": base64.b64encode(json.dumps([profile]).encode()).decode(),
        },
    }
    if fault:
        with pytest.raises(verifier.VerificationError):
            verifier.verify_windows_sharing(plan, expected)
    else:
        assert verifier.verify_windows_sharing(plan, expected)["profileCount"] == 1
        assert accesses == [
            ("runuser", "-u", "test", "--", "test", "-r", str(shortcut)),
            ("runuser", "-u", "test", "--", "test", "-x", str(shortcut)),
        ]
