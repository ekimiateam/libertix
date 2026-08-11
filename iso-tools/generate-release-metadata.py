#!/usr/bin/env python3
"""Generate channel metadata from one release configuration and built artifacts."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import UTC, datetime
from pathlib import Path
from urllib.parse import quote

REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CONFIG = REPOSITORY_ROOT / "release-config.json"
REPOSITORY_URL = "https://github.com/ekimiateam/libertix"
RELEASE_DOWNLOAD_BASE = REPOSITORY_URL + "/releases/download"
SHA7_PATTERN = re.compile(r"^[0-9a-f]{7}$")
VERSION_PATTERN = re.compile(r"^(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){1,2}(?:-[0-9A-Za-z.-]+)?$")
HEX_SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
IDENTIFIER_PATTERN = re.compile(r"^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$")
GRUB_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$")
ISO_FILE_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\.iso$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _require_string(value: object, name: str, *, maximum: int) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > maximum:
        raise ValueError(f"{name} must be a non-empty string of at most {maximum} characters")
    return value


def load_config(path: Path) -> dict[str, object]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or set(data) != {
        "schemaVersion",
        "mainRelease",
        "distributions",
    }:
        raise ValueError(
            "release config must contain only schemaVersion, mainRelease and distributions"
        )
    if data["schemaVersion"] != 1:
        raise ValueError("unsupported release config schemaVersion")

    main_release = data["mainRelease"]
    if not isinstance(main_release, dict) or set(main_release) != {
        "version",
        "title",
        "notes",
    }:
        raise ValueError("mainRelease must contain only version, title and notes")
    version = _require_string(main_release["version"], "mainRelease.version", maximum=64)
    if not VERSION_PATTERN.fullmatch(version):
        raise ValueError("mainRelease.version is not a supported release version")
    _require_string(main_release["title"], "mainRelease.title", maximum=120)
    _require_string(main_release["notes"], "mainRelease.notes", maximum=10000)

    distributions = data["distributions"]
    if not isinstance(distributions, list) or not distributions:
        raise ValueError("distributions must contain at least one entry")
    expected_keys = {
        "id",
        "name",
        "osReleaseId",
        "grubDisplayName",
        "grubIcon",
        "secureBootMicrosoftAuthorities",
        "description",
        "imageUrl",
        "isoInstaller",
        "isoInstallerFileName",
        "isoInstallerSha256",
        "isoInstallerSizeBytes",
        "sizeInGB",
    }
    seen_ids: set[str] = set()
    for index, distribution in enumerate(distributions):
        prefix = f"distributions[{index}]"
        if not isinstance(distribution, dict) or set(distribution) != expected_keys:
            raise ValueError(f"{prefix} has missing or unknown properties")
        distro_id = _require_string(distribution["id"], f"{prefix}.id", maximum=64)
        if not IDENTIFIER_PATTERN.fullmatch(distro_id) or distro_id in seen_ids:
            raise ValueError(f"{prefix}.id is invalid or duplicated")
        seen_ids.add(distro_id)
        for key, maximum in (
            ("name", 120),
            ("description", 1000),
            ("imageUrl", 2048),
            ("isoInstaller", 2048),
        ):
            _require_string(distribution[key], f"{prefix}.{key}", maximum=maximum)
        if not str(distribution["imageUrl"]).startswith("https://"):
            raise ValueError(f"{prefix}.imageUrl must use HTTPS")
        if not str(distribution["isoInstaller"]).startswith("https://"):
            raise ValueError(f"{prefix}.isoInstaller must use HTTPS")
        for key in ("osReleaseId", "grubIcon"):
            value = _require_string(distribution[key], f"{prefix}.{key}", maximum=64)
            if not IDENTIFIER_PATTERN.fullmatch(value):
                raise ValueError(f"{prefix}.{key} is invalid")
        grub_name = _require_string(
            distribution["grubDisplayName"], f"{prefix}.grubDisplayName", maximum=80
        )
        if not GRUB_NAME_PATTERN.fullmatch(grub_name):
            raise ValueError(f"{prefix}.grubDisplayName is invalid")
        authorities = distribution["secureBootMicrosoftAuthorities"]
        if (
            not isinstance(authorities, list)
            or not authorities
            or len(authorities) != len(set(authorities))
            or any(authority not in {"2011", "2023"} for authority in authorities)
        ):
            raise ValueError(
                f"{prefix}.secureBootMicrosoftAuthorities must contain unique 2011/2023 values"
            )
        filename = _require_string(
            distribution["isoInstallerFileName"],
            f"{prefix}.isoInstallerFileName",
            maximum=132,
        )
        if not ISO_FILE_PATTERN.fullmatch(filename):
            raise ValueError(f"{prefix}.isoInstallerFileName is invalid")
        if not isinstance(
            distribution["isoInstallerSha256"], str
        ) or not HEX_SHA256_PATTERN.fullmatch(distribution["isoInstallerSha256"]):
            raise ValueError(f"{prefix}.isoInstallerSha256 is invalid")
        if (
            not isinstance(distribution["isoInstallerSizeBytes"], int)
            or distribution["isoInstallerSizeBytes"] <= 0
        ):
            raise ValueError(f"{prefix}.isoInstallerSizeBytes must be positive")
        if not isinstance(distribution["sizeInGB"], (int, float)) or distribution["sizeInGB"] < 20:
            raise ValueError(f"{prefix}.sizeInGB must be at least 20")
    return data


def _artifact(path: Path, url: str) -> dict[str, object]:
    resolved = path.resolve(strict=True)
    if not resolved.is_file() or resolved.stat().st_size <= 0:
        raise ValueError(f"release artifact is missing or empty: {path}")
    return {
        "url": url,
        "sha256": sha256(resolved),
        "sizeBytes": resolved.stat().st_size,
    }


def generate_metadata(
    config: dict[str, object],
    *,
    channel: str,
    tag: str,
    commit: str,
    bios_iso: Path,
    uefi_iso: Path,
    wpf_zip: Path,
    aria2_archive: Path,
    ext4_driver: Path,
    grub4dos_loader: Path,
    grub4dos_mbr: Path,
    published_at: str,
) -> tuple[dict[str, object], dict[str, object]]:
    if channel not in {"dev", "main"}:
        raise ValueError("channel must be dev or main")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise ValueError("commit must be a lowercase 40-character Git SHA")
    main_release = config["mainRelease"]
    assert isinstance(main_release, dict)
    if channel == "dev":
        if not SHA7_PATTERN.fullmatch(tag) or not commit.startswith(tag):
            raise ValueError("dev tag must be the seven-character prefix of commit")
        build_version = f"dev_{tag}"
        title = f"Alpha {tag}"
        notes = f"Automated Libertix alpha build for commit {tag}."
    else:
        if tag != main_release["version"]:
            raise ValueError("main tag must match mainRelease.version")
        build_version = tag
        title = str(main_release["title"])
        notes = str(main_release["notes"])

    encoded_tag = quote(tag, safe="")
    release_url = f"{REPOSITORY_URL}/releases/tag/{encoded_tag}"
    download_base = f"{RELEASE_DOWNLOAD_BASE}/{encoded_tag}"
    bios = _artifact(bios_iso, f"{download_base}/libertix-installer-bios.iso")
    bios["fileName"] = "libertix-installer-bios.iso"
    uefi = _artifact(uefi_iso, f"{download_base}/libertix-installer-uefi.iso")
    uefi["fileName"] = "libertix-installer-uefi.iso"
    wpf = _artifact(wpf_zip, f"{download_base}/Libertix-wpf.zip")
    wpf["fileName"] = "Libertix-wpf.zip"

    configured_distributions = config["distributions"]
    assert isinstance(configured_distributions, list)
    distributions = [dict(source) for source in configured_distributions]

    def support_artifact(path: Path, file_name: str) -> dict[str, object]:
        artifact = _artifact(path, file_name)
        artifact["fileName"] = file_name
        return artifact

    catalog = {
        "schemaVersion": 1,
        "artifacts": {
            "wpf": wpf,
            "miniIso": {"bios": bios, "uefi": uefi},
            "support": {
                "aria2Archive": support_artifact(aria2_archive, "aria2-64.zip"),
                "ext4Driver": support_artifact(ext4_driver, "ext4-win-driver.exe"),
                "grub4DosLoader": support_artifact(grub4dos_loader, "grldr"),
                "grub4DosMbr": support_artifact(grub4dos_mbr, "grldr.mbr"),
            },
        },
        "distributions": distributions,
    }

    releases = {
        "schemaVersion": 1,
        "channel": channel,
        "latest": {
            "version": build_version,
            "tag": tag,
            "commit": commit,
            "title": title,
            "notes": notes,
            "publishedAt": published_at,
            "releaseUrl": release_url,
            "wpf": wpf,
            "miniIso": {"bios": bios, "uefi": uefi},
        },
    }
    return catalog, releases


def write_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(
        json.dumps(value, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG)
    parser.add_argument("--channel", choices=("dev", "main"), required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--bios-iso", type=Path, required=True)
    parser.add_argument("--uefi-iso", type=Path, required=True)
    parser.add_argument("--wpf-zip", type=Path, required=True)
    parser.add_argument("--aria2-archive", type=Path, required=True)
    parser.add_argument("--ext4-driver", type=Path, required=True)
    parser.add_argument("--grub4dos-loader", type=Path, required=True)
    parser.add_argument("--grub4dos-mbr", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--published-at")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    published_at = args.published_at or datetime.now(UTC).isoformat().replace("+00:00", "Z")
    config = load_config(args.config)
    catalog, releases = generate_metadata(
        config,
        channel=args.channel,
        tag=args.tag,
        commit=args.commit.lower(),
        bios_iso=args.bios_iso,
        uefi_iso=args.uefi_iso,
        wpf_zip=args.wpf_zip,
        aria2_archive=args.aria2_archive,
        ext4_driver=args.ext4_driver,
        grub4dos_loader=args.grub4dos_loader,
        grub4dos_mbr=args.grub4dos_mbr,
        published_at=published_at,
    )
    write_json(args.output_dir / "catalog.json", catalog)
    write_json(args.output_dir / "releases.json", releases)


if __name__ == "__main__":
    main()
