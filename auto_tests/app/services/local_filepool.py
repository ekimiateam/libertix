"""Prepare a complete signed filepool beside the executable under test."""

from __future__ import annotations

import base64
import hashlib
import json
import re
import time
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
            or not 0 < item["sizeBytes"] <= 16 * 1024**3
        ):
            raise ValueError("Invalid local filepool artifact metadata")
        names.add(name)
    return files


def download_artifact(client, url, destination, size, digest, progress, result, vm_name):
    temporary = destination.with_name(destination.name + ".partial")
    for attempt in range(1, 3):
        network_recovery.checkpoint()
        count = 0
        response = None
        try:
            if temporary.is_symlink():
                raise ValueError("Partial download must not be a symbolic link")
            count = temporary.stat().st_size if temporary.exists() else 0
            if count > size:
                raise ValueError("Partial download exceeds signed size")
            if count < size:
                headers = {"Accept-Encoding": "identity"}
                if count:
                    headers["Range"] = f"bytes={count}-"
                with client.stream("GET", url, headers=headers) as response:
                    response.raise_for_status()
                    if response.status_code == 206:
                        expected = f"bytes {count}-{size - 1}/{size}"
                        if response.headers.get("Content-Range") != expected:
                            raise ValueError("Download range does not match requested bytes")
                    elif response.status_code == 200:
                        # A server may ignore Range; never append its full response.
                        count = 0
                    else:
                        raise ValueError("Unexpected download response status")
                    if response.headers.get("Content-Encoding", "identity") != "identity":
                        raise ValueError("Download must use identity encoding for byte ranges")
                    progress("Resuming" if count else "Downloading", destination.name, count, size)
                    reported = count
                    with temporary.open("ab" if count else "wb") as stream:
                        for chunk in response.iter_bytes(1024 * 1024):
                            if count + len(chunk) > size:
                                raise ValueError("Download exceeds signed size")
                            stream.write(chunk)
                            count += len(chunk)
                            if count - reported >= 64 * 1024**2:
                                progress("Downloading", destination.name, count, size)
                                reported = count
                if count != size:
                    raise httpx.RemoteProtocolError("Download ended before the signed size")
            with temporary.open("rb") as stream:
                actual = hashlib.file_digest(stream, "sha256").hexdigest()
            if actual != digest:
                raise ValueError("Downloaded file does not match signed SHA-256")
            temporary.replace(destination)
            progress("Downloaded and verified", destination.name, size, size)
            return
        except (httpx.HTTPError, OSError, ValueError) as exc:
            status = response.status_code if response is not None else None
            details = {
                "vm": vm_name,
                "file": destination.name,
                "host": urlsplit(url).hostname,
                "attempt": attempt,
                "bytes_transferred": count,
                "total_bytes": size,
                "http_status": status,
                "exception_type": type(exc).__name__,
            }
            reason = f"HTTP {status}" if isinstance(exc, httpx.HTTPStatusError) else str(exc)
            reason = reason or type(exc).__name__
            details["error"] = reason
            retryable = isinstance(exc, httpx.TransportError) or (
                isinstance(exc, httpx.HTTPStatusError) and status in {429, 500, 502, 503, 504}
            )
            if retryable:
                network_recovery.recover(time.monotonic(), context={"vm": vm_name})
            if not retryable or attempt == 2:
                raise WorkflowError(
                    "automation.local_filepool.download",
                    f"Local filepool download failed for {destination.name}: {reason}",
                    details=details,
                ) from exc
            result.ok(
                "automation.local_filepool.retry",
                f"Retrying {destination.name} (attempt 2/2) from {count} bytes: {reason}",
                **details,
            )
            time.sleep(3)


def prepare_local_filepool(validation, vm, executable: PureWindowsPath, result) -> None:
    settings = validation.settings
    repository = Path(__file__).resolve().parents[3]
    base = settings.published_dev_metadata_base_url.rstrip("/") + "/"
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

    with httpx.Client(follow_redirects=True, timeout=60) as client:
        catalog_bytes = _download_bytes(client, base + "catalog.json", MAXIMUM_METADATA_BYTES)
        signature = _download_bytes(client, base + "catalog.json.sig", MAXIMUM_SIGNATURE_BYTES)
        _load_public_key(repository / "Scripts/config/Libertix.CatalogPublicKey.xml").verify(
            base64.b64decode(signature.strip(), validate=True),
            catalog_bytes,
            padding.PKCS1v15(),
            hashes.SHA256(),
        )
        artifacts = catalog_artifacts(json.loads(catalog_bytes))
        cache = settings.runtime_dir / "local-filepool" / hashlib.sha256(catalog_bytes).hexdigest()
        cache.mkdir(parents=True, exist_ok=True)
        paths = [cache / "catalog.json", cache / "catalog.json.sig"]
        paths[0].write_bytes(catalog_bytes)
        paths[1].write_bytes(signature)
        for item in artifacts:
            name, size, digest = item["fileName"], item["sizeBytes"], item["sha256"].lower()
            selected = None
            for candidate in (repository / "auto_tests/app/filepool" / name, cache / name):
                if (
                    candidate.is_file()
                    and not candidate.is_symlink()
                    and candidate.stat().st_size == size
                ):
                    with candidate.open("rb") as stream:
                        if hashlib.file_digest(stream, "sha256").hexdigest() == digest:
                            selected = candidate
                            progress("Verified cached", name, size, size)
                            break
            if selected is None:
                url = urljoin(base, item["url"])
                parsed = urlsplit(url)
                if (
                    parsed.scheme != "https"
                    or not parsed.hostname
                    or parsed.username
                    or parsed.password
                ):
                    raise ValueError("Signed artifacts must use HTTPS without credentials")
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
                timeout=30,
            )
            for path in paths:
                reported = 0
                progress("Copying to VM", path.name, 0, path.stat().st_size)

                def upload_progress(done, total, *, name=path.name):
                    nonlocal reported
                    if done == total or done - reported >= 64 * 1024**2:
                        progress("Copying to VM", name, done, total)
                        reported = done

                ssh.upload_file(
                    path,
                    str(destination / path.name),
                    step="automation.local_filepool.copy",
                    on_progress=upload_progress,
                )
    result.ok(
        "automation.local_filepool.prepared",
        "Signed catalog and all artifacts copied beside Libertix.exe",
        vm=vm.name,
        directory=str(destination),
        files=[path.name for path in paths],
        catalog_sha256=hashlib.sha256(catalog_bytes).hexdigest(),
        metadata_url=base,
    )
