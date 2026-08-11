from __future__ import annotations

import base64
import hashlib
import json
import re
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from io import BytesIO
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

import httpx
from cryptography.exceptions import InvalidSignature
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding, rsa

from app.errors import WorkflowError

SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
SHA7_PATTERN = re.compile(r"^[0-9a-f]{7}$")
MAXIMUM_METADATA_BYTES = 1024 * 1024
MAXIMUM_SIGNATURE_BYTES = 16 * 1024
MAXIMUM_WPF_ARCHIVE_BYTES = 64 * 1024 * 1024


@dataclass(frozen=True)
class PublishedRelease:
    directory: Path
    tag: str
    commit: str
    sha256: str


def _download_bytes(client: httpx.Client, url: str, maximum_bytes: int) -> bytes:
    with client.stream("GET", url) as response:
        response.raise_for_status()
        content_length = response.headers.get("content-length")
        if content_length is not None and int(content_length) > maximum_bytes:
            raise ValueError(f"published file exceeds {maximum_bytes} bytes: {url}")
        payload = bytearray()
        for chunk in response.iter_bytes():
            payload.extend(chunk)
            if len(payload) > maximum_bytes:
                raise ValueError(f"published file exceeds {maximum_bytes} bytes: {url}")
    return bytes(payload)


def _load_public_key(path: Path) -> rsa.RSAPublicKey:
    root = ET.fromstring(path.read_text(encoding="utf-8"))
    modulus = root.findtext("Modulus")
    exponent = root.findtext("Exponent")
    if not modulus or not exponent:
        raise ValueError("application catalog public key is incomplete")
    numbers = rsa.RSAPublicNumbers(
        int.from_bytes(base64.b64decode(exponent, validate=True), "big"),
        int.from_bytes(base64.b64decode(modulus, validate=True), "big"),
    )
    return numbers.public_key()


def _verify_signed_json(
    client: httpx.Client,
    base_url: str,
    file_name: str,
    public_key: rsa.RSAPublicKey,
) -> dict[str, object]:
    payload = _download_bytes(client, f"{base_url}/{file_name}", MAXIMUM_METADATA_BYTES)
    encoded_signature = _download_bytes(
        client,
        f"{base_url}/{file_name}.sig",
        MAXIMUM_SIGNATURE_BYTES,
    )
    signature = base64.b64decode(encoded_signature.strip(), validate=True)
    public_key.verify(signature, payload, padding.PKCS1v15(), hashes.SHA256())
    value = json.loads(payload.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError(f"{file_name} is not a JSON object")
    return value


def _validate_release_metadata(metadata: dict[str, object]) -> tuple[str, str]:
    latest = metadata.get("latest")
    if (
        metadata.get("schemaVersion") != 1
        or metadata.get("channel") != "dev"
        or not isinstance(latest, dict)
    ):
        raise ValueError("published dev release metadata is invalid")
    tag = latest.get("tag")
    commit = latest.get("commit")
    if (
        not isinstance(tag, str)
        or not SHA7_PATTERN.fullmatch(tag)
        or not isinstance(commit, str)
        or not re.fullmatch(r"[0-9a-f]{40}", commit)
        or not commit.startswith(tag)
    ):
        raise ValueError("published dev tag and commit do not match")
    return tag, commit


def _validate_wpf_artifact(catalog: dict[str, object], tag: str) -> tuple[str, str, int]:
    artifacts = catalog.get("artifacts")
    wpf = artifacts.get("wpf") if isinstance(artifacts, dict) else None
    if not isinstance(wpf, dict):
        raise ValueError("published catalog does not define the WPF artifact")
    url = wpf.get("url")
    sha256 = wpf.get("sha256")
    size_bytes = wpf.get("sizeBytes")
    parsed = urlsplit(url) if isinstance(url, str) else None
    expected_path = f"/ekimiateam/libertix/releases/download/{tag}/Libertix-wpf.zip"
    if (
        wpf.get("fileName") != "Libertix-wpf.zip"
        or parsed is None
        or parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or parsed.path != expected_path
        or parsed.query
        or parsed.fragment
        or not isinstance(sha256, str)
        or not SHA256_PATTERN.fullmatch(sha256)
        or not isinstance(size_bytes, int)
        or size_bytes <= 0
        or size_bytes > MAXIMUM_WPF_ARCHIVE_BYTES
    ):
        raise ValueError("published WPF artifact metadata is invalid")
    return url, sha256, size_bytes


def _extract_wpf_archive(payload: bytes, destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=False)
    with zipfile.ZipFile(BytesIO(payload)) as archive:
        members = archive.infolist()
        if not members:
            raise ValueError("published WPF archive is empty")
        for member in members:
            path = PurePosixPath(member.filename)
            if path.is_absolute() or ".." in path.parts or not path.parts:
                raise ValueError("published WPF archive contains an unsafe path")
            if ((member.external_attr >> 16) & 0o170000) == 0o120000:
                raise ValueError("published WPF archive contains a symbolic link")
        archive.extractall(destination)
    if not (destination / "Libertix.exe").is_file():
        raise ValueError("published WPF archive does not contain Libertix.exe")


def download_published_dev_release(
    *,
    metadata_base_url: str,
    public_key_path: Path,
    work_directory: Path,
    timeout_seconds: float,
) -> PublishedRelease:
    try:
        public_key = _load_public_key(public_key_path)
        with httpx.Client(
            follow_redirects=True,
            timeout=httpx.Timeout(timeout_seconds),
        ) as client:
            releases = _verify_signed_json(client, metadata_base_url, "releases.json", public_key)
            catalog = _verify_signed_json(client, metadata_base_url, "catalog.json", public_key)
            tag, commit = _validate_release_metadata(releases)
            url, expected_sha256, expected_size = _validate_wpf_artifact(catalog, tag)
            payload = _download_bytes(client, url, MAXIMUM_WPF_ARCHIVE_BYTES)
        if len(payload) != expected_size:
            raise ValueError("published WPF archive size does not match the signed catalog")
        actual_sha256 = hashlib.sha256(payload).hexdigest()
        if actual_sha256 != expected_sha256:
            raise ValueError("published WPF archive hash does not match the signed catalog")
        destination = work_directory / "release"
        _extract_wpf_archive(payload, destination)
        return PublishedRelease(destination, tag, commit, actual_sha256)
    except (
        InvalidSignature,
        OSError,
        ValueError,
        httpx.HTTPError,
        zipfile.BadZipFile,
    ) as exc:
        raise WorkflowError(
            "published_release.download",
            "The latest signed dev build could not be downloaded or verified",
            details={"metadata_base_url": metadata_base_url, "error": str(exc)},
        ) from exc
