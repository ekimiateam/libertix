from __future__ import annotations

import io
import json
import stat
from contextlib import nullcontext
from pathlib import Path
from types import SimpleNamespace

import pytest

from app.errors import WorkflowError
from app.services import automation_diagnostics as diagnostics
from app.services.automation_types import AutomationOptions


class RemoteFile(io.BytesIO):
    def stat(self):
        return SimpleNamespace(st_size=len(self.getvalue()))


class FakeSftp:
    def __init__(self):
        self.files = {
            "/logs/nested/installer.log": b"full log\n" * 10000,
            "/logs/unattended-123.status.json": b'{"stage":"failed"}',
            "/logs/launch-123.result.json": b'{"status":"error"}',
            "/logs/unattended-123.json": b"test credential must not be downloaded",
            "/logs/windows-preferences.secret.json": b"test Wi-Fi secret",
            "/logs/password.txt": b"test password",
            "/logs/Libertix.exe": b"binary is not a log",
        }
        self.opened = []

    def lstat(self, path):
        if path not in {"/logs", "/logs/nested"}:
            raise FileNotFoundError(path)
        return SimpleNamespace(st_mode=stat.S_IFDIR)

    def listdir_attr(self, path):
        names = {
            str(Path(name).relative_to(path)).split("/")[0]
            for name in self.files
            if name.startswith(path + "/")
        }
        result = [
            SimpleNamespace(
                filename=name,
                st_mode=stat.S_IFREG if path + "/" + name in self.files else stat.S_IFDIR,
            )
            for name in sorted(names)
        ]
        if path == "/logs":
            result.append(SimpleNamespace(filename="linked.log", st_mode=stat.S_IFLNK))
        return result

    def open(self, path, mode):
        assert mode == "rb"
        self.opened.append(path)
        return RemoteFile(self.files[path])


@pytest.mark.parametrize(
    "name",
    [
        "storage-before-installation.json",
        "uninstall-verification.json",
        "source-encryption-original.json",
        "pending.env",
        "install-success.env",
        "live-started.env",
        "live-failed.env",
    ],
)
def test_collection_includes_durable_recovery_and_uninstall_reports(name):
    assert diagnostics.is_diagnostic_file(name)


def test_collection_downloads_full_logs_and_states_but_not_secrets_or_links(tmp_path):
    sftp = FakeSftp()
    records = []
    diagnostics.download_diagnostics(sftp, "/logs", tmp_path, records)
    copied = [item for item in records if item["status"] == "copied"]
    assert len(copied) == 3
    assert (tmp_path / "nested/installer.log").read_bytes() == sftp.files[
        "/logs/nested/installer.log"
    ]
    assert all(Path(item["local_path"]).stat().st_mode & 0o777 == 0o600 for item in copied)
    assert len(sftp.opened) == 3
    assert all(diagnostics.is_diagnostic_file(Path(path).name) for path in sftp.opened)


@pytest.mark.parametrize("exception", [PermissionError("denied"), TimeoutError("network")])
def test_collection_records_unreadable_logs_without_discarding_other_files(
    monkeypatch, tmp_path, exception
):
    sftp = FakeSftp()
    original = sftp.open

    def read(path, mode):
        if path.endswith("installer.log"):
            raise exception
        return original(path, mode)

    monkeypatch.setattr(sftp, "open", read)
    records = []
    diagnostics.download_diagnostics(sftp, "/logs", tmp_path, records)
    assert sum(item["status"] == "error" for item in records) == 1
    assert sum(item["status"] == "copied" for item in records) == 2


@pytest.mark.parametrize(
    ("available_os", "context_outcome"),
    [
        ("windows", "complete"),
        ("linux", "complete"),
        ("windows", "command-error"),
        ("linux", "command-error"),
        ("windows", "nonzero-exit"),
        ("linux", "nonzero-exit"),
        ("windows", "missing-completion-marker"),
        ("windows", "sftp-error"),
        ("linux", "sftp-error"),
        (None, "unreachable"),
    ],
)
def test_failure_bundle_waits_then_collects_and_records_original_error(
    monkeypatch, tmp_path, available_os, context_outcome
):
    events = []
    clients = []
    sftp = FakeSftp()
    settings = SimpleNamespace(
        windows_ssh_password=SimpleNamespace(get_secret_value=lambda: "windows-test-secret"),
        ssh_known_hosts=tmp_path / "known-hosts",
        ssh_port=22,
        ssh_timeout_seconds=2,
    )
    vm = SimpleNamespace(name="vm2", vmid=501, username="admin", host="192.0.2.241")

    class FakeSSH:
        def __init__(self, host, username, password, **kwargs):
            self.remote_os = kwargs["remote_os"]
            clients.append(kwargs)

        def __enter__(self):
            assert events[:2] == [("capture", "screen.png"), ("wait", 15)]
            events.append(("ssh", self.remote_os))
            if self.remote_os != available_os:
                raise WorkflowError("ssh.connect", "test connection unavailable")
            return self

        def __exit__(self, *_args):
            pass

        def _text_sftp(self, timeout):
            assert timeout == 300
            if context_outcome == "sftp-error":
                raise WorkflowError(
                    "ssh.sftp", "SFTP channel failed", details={"sftp_phase": "negotiation"}
                )
            return nullcontext(sftp)

        def upload_text(self, path, source, **kwargs):
            assert self.remote_os == "windows"
            assert path.startswith("C:/Windows/Temp/libertix-diagnostics-")
            assert "LIBERTIX_DIAGNOSTICS_COMPLETED" in source
            assert kwargs["replay_safe"] is True
            events.append(("upload", path))

        def run(self, command, **kwargs):
            assert kwargs["replay_safe"] is True
            if kwargs["step"] == "automation.diagnostics.cleanup_script":
                events.append(("cleanup", self.remote_os))
                return SimpleNamespace(exit_code=0, stdout="", stderr="")
            assert kwargs["step"] == "automation.diagnostics.context"
            assert kwargs["check"] is False
            events.append(("context", self.remote_os))
            if context_outcome == "command-error":
                raise WorkflowError(
                    kwargs["step"],
                    "Remote command execution failed",
                    details={"exception_type": "TimeoutError", "error": "context deadline"},
                )
            return SimpleNamespace(
                exit_code=1 if context_outcome == "nonzero-exit" else 0,
                stdout="LIBERTIX_DIAGNOSTICS_STARTED\n"
                + (
                    ""
                    if context_outcome == "missing-completion-marker"
                    else "LIBERTIX_DIAGNOSTICS_COMPLETED\n"
                ),
                stderr="section failed" if context_outcome == "nonzero-exit" else "",
            )

    monkeypatch.setattr(diagnostics, "SSHClient", FakeSSH)
    monkeypatch.setattr(diagnostics.time, "sleep", lambda seconds: events.append(("wait", seconds)))
    monkeypatch.setattr(diagnostics, "WINDOWS_LOG_ROOTS", ("/logs",))
    monkeypatch.setattr(diagnostics, "LINUX_LOG_ROOTS", ("/logs",))
    original = {"step": "automation.launch_elevated", "message": "original failure"}
    path = diagnostics.collect_failure_diagnostics(
        settings,
        vm,
        AutomationOptions("test", "linux-test-secret", True),
        tmp_path / "mint-linux-first" / "captures",
        [original],
        lambda path: events.append(("capture", path.name)),
    )
    report = json.loads(path.read_text())
    assert report["errors"] == [original]
    assert report["vmid"] == 501 and report["scenario"] == "mint-linux-first"
    assert "VM501-automation.launch_elevated" in str(path)
    assert report["status"] == ("collected" if context_outcome == "complete" else "incomplete")
    if available_os:
        assert ("context", available_os) in events
        context = report["system_context"]
        expected_context = (
            "collected" if context_outcome in {"complete", "sftp-error"} else "incomplete"
        )
        assert context["status"] == expected_context
        assert context["elapsed_seconds"] >= 0
        if context_outcome == "command-error":
            assert context["phase"] == "execute"
            assert context["failure"]["details"]["error"] == "context deadline"
        else:
            assert context["phase"] == "finished"
            assert Path(context["path"]).is_file()
            assert "STDERR:" in Path(context["path"]).read_text()
        if available_os == "windows":
            assert ("cleanup", "windows") in events
        if context_outcome == "sftp-error":
            assert report["files"][0]["failure"]["details"]["sftp_phase"] == "negotiation"
        else:
            assert len([item for item in report["files"] if item["status"] == "copied"]) == 3
    assert "windows-test-secret" not in path.read_text()
    assert "linux-test-secret" not in path.read_text()
    assert clients[0]["trust_on_first_use"] is False
    if available_os != "windows":
        assert (
            clients[1]["known_hosts_path"]
            == tmp_path / "mint-linux-first/captures/vm2-linux-known-hosts"
        )


def test_missing_root_is_recorded_and_not_created_remotely(tmp_path):
    records = []
    diagnostics.download_diagnostics(FakeSftp(), "/absent", tmp_path, records)
    assert records == [{"remote_path": "/absent", "status": "absent"}]
    assert not list(tmp_path.iterdir())


def test_linux_collection_includes_the_package_update_logs():
    assert "/var/log/apt" in diagnostics.LINUX_LOG_ROOTS
    assert "/var/log/unattended-upgrades" in diagnostics.LINUX_LOG_ROOTS
