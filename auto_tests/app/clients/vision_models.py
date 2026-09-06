from __future__ import annotations

import re
from typing import Literal

from pydantic import BaseModel, Field


def contains_install_blocker(content: str) -> bool:
    text = content.lower()
    return any(
        marker in text
        for marker in (
            "espace insuffisant",
            "insufficient space",
            "additional space needed",
            "size cannot exceed",
            "failed to download",
            "failed to obtain",
            "impossible de télécharger",
            "impossible de charger",
            "no iso url found",
            "failed to copy iso",
            "installation échouée",
            "installation echouee",
            "installer-failed",
        )
    )


def contains_final_reboot_prompt(content: str) -> bool:
    text = content.casefold()
    reboot_button = any(
        marker in text for marker in ("redemarrer", "redémarrer", "reboot", "restart", "reiniciar")
    )
    final_state = any(
        marker in text
        for marker in (
            "partitionnement termine",
            "partitionnement terminé",
            "partitioning complete",
            "particionamiento completado",
            "uefi preparation complete",
            "préparation uefi terminée",
            "preparación uefi completada",
            "next reboot will automatically boot",
            "boot entry configured",
            "grub4dos installed",
        )
    )
    return reboot_button and final_state and re.search(r"\b100\s*%", text) is not None


def contains_active_install_progress(content: str) -> bool:
    if contains_final_reboot_prompt(content):
        return False
    text = content.lower()
    progress_pattern = (
        r"\b(downloading|copying|extracting|copie|téléchargement).{0,80}"
        r"\b[0-9]{1,2}\s*%"
    )
    if re.search(progress_pattern, text):
        return True
    if re.search(r"\b[0-9][0-9\s]*/[0-9][0-9\s]*\s*mb\b", text) and any(
        marker in text for marker in ("downloading", "télécharg", "linux iso", ".iso")
    ):
        return True
    if any(
        marker in text
        for marker in (
            "decryptioninprogress",
            "decryption in progress",
            "décryptage en cours",
            "dechiffrement de windows",
            "déchiffrement de windows",
            "waiting for c: decryption",
        )
    ):
        return True
    return any(
        marker in text
        for marker in (
            "copying iso contents",
            "mounting iso and copying",
            "extracting system",
            "stage: 120-unsquashfs",
            "stage: 130-target-system-config",
            "extraction de mint",
            "configuration du systeme installe",
            "configuration du système installé",
        )
    )


class InstallProgressVerdict(BaseModel):
    iso_download_finished: bool
    installation_finished: bool
    reboot_prompt_visible: bool
    still_in_progress: bool
    error_visible: bool
    summary: str = Field(min_length=1)
    visible_text: str
    analysis_source: Literal["strict_json"] = "strict_json"

    @property
    def done(self) -> bool:
        return (
            self.iso_download_finished or self.installation_finished or self.reboot_prompt_visible
        )

    @property
    def blocking_problem_visible(self) -> bool:
        return contains_install_blocker(f"{self.summary}\n{self.visible_text}")

    @property
    def active_install_progress_visible(self) -> bool:
        return contains_active_install_progress(f"{self.summary}\n{self.visible_text}")
