from __future__ import annotations

import json
import re
from dataclasses import dataclass
from pathlib import Path

from app.errors import WorkflowError

_IDENTIFIER = re.compile(r"^[a-z0-9](?:[a-z0-9._-]{0,62}[a-z0-9])?$")
_GRUB_LABEL = re.compile(r"^[A-Za-z0-9][A-Za-z0-9 ._()+-]{0,79}$")


@dataclass(frozen=True)
class DistributionProfile:
    id: str
    name: str
    os_release_id: str
    grub_display_name: str
    grub_icon: str
    installer_iso_file_name: str
    catalog_index: int


def load_distribution_profile(distribution_id: str) -> DistributionProfile:
    catalog_path = Path(__file__).resolve().parent / "filepool" / "distros.json"
    try:
        catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise WorkflowError(
            "automation.distribution_catalog",
            "The source distribution catalog could not be loaded",
            details={"path": str(catalog_path), "error": str(exc)},
        ) from exc

    if not isinstance(catalog, list):
        raise WorkflowError(
            "automation.distribution_catalog",
            "The source distribution catalog is not a JSON array",
            details={"path": str(catalog_path)},
        )

    matches: list[DistributionProfile] = []
    for index, entry in enumerate(catalog):
        if not isinstance(entry, dict) or entry.get("id") != distribution_id:
            continue
        values = {
            "id": entry.get("id"),
            "name": entry.get("name"),
            "os_release_id": entry.get("osReleaseId"),
            "grub_display_name": entry.get("grubDisplayName"),
            "grub_icon": entry.get("grubIcon"),
            "installer_iso_file_name": entry.get("isoInstallerFileName"),
        }
        if (
            not isinstance(values["id"], str)
            or not _IDENTIFIER.fullmatch(values["id"])
            or not isinstance(values["name"], str)
            or not values["name"].strip()
            or not isinstance(values["os_release_id"], str)
            or not _IDENTIFIER.fullmatch(values["os_release_id"])
            or not isinstance(values["grub_display_name"], str)
            or not _GRUB_LABEL.fullmatch(values["grub_display_name"])
            or not isinstance(values["grub_icon"], str)
            or not _IDENTIFIER.fullmatch(values["grub_icon"])
            or not isinstance(values["installer_iso_file_name"], str)
            or not values["installer_iso_file_name"]
            or "/" in values["installer_iso_file_name"]
            or "\\" in values["installer_iso_file_name"]
        ):
            raise WorkflowError(
                "automation.distribution_catalog",
                "The selected distribution has invalid automation metadata",
                details={"path": str(catalog_path), "distribution": distribution_id},
            )
        matches.append(DistributionProfile(catalog_index=index, **values))

    if len(matches) != 1:
        raise WorkflowError(
            "automation.distribution_catalog",
            "The requested distribution must occur exactly once in the source catalog",
            details={
                "path": str(catalog_path),
                "distribution": distribution_id,
                "matches": len(matches),
            },
        )
    return matches[0]
