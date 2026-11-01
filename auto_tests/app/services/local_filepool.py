"""Prepare a filepool matching the published or development source under test."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import time
from dataclasses import dataclass
from http import HTTPStatus
from pathlib import Path, PureWindowsPath
from urllib.parse import urljoin, urlsplit

import httpx
from cryptography.hazmat.primitives import hashes
from cryptography.hazmat.primitives.asymmetric import padding

from app.clients import network_recovery
from app.errors import WorkflowError
from app.published_release import (
    MAXIMUM_METADATA_BYTES,
    MAXIMUM_SIGNATURE_BYTES,
    _download_bytes,
    _load_public_key,
)

MAXIMUM_ARTIFACT_BYTES = 16 * 1024**3
DOWNLOAD_ATTEMPTS = 2
DOWNLOAD_CHUNK_BYTES = 1024 * 1024
PROGRESS_INTERVAL_BYTES = 64 * 1024**2
DOWNLOAD_RETRY_DELAY_SECONDS = 3
HTTP_TIMEOUT_SECONDS = 60
VM_DIRECTORY_TIMEOUT_SECONDS = 30
RETRYABLE_HTTP_STATUSES = {
    HTTPStatus.TOO_MANY_REQUESTS,
    HTTPStatus.INTERNAL_SERVER_ERROR,
    HTTPStatus.BAD_GATEWAY,
    HTTPStatus.SERVICE_UNAVAILABLE,
    HTTPStatus.GATEWAY_TIMEOUT,
}


@dataclass
class _DownloadAttempt:
    count: int = 0
    response: httpx.Response | None = None


def catalog_artifacts(catalog: dict) -> list[dict]:
    artifacts = catalog["artifacts"]
    files = [artifacts["wpf"], *artifacts["miniIso"].values(), *artifacts["support"].values()]
    files += [
        {
            "fileName": distro["isoInstallerFileName"],
            "url": distro["isoInstaller"],
            "sha256": distro["isoInstallerSha256"],
            "sizeBytes": distro["isoInstallerSizeBytes"],
        }
        for distro in catalog["distributions"]
    ]
    names = set()
    for item in files:
        name = item["fileName"]
        if (
            not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", name)
            or name in names
            or not re.fullmatch(r"[0-9a-fA-F]{64}", item["sha256"])
            or not isinstance(item["sizeBytes"], int)
            or not 0 < item["sizeBytes"] <= MAXIMUM_ARTIFACT_BYTES
        ):
            raise ValueError("Invalid local filepool artifact metadata")
        names.add(name)
    return files


def download_artifact(client, url, destination, size, digest, progress, result, vm_name):
    temporary = destination.with_name(destination.name + ".partial")
    for attempt in range(1, DOWNLOAD_ATTEMPTS + 1):
        network_recovery.checkpoint()
        state = _DownloadAttempt()
        try:
            _inspect_partial_download(temporary, size, state)
            if state.count < size:
                _receive_artifact(client, url, temporary, destination.name, size, progress, state)
            _publish_verified_artifact(temporary, destination, size, digest, progress)
            return
        except (httpx.HTTPError, OSError, ValueError) as exc:
            details, retryable = _download_failure_details(
                exc, state, vm_name, destination.name, url, attempt, size
            )
            reason = details["error"]
            if retryable:
                network_recovery.recover(time.monotonic(), context={"vm": vm_name})
            if not retryable or attempt == DOWNLOAD_ATTEMPTS:
                raise WorkflowError(
                    "automation.local_filepool.download",
                    f"Local filepool download failed for {destination.name}: {reason}",
                    details=details,
                ) from exc
            result.ok(
                "automation.local_filepool.retry",
                f"Retrying {destination.name} (attempt {attempt + 1}/{DOWNLOAD_ATTEMPTS}) "
                f"from {state.count} bytes: {reason}",
                **details,
            )
            time.sleep(DOWNLOAD_RETRY_DELAY_SECONDS)


def _inspect_partial_download(temporary, size, state):
    if temporary.is_symlink():
        raise ValueError("Partial download must not be a symbolic link")
    state.count = temporary.stat().st_size if temporary.exists() else 0
    if state.count > size:
        raise ValueError("Partial download exceeds signed size")


def _receive_artifact(client, url, temporary, name, size, progress, state):
    headers = {"Accept-Encoding": "identity"}
    if state.count:
        headers["Range"] = f"bytes={state.count}-"
    with client.stream("GET", url, headers=headers) as response:
        state.response = response
        _validate_download_response(response, size, state)
        progress("Resuming" if state.count else "Downloading", name, state.count, size)
        _write_download_body(response, temporary, name, size, progress, state)
    if state.count != size:
        raise httpx.RemoteProtocolError("Download ended before the signed size")


def _validate_download_response(response, size, state):
    response.raise_for_status()
    if response.status_code == HTTPStatus.PARTIAL_CONTENT:
        expected = f"bytes {state.count}-{size - 1}/{size}"
        if response.headers.get("Content-Range") != expected:
            raise ValueError("Download range does not match requested bytes")
    elif response.status_code == HTTPStatus.OK:
        # A server may ignore Range; never append its full response.
        state.count = 0
    else:
        raise ValueError("Unexpected download response status")
    if response.headers.get("Content-Encoding", "identity") != "identity":
        raise ValueError("Download must use identity encoding for byte ranges")


def _write_download_body(response, temporary, name, size, progress, state):
    reported = state.count
    with temporary.open("ab" if state.count else "wb") as stream:
        for chunk in response.iter_bytes(DOWNLOAD_CHUNK_BYTES):
            if state.count + len(chunk) > size:
                raise ValueError("Download exceeds signed size")
            stream.write(chunk)
            state.count += len(chunk)
            if state.count - reported >= PROGRESS_INTERVAL_BYTES:
                progress("Downloading", name, state.count, size)
                reported = state.count


def _publish_verified_artifact(temporary, destination, size, digest, progress):
    with temporary.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != digest:
        raise ValueError("Downloaded file does not match signed SHA-256")
    temporary.replace(destination)
    progress("Downloaded and verified", destination.name, size, size)


def _download_failure_details(exc, state, vm_name, name, url, attempt, size):
    status = state.response.status_code if state.response is not None else None
    details = {
        "vm": vm_name,
        "file": name,
        "host": urlsplit(url).hostname,
        "attempt": attempt,
        "bytes_transferred": state.count,
        "total_bytes": size,
        "http_status": status,
        "exception_type": type(exc).__name__,
    }
    reason = f"HTTP {status}" if isinstance(exc, httpx.HTTPStatusError) else str(exc)
    details["error"] = reason or type(exc).__name__
    retryable = isinstance(exc, httpx.TransportError) or (
        isinstance(exc, httpx.HTTPStatusError) and status in RETRYABLE_HTTP_STATUSES
    )
    return details, retryable


def prepare_local_filepool(
    validation, vm, executable: PureWindowsPath, result, *, use_default_filepool: bool = True
) -> None:
    settings = validation.settings
    repository = Path(__file__).resolve().parents[3]
    base = (
        settings.published_dev_metadata_base_url
        if use_default_filepool
        else settings.filepool_base_url
    ).rstrip("/") + "/"
    destination = executable.parent / "filepool"

    def progress(action, name, transferred, total):
        result.ok(
            "automation.local_filepool.progress",
            f"{action} {name}: {transferred / 1024**2:.1f}/{total / 1024**2:.1f} MiB "
            f"({100 * transferred / total:.1f}%)",
            vm=vm.name,
            file=name,
            phase=f"{action} {name}",
            sequence=transferred,
            bytes_transferred=transferred,
            total_bytes=total,
        )

    with httpx.Client(follow_redirects=True, timeout=HTTP_TIMEOUT_SECONDS) as client:
        if use_default_filepool:
            catalog_bytes, signature = _read_verified_catalog(client, base, repository)
        else:
            catalog_bytes = _download_bytes(client, base + "catalog.json", MAXIMUM_METADATA_BYTES)
            signature = None
        catalog = json.loads(catalog_bytes)
        artifacts = catalog_artifacts(catalog)
        if not use_default_filepool:
            artifacts.remove(catalog["artifacts"]["wpf"])
        cache = settings.runtime_dir / "local-filepool" / hashlib.sha256(catalog_bytes).hexdigest()
        cache.mkdir(parents=True, exist_ok=True)
        paths = [cache / "catalog.json"]
        paths[0].write_bytes(catalog_bytes)
        if signature is not None:
            signature_path = cache / "catalog.json.sig"
            signature_path.write_bytes(signature)
            paths.append(signature_path)
        for item in artifacts:
            name, size, digest = item["fileName"], item["sizeBytes"], item["sha256"].lower()
            selected = _find_cached_artifact(repository, cache, name, size, digest, progress)
            if selected is None:
                url = urljoin(base, item["url"])
                parsed = urlsplit(url)
                if (
                    parsed.scheme not in (("https",) if use_default_filepool else ("http", "https"))
                    or not parsed.hostname
                    or parsed.username
                    or parsed.password
                ):
                    raise ValueError(
                        "Signed artifacts must use HTTPS without credentials"
                        if use_default_filepool
                        else "Development artifacts must use HTTP(S) without credentials"
                    )
                selected = cache / name
                download_artifact(client, url, selected, size, digest, progress, result, vm.name)
            paths.append(selected)
        with validation.ssh(
            vm.host,
            vm.username,
            settings.windows_ssh_password.get_secret_value(),
            remote_os="windows",
        ) as ssh:
            validation.run_windows_script(
                ssh,
                script_name="local_filepool.ps1",
                config={"mode": "prepare", "directory": str(destination)},
                step="automation.local_filepool.directory",
                timeout=VM_DIRECTORY_TIMEOUT_SECONDS,
            )
            for path in paths:
                _upload_artifact(ssh, path, destination, progress)
    result.ok(
        "automation.local_filepool.prepared",
        (
            "Signed catalog and all artifacts copied beside Libertix.exe"
            if use_default_filepool
            else "Development catalog and installation artifacts copied beside Libertix.exe"
        ),
        vm=vm.name,
        directory=str(destination),
        files=[path.name for path in paths],
        catalog_sha256=hashlib.sha256(catalog_bytes).hexdigest(),
        metadata_url=base,
    )


def _read_verified_catalog(client, base, repository):
    catalog_bytes = _download_bytes(client, base + "catalog.json", MAXIMUM_METADATA_BYTES)
    signature = _download_bytes(client, base + "catalog.json.sig", MAXIMUM_SIGNATURE_BYTES)
    _load_public_key(repository / "Scripts/config/Libertix.CatalogPublicKey.xml").verify(
        base64.b64decode(signature.strip(), validate=True),
        catalog_bytes,
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
    return catalog_bytes, signature


def _find_cached_artifact(repository, cache, name, size, digest, progress):
    for candidate in (repository / "auto_tests/app/filepool" / name, cache / name):
        if not candidate.is_file() or candidate.is_symlink() or candidate.stat().st_size != size:
            continue
        with candidate.open("rb") as stream:
            if hashlib.file_digest(stream, "sha256").hexdigest() == digest:
                progress("Verified cached", name, size, size)
                return candidate
    return None


def _upload_artifact(ssh, path, destination, progress):
    reported = 0
    progress("Copying to VM", path.name, 0, path.stat().st_size)

    def upload_progress(done, total, *, name=path.name):
        nonlocal reported
        if done == total or done - reported >= PROGRESS_INTERVAL_BYTES:
            progress("Copying to VM", name, done, total)
            reported = done

    ssh.upload_file(
        path,
        str(destination / path.name),
        step="automation.local_filepool.copy",
        on_progress=upload_progress,
    )
