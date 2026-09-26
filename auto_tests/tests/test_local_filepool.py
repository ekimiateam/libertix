"""Local preparation contracts; HTTP and SSH are isolated from the laboratory."""

import base64
import hashlib
import json
from contextlib import nullcontext
from pathlib import PureWindowsPath
from types import SimpleNamespace

import httpx
import pytest
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa
from pydantic import SecretStr

from app.errors import WorkflowError
from app.services import local_filepool
from app.services.common import ResultBuilder
from app.stream_events import StreamEventProjector


@pytest.mark.parametrize("failure", [None, "signature", "hash", "size"])
def test_signed_filepool_preparation_verifies_before_upload(monkeypatch, tmp_path, failure):
    content = b"test artifact"

    def artifact(name):
        return {
            "fileName": name,
            "url": name,
            "sizeBytes": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
        }

    catalog = {
        "artifacts": {
            "wpf": artifact("test.zip"),
            "miniIso": {"bios": artifact("test-bios.iso"), "uefi": artifact("test-uefi.iso")},
            "support": {"driver": artifact("test-driver.exe")},
        },
        "distributions": [
            {
                "isoInstallerFileName": "test-distro.iso",
                "isoInstaller": "test-distro.iso",
                "isoInstallerSizeBytes": len(content),
                "isoInstallerSha256": hashlib.sha256(content).hexdigest(),
            }
        ],
    }
    raw = json.dumps(catalog, indent=2).encode()
    key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    signature = base64.b64encode(key.sign(raw, padding.PKCS1v15(), hashes.SHA256()))
    if failure == "signature":
        raw += b" "
    monkeypatch.setattr(local_filepool, "_load_public_key", lambda _path: key.public_key())

    def respond(request):
        name = request.url.path.rsplit("/", 1)[-1]
        body = {"catalog.json": raw, "catalog.json.sig": signature}.get(name, content)
        if name == "test-distro.iso":
            if failure == "hash":
                body = b"X" * len(content)
            elif failure == "size":
                body += b"X"
        return httpx.Response(200, content=body)

    client = httpx.Client(transport=httpx.MockTransport(respond))
    monkeypatch.setattr(local_filepool.httpx, "Client", lambda **_kwargs: client)
    uploaded = {}
    actions = []

    class TestSsh:
        def upload_file(self, path, destination, *, step, on_progress):
            uploaded[PureWindowsPath(destination).name] = path.read_bytes()
            on_progress(path.stat().st_size, path.stat().st_size)

    validation = SimpleNamespace(
        settings=SimpleNamespace(
            published_dev_metadata_base_url="https://example.invalid/dev",
            runtime_dir=tmp_path,
            windows_ssh_password=SecretStr("unit-test-only"),
        ),
        ssh=lambda *_args, **_kwargs: nullcontext(TestSsh()),
        run_windows_script=lambda *_args, **kwargs: actions.append(kwargs),
    )
    vm = SimpleNamespace(name="vm2", host="unit-test.invalid", username="test")
    result = ResultBuilder("automation")

    def prepare():
        local_filepool.prepare_local_filepool(
            validation, vm, PureWindowsPath(r"C:\test\Libertix.exe"), result
        )

    if failure:
        with pytest.raises(InvalidSignature if failure == "signature" else WorkflowError):
            prepare()
        assert not uploaded and not actions
        assert not any(step.step == "automation.local_filepool.prepared" for step in result.steps)
    else:
        prepare()
        assert uploaded["catalog.json"] == raw
        assert uploaded["catalog.json.sig"] == signature
        assert len(uploaded) == 7
        assert uploaded["test-distro.iso"] == content
        assert actions[0]["config"] == {"mode": "prepare", "directory": r"C:\test\filepool"}
        assert result.steps[-1].step == "automation.local_filepool.prepared"
        projector = StreamEventProjector("unit", tmp_path / "logs")
        for step in result.steps:
            event = projector.project_step(step)
            assert event is not None
            rendered = projector.render(event, stream_format="compact")
            assert rendered.startswith("FILEPOOL vm2")
            assert step.message in rendered
        assert any("Downloading test-distro.iso" in step.message for step in result.steps)
        assert any("Copying to VM test-distro.iso" in step.message for step in result.steps)


@pytest.mark.parametrize(
    "outcome", ["resume", "ignored-range", "bad-range", "hash", "timeout", "not-found"]
)
def test_download_retry_preserves_bytes_and_requires_signed_integrity(
    monkeypatch, tmp_path, outcome
):
    prefix = b"A" * (1024 * 1024)
    content = prefix + b"end"
    destination = tmp_path / "distro.iso"
    requests = []
    progress = []
    result = ResultBuilder("automation")
    monkeypatch.setattr(local_filepool.time, "sleep", lambda _seconds: None)
    recoveries = []
    monkeypatch.setattr(
        local_filepool.network_recovery, "recover", lambda *a, **k: recoveries.append(k)
    )

    class InterruptedStream(httpx.SyncByteStream):
        def __iter__(self):
            yield prefix
            raise httpx.ReadTimeout("test download stalled")

    def respond(request):
        requests.append(request)
        assert request.headers["Accept-Encoding"] == "identity"
        if len(requests) == 1:
            assert "Range" not in request.headers
            return httpx.Response(200, stream=InterruptedStream())
        assert request.headers["Range"] == f"bytes={len(prefix)}-"
        if outcome == "timeout":
            raise httpx.ReadTimeout("test download still stalled")
        if outcome == "not-found":
            return httpx.Response(404)
        if outcome == "ignored-range":
            return httpx.Response(200, content=content)
        start = 0 if outcome == "bad-range" else len(prefix)
        return httpx.Response(
            206,
            headers={"Content-Range": f"bytes {start}-{len(content) - 1}/{len(content)}"},
            content=b"bad" if outcome == "hash" else b"end",
        )

    def download():
        with httpx.Client(transport=httpx.MockTransport(respond)) as client:
            local_filepool.download_artifact(
                client,
                "https://example.invalid/distro.iso",
                destination,
                len(content),
                hashlib.sha256(content).hexdigest(),
                lambda *a: progress.append(a),
                result,
                "vm2",
            )

    if outcome in {"resume", "ignored-range"}:
        download()
        assert destination.read_bytes() == content
        assert progress[-1][0] == "Downloaded and verified"
    else:
        with pytest.raises(WorkflowError) as caught:
            download()
        assert caught.value.step == "automation.local_filepool.download"
        assert caught.value.details["file"] == "distro.iso"
        assert caught.value.details["attempt"] == 2
        assert not destination.exists()
        assert not any(p[0] == "Downloaded and verified" for p in progress)
    assert len(requests) == 2
    assert recoveries
    assert result.steps[0].step == "automation.local_filepool.retry"
    assert "test download stalled" in result.steps[0].message


def test_download_reuses_complete_verified_partial_without_http(tmp_path):
    destination = tmp_path / "distro.iso"
    destination.with_name("distro.iso.partial").write_bytes(b"complete")
    local_filepool.download_artifact(
        None,
        "https://example.invalid/distro.iso",
        destination,
        8,
        hashlib.sha256(b"complete").hexdigest(),
        lambda *a: None,
        ResultBuilder("test"),
        "vm2",
    )
    assert destination.read_bytes() == b"complete"


@pytest.mark.parametrize("response_kind", ["resume", "not-found", "compressed"])
def test_download_resumes_previous_run_and_does_not_retry_permanent_errors(
    monkeypatch, tmp_path, response_kind
):
    destination = tmp_path / "distro.iso"
    partial = destination.with_name("distro.iso.partial")
    partial.write_bytes(b"part")
    requests = []
    monkeypatch.setattr(local_filepool.time, "sleep", lambda _: pytest.fail("Unexpected retry"))

    def respond(request):
        requests.append(request)
        assert request.headers["Range"] == "bytes=4-"
        if response_kind == "not-found":
            return httpx.Response(404)
        headers = {"Content-Range": "bytes 4-7/8"}
        if response_kind == "compressed":
            headers["Content-Encoding"] = "gzip"
        return httpx.Response(206, headers=headers, stream=httpx.ByteStream(b"done"))

    with httpx.Client(transport=httpx.MockTransport(respond)) as client:

        def download():
            local_filepool.download_artifact(
                client,
                "https://example.invalid/distro.iso",
                destination,
                8,
                hashlib.sha256(b"partdone").hexdigest(),
                lambda *a: None,
                ResultBuilder("test"),
                "vm2",
            )

        if response_kind == "resume":
            download()
            assert destination.read_bytes() == b"partdone"
        else:
            with pytest.raises(WorkflowError):
                download()
            assert not destination.exists()
            assert partial.read_bytes() == b"part"
    assert len(requests) == 1
