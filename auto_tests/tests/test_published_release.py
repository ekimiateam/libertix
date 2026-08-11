from __future__ import annotations

import base64
import hashlib
import io
import json
import zipfile
from pathlib import Path

import httpx
import pytest
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from app.errors import WorkflowError
from app.published_release import download_published_dev_release


def _application_key(tmp_path: Path) -> tuple[rsa.RSAPrivateKey, Path]:
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    numbers = private_key.public_key().public_numbers()
    modulus = numbers.n.to_bytes((numbers.n.bit_length() + 7) // 8, "big")
    exponent = numbers.e.to_bytes((numbers.e.bit_length() + 7) // 8, "big")
    path = tmp_path / "CatalogPublicKey.xml"
    path.write_text(
        "<RSAKeyValue><Modulus>"
        + base64.b64encode(modulus).decode("ascii")
        + "</Modulus><Exponent>"
        + base64.b64encode(exponent).decode("ascii")
        + "</Exponent></RSAKeyValue>",
        encoding="utf-8",
    )
    return private_key, path


def _signed(private_key: rsa.RSAPrivateKey, value: object) -> tuple[bytes, bytes]:
    payload = (json.dumps(value) + "\n").encode()
    signature = private_key.sign(payload, padding.PKCS1v15(), hashes.SHA256())
    return payload, base64.b64encode(signature) + b"\n"


def _wpf_archive() -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w") as archive:
        archive.writestr("Libertix.exe", b"published executable")
        archive.writestr("BUILD-INFO.txt", "test")
    return buffer.getvalue()


def test_published_dev_release_is_signed_hashed_and_extracted(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    private_key, public_key = _application_key(tmp_path)
    archive = _wpf_archive()
    tag = "a881918"
    commit = tag + "0" * 33
    release_url = f"https://github.com/ekimiateam/libertix/releases/download/{tag}/Libertix-wpf.zip"
    releases, releases_signature = _signed(
        private_key,
        {"schemaVersion": 1, "channel": "dev", "latest": {"tag": tag, "commit": commit}},
    )
    catalog, catalog_signature = _signed(
        private_key,
        {
            "schemaVersion": 1,
            "artifacts": {
                "wpf": {
                    "fileName": "Libertix-wpf.zip",
                    "url": release_url,
                    "sha256": hashlib.sha256(archive).hexdigest(),
                    "sizeBytes": len(archive),
                }
            },
            "distributions": [],
        },
    )
    responses = {
        "https://pages.test/dev/releases.json": releases,
        "https://pages.test/dev/releases.json.sig": releases_signature,
        "https://pages.test/dev/catalog.json": catalog,
        "https://pages.test/dev/catalog.json.sig": catalog_signature,
        release_url: archive,
    }

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=responses[str(request.url)], request=request)

    real_client = httpx.Client
    monkeypatch.setattr(
        "app.published_release.httpx.Client",
        lambda **kwargs: real_client(transport=httpx.MockTransport(handler), **kwargs),
    )

    release = download_published_dev_release(
        metadata_base_url="https://pages.test/dev",
        public_key_path=public_key,
        work_directory=tmp_path / "work",
        timeout_seconds=10,
    )

    assert release.tag == tag
    assert release.commit == commit
    assert release.sha256 == hashlib.sha256(archive).hexdigest()
    assert (release.directory / "Libertix.exe").read_bytes() == b"published executable"


def test_published_dev_release_rejects_a_catalog_with_an_invalid_signature(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    private_key, public_key = _application_key(tmp_path)
    releases, releases_signature = _signed(
        private_key,
        {
            "schemaVersion": 1,
            "channel": "dev",
            "latest": {"tag": "a881918", "commit": "a881918" + "0" * 33},
        },
    )
    responses = {
        "https://pages.test/dev/releases.json": releases,
        "https://pages.test/dev/releases.json.sig": releases_signature,
        "https://pages.test/dev/catalog.json": b"{}\n",
        "https://pages.test/dev/catalog.json.sig": b"aW52YWxpZA==\n",
    }

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=responses[str(request.url)], request=request)

    real_client = httpx.Client
    monkeypatch.setattr(
        "app.published_release.httpx.Client",
        lambda **kwargs: real_client(transport=httpx.MockTransport(handler), **kwargs),
    )

    with pytest.raises(WorkflowError, match="latest signed dev build"):
        download_published_dev_release(
            metadata_base_url="https://pages.test/dev",
            public_key_path=public_key,
            work_directory=tmp_path / "work",
            timeout_seconds=10,
        )
