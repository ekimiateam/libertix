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
    text = content.lower()
    reboot_button = "redemarrer" in text or "redémarrer" in text
    final_state = any(
        marker in text
        for marker in (
            "partitionnement termine",
            "partitionnement terminé",
            "next reboot will automatically boot",
            "boot entry configured",
            "grub4dos installed",
        )
    )
    return reboot_button and final_state and re.search(r"\b100\s*%", text) is not None


def contains_wizard_blocker(content: str) -> bool:
    text = content.casefold()
    return any(
        marker in text
        for marker in (
            "compat_e_",
            "une erreur s'est produite",
            "une erreur s’est produite",
            "installation bloquée",
            "installation bloquee",
            "champ invalide",
            "passwords do not match",
            "les mots de passe ne correspondent pas",
        )
    )


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
        marker in text for marker in ("downloading", "télécharg", "linux iso", "mint.iso")
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


def contains_live_install_success(content: str) -> bool:
    text = content.lower()
    return any(
        marker in text
        for marker in (
            "installer-success",
            "installation terminée et vérifiée",
            "installation terminee et verifiee",
            "libertix_install_success=true",
        )
    )


class VisionVerdict(BaseModel):
    no_visible_problem: bool
    libertix_running: bool
    welcome_message_ok: bool
    summary: str = Field(min_length=1)
    visible_problems: list[str]

    @property
    def valid(self) -> bool:
        return self.no_visible_problem and self.libertix_running and self.welcome_message_ok


class InstallProgressVerdict(BaseModel):
    iso_download_finished: bool
    installation_finished: bool
    reboot_prompt_visible: bool
    still_in_progress: bool
    error_visible: bool
    summary: str = Field(min_length=1)
    visible_text: str
    analysis_source: Literal["strict_json", "reasoning_json", "reasoning_fallback"] = "strict_json"

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


class WizardStateVerdict(BaseModel):
    detected_screen: Literal[
        "welcome",
        "compatibility",
        "distro",
        "resize",
        "sharing",
        "account",
        "warning",
        "apply",
        "other",
    ]
    expected_screen_visible: bool
    no_blocking_error: bool
    username_visible: bool
    password_fields_filled: bool
    summary: str = Field(min_length=1)
    visible_text: str
