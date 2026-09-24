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
        with pytest.raises(InvalidSignature if failure == "signature" else ValueError):
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
