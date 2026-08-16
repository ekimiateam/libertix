from __future__ import annotations

import importlib.util
import json
import os
import re
import subprocess
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]
CATALOGUE_PATH = ROOT / "Resources/Libertix.Translations.json"
LANGUAGES = ("en", "fr", "es")


def translation_catalogue() -> dict[str, object]:
    return json.loads(CATALOGUE_PATH.read_text(encoding="utf-8"))


def language_section(language: str, section: str) -> dict[str, str]:
    return translation_catalogue()["languages"][language][section]


def load_i18n_module() -> ModuleType:
    path = ROOT / "assets/live/libertix-i18n.py"
    spec = importlib.util.spec_from_file_location("libertix_i18n_tests", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load live translation helper: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resource_keys(language: str) -> set[str]:
    return set(language_section(language, "wpf"))


def test_translation_catalogue_is_the_single_runtime_source() -> None:
    catalogue = translation_catalogue()
    project = (ROOT / "Libertix.csproj").read_text(encoding="utf-8-sig")
    runtime_sources = "\n".join(
        (ROOT / relative).read_text(encoding="utf-8-sig")
        for relative in (
            "Localization.cs",
            "Scripts/libertix-compatibility-preflight.ps1",
            "Scripts/libertix-post-install-result.ps1",
            "assets/live/libertix-i18n.py",
            "assets/live/libertix-first-boot-result.py",
            "grub/render-libertix-menu.py",
            "iso-tools/build-iso.sh",
        )
    )

    assert catalogue["schemaVersion"] == 1
    assert catalogue["supportedLanguages"] == list(LANGUAGES)
    assert set(catalogue["languages"]) == set(LANGUAGES)
    assert 'Content Include="Resources\\Libertix.Translations.json"' in project
    assert "Strings.en.xaml" not in project
    assert "Libertix.CompatibilityMessages.json" not in runtime_sources
    assert "Libertix.PostInstallTranslations.json" not in runtime_sources
    assert "libertix-translations.json" not in runtime_sources
    assert runtime_sources.count("Libertix.Translations.json") >= 7


def test_supported_language_metadata_is_complete_and_exact() -> None:
    catalogue = translation_catalogue()
    expected = {
        "en": ("English", "en_US.UTF-8", "us"),
        "fr": ("Français", "fr_FR.UTF-8", "fr"),
        "es": ("Español", "es_ES.UTF-8", "es"),
    }
    for language, values in expected.items():
        entry = catalogue["languages"][language]
        assert (entry["displayName"], entry["linuxLocale"], entry["keyboardLayout"]) == values


def test_every_translation_section_has_key_and_placeholder_parity() -> None:
    catalogue = translation_catalogue()
    sections = ("wpf", "live", "postInstall", "firstBoot", "grub")
    for section in sections:
        english = catalogue["languages"]["en"][section]
        for language in LANGUAGES:
            translated = catalogue["languages"][language][section]
            assert set(translated) == set(english), f"{language}:{section}"
            for key, english_value in english.items():
                expected = set(re.findall(r"\{[A-Za-z0-9_]+(?::[^}]*)?\}", english_value))
                actual = set(re.findall(r"\{[A-Za-z0-9_]+(?::[^}]*)?\}", translated[key]))
                assert actual == expected, f"{language}:{section}:{key}"


def test_about_page_is_built_and_reachable_from_welcome() -> None:
    project = (ROOT / "Libertix.csproj").read_text(encoding="utf-8-sig")
    welcome = (ROOT / "Pages/Welcome.xaml").read_text(encoding="utf-8-sig")
    code_behind = (ROOT / "MainWindow.xaml.cs").read_text(encoding="utf-8-sig")
    about = (ROOT / "Pages/About.xaml").read_text(encoding="utf-8-sig")

    assert '<Page Include="Pages\\About.xaml" />' in project
    assert '<Compile Include="Pages\\About.xaml.cs">' in project
    assert '<Page Include="Pages\\Welcome.xaml" />' in project
    assert '<Compile Include="Pages\\Welcome.xaml.cs">' in project
    assert 'Click="About_Click"' in welcome
    assert "new About()" in code_behind
    assert "https://ekimia.fr/libertix/" in about
    assert "https://ekimia.fr/donations/campagne-libertix/" in about
    assert "https://github.com/ekimiateam/libertix" in about


def test_returning_from_about_creates_a_fresh_welcome_navigation_root() -> None:
    code_behind = (ROOT / "MainWindow.xaml.cs").read_text(encoding="utf-8-sig")
    return_to_welcome = code_behind.split("public void ReturnToWelcome()", 1)[1].split(
        "private Welcome CreateWelcomePage", 1
    )[0]

    assert "CreateWelcomePage()" in return_to_welcome
    assert "navigation.RemoveBackEntry()" in return_to_welcome
    assert "GoBack()" not in return_to_welcome
    assert "_welcomeContent" not in code_behind
    assert "return new Welcome(" in code_behind


def test_all_wpf_languages_contain_the_same_about_resources() -> None:
    expected_about_keys = {
        "AboutButton",
        "AboutTitle",
        "AboutSubtitle",
        "AboutProjectHeading",
        "AboutProjectBody",
        "AboutDevelopersHeading",
        "AboutDevelopersBody",
        "AboutDonorsHeading",
        "AboutDonorsBody",
        "AboutWebsiteButton",
        "AboutDonateButton",
        "AboutLinkError",
    }
    keys_by_language = {language: resource_keys(language) for language in LANGUAGES}

    assert all(expected_about_keys <= keys for keys in keys_by_language.values())
    assert len({frozenset(keys) for keys in keys_by_language.values()}) == 1


def test_public_credits_are_present_in_every_wpf_language() -> None:
    required_names = ("felix068", "Michel Memeteau", "MopigamesYT", "Aamir Shahzad")
    required_donors = ("Olivier", "Boyka", "Coin des Geeks", "Matthieu")

    for language in LANGUAGES:
        content = "\n".join(language_section(language, "wpf").values())
        for name in (*required_names, *required_donors):
            assert name in content


def test_live_translation_catalogues_have_identical_keys() -> None:
    catalogue = translation_catalogue()
    live = {language: catalogue["languages"][language]["live"] for language in LANGUAGES}

    assert catalogue["supportedLanguages"] == list(LANGUAGES)
    assert set(catalogue["languages"]) == set(LANGUAGES)
    assert len({frozenset(entries) for entries in live.values()}) == 1
    assert all(live[language] for language in LANGUAGES)


def test_post_install_result_catalogues_are_complete_and_parallel() -> None:
    catalogues = {language: language_section(language, "postInstall") for language in LANGUAGES}

    assert set(catalogues) == set(LANGUAGES)
    expected = set(catalogues["en"])
    assert expected == {
        "successTitle",
        "successMessage",
        "waitingTitle",
        "waitingMessage",
        "waitingAdvice",
        "failureTitle",
        "failureMessage",
        "details",
        "statusLabel",
        "planLabel",
        "logLabel",
        "checkPassedLabel",
        "checkFailedLabel",
        "errorLabel",
        "close",
        "rollback",
        "rollbackConfirmTitle",
        "rollbackConfirmMessage",
        "rollbackRunning",
        "rollbackComplete",
        "rollbackFailed",
    }
    for language, values in catalogues.items():
        assert set(values) == expected, language
        assert all(isinstance(value, str) and value.strip() for value in values.values())


def test_linux_extraction_labels_are_concise_in_every_language() -> None:
    expected = {
        "en": ("Extracting the Linux system", "Extracting the Linux system:"),
        "fr": ("Extraction du système Linux", "Extraction du système Linux :"),
        "es": ("Extrayendo el sistema Linux", "Extrayendo el sistema Linux:"),
    }

    for language, (label, progress_prefix) in expected.items():
        live = language_section(language, "live")
        assert live["stage_120_unsquashfs"] == label
        assert live["extraction_progress"].startswith(progress_prefix)


def test_compatibility_message_catalogue_has_language_and_key_parity() -> None:
    catalogue = translation_catalogue()
    compatibility = {
        language: catalogue["languages"][language]["compatibility"] for language in LANGUAGES
    }

    assert all(
        set(values)
        == {
            "checkMessages",
            "warningMessages",
            "errorMessages",
            "bootstrapMessages",
        }
        for values in compatibility.values()
    )
    for section_name in compatibility["en"]:
        sections = [compatibility[language][section_name] for language in LANGUAGES]
        assert len({frozenset(entries) for entries in sections}) == 1
        assert all(sections)

    assert {
        "AdministratorRequired",
        "SingleInstanceRequired",
        "InvalidStartupOptionsTitle",
        "InvalidStartupOptionsMessage",
    } <= set(compatibility["en"]["bootstrapMessages"])

    script = (ROOT / "Scripts/libertix-compatibility-preflight.ps1").read_text(encoding="utf-8-sig")
    assert "Libertix.Translations.json" in script
    assert "$checkMessages = @{" not in script
    assert "$warningMessages = @{" not in script
    assert "$errorMessages = @{" not in script


@pytest.mark.parametrize("language", LANGUAGES)
def test_live_translation_helper_loads_every_supported_language(language: str) -> None:
    module = load_i18n_module()
    translations = module.load_catalogue(language)

    assert translations["stage_120_unsquashfs"]
    assert translations["installation_success"]


@pytest.mark.parametrize(
    ("language", "expected_title"),
    (
        ("en", "Automatic installation"),
        ("fr", "Installation automatique"),
        ("es", "Instalación automática"),
    ),
)
def test_live_context_retry_preserves_language_exports(
    tmp_path: Path,
    language: str,
    expected_title: str,
) -> None:
    error_file = tmp_path / "context-load-error"
    command = r"""
set -eu
. "$LIVE_CONTEXT"
. "$LIVE_I18N"
load_libertix_live_context() {
    export LANGUAGE_CODE="$TEST_LANGUAGE"
    export SYSTEM_LANG="${TEST_LANGUAGE}_TEST.UTF-8"
}
load_libertix_live_context_with_retry bios 1 "$ERROR_FILE"
load_libertix_translations "$I18N_HELPER"
printf '%s\n' "$LANGUAGE_CODE"
printf '%s\n' "$LIBERTIX_I18N_AUTOMATIC_INSTALLATION"
"""
    environment = os.environ.copy()
    environment.update(
        {
            "LIVE_CONTEXT": str(ROOT / "assets/live/libertix-live-context.sh"),
            "LIVE_I18N": str(ROOT / "assets/live/libertix-i18n.sh"),
            "I18N_HELPER": str(ROOT / "assets/live/libertix-i18n.py"),
            "ERROR_FILE": str(error_file),
            "TEST_LANGUAGE": language,
        }
    )
    result = subprocess.run(
        ["bash", "-c", command],
        check=True,
        capture_output=True,
        text=True,
        env=environment,
    )

    assert result.stdout.splitlines() == [language, expected_title]


def test_bios_and_uefi_project_the_language_code_to_the_live() -> None:
    bios = (ROOT / "Pages/ApplyChanges.Plan.cs").read_text(encoding="utf-8-sig")
    plan_exporter = (ROOT / "assets/live/libertix-installation-plan.py").read_text(
        encoding="utf-8-sig"
    )
    target = (ROOT / "assets/live/libertix-target-common.sh").read_text(encoding="utf-8-sig")

    assert "LanguageCode = Localization.CurrentLanguage" in bios
    assert '"LANGUAGE_CODE": locale["languageCode"]' in plan_exporter
    assert 'LANGUAGE_CODE="$LANGUAGE_CODE"' in target


def test_english_live_ui_contains_no_french_fallback_text() -> None:
    ui_sources = "\n".join(
        (ROOT / relative).read_text(encoding="utf-8-sig")
        for relative in (
            "assets/live/libertix-gui.py",
            "iso/live/libertix-runner.sh",
            "iso-uefi/live/libertix-runner.sh",
            "assets/live/libertix-runner-stage-common.sh",
        )
    )
    forbidden = (
        "Etape:",
        "Action en cours",
        "Derniers evenements",
        "Plus de details",
        "Installation terminee",
        "Redemarrage automatique",
        "Installation echouee",
    )

    assert all(text not in ui_sources for text in forbidden)

    module = load_i18n_module()
    english = module.load_catalogue("en")
    assert english["step"] == "Stage:"
    assert english["installation_success"] == "Installation completed and verified."


def test_compatibility_preflight_uses_the_selected_language() -> None:
    runner = (ROOT / "Helpers/CompatibilityPreflightRunner.cs").read_text(encoding="utf-8-sig")
    script = (ROOT / "Scripts/libertix-compatibility-preflight.ps1").read_text(encoding="utf-8-sig")
    messages = language_section("en", "compatibility")

    assert "string languageCode = Localization.CurrentLanguage" in runner
    assert '" -LanguageCode " +' in runner
    assert "WindowsProcessRunner.QuoteArgument(languageCode)" in runner
    assert '[ValidateSet("en", "fr", "es")]' in script
    assert messages["checkMessages"]["COMPAT_010_PRIVILEGES"] == (
        "Checking administrator privileges"
    )
    assert messages["checkMessages"]["COMPAT_050_FILESYSTEM"] == (
        "Checking NTFS, BitLocker, and shrinkable space"
    )
    assert messages["warningMessages"]["BITLOCKER"].startswith("BitLocker is active;")
    assert 'Write-Check "COMPAT_010_PRIVILEGES"' in script
    assert 'Write-Check "COMPAT_050_FILESYSTEM"' in script
    assert 'Write-LocalizedWarning "BITLOCKER"' in script


def test_apply_changes_runtime_messages_are_translated_in_every_language() -> None:
    required_keys = {
        "ConfirmationYes",
        "ConfirmationNo",
        "ApplyChangesPreparingWindowsShare",
        "WindowsShareShortcutDescription",
        "ApplyChangesPreparingUefi",
        "ApplyChangesCheckingSecureBoot",
        "ApplyChangesDecryptingWindowsInit",
        "ApplyChangesWindowsDecrypted",
        "ApplyChangesDecryptingWindowsPercent",
        "ApplyChangesDownloading",
        "ApplyChangesDownloadingIso",
        "ApplyChangesDownloadingLinuxIso",
        "ApplyChangesDownloadingDistribution",
        "ApplyChangesDistributionReady",
        "ApplyChangesDownloadingUefiIso",
        "ApplyChangesRollbackInProgress",
        "ApplyChangesCancelledRestored",
        "ApplyChangesErrorRollback",
        "ApplyChangesRollbackIncomplete",
        "ApplyChangesBitLockerReenable",
        "ApplyChangesBitLockerReenableDetails",
        "ApplyChangesBitLockerReenableTitle",
    }

    assert all(required_keys <= resource_keys(language) for language in LANGUAGES)


def test_every_csharp_localization_reference_exists_in_every_language() -> None:
    patterns = (
        re.compile(r'\bLocalized(?:Format)?\(\s*"([A-Za-z0-9_.-]+)"'),
        re.compile(r'\bLocalization\.GetString\(\s*"([A-Za-z0-9_.-]+)"'),
    )
    referenced_keys: set[str] = set()
    for source in ROOT.rglob("*.cs"):
        if any(part in {"bin", "obj", ".work", "runtime"} for part in source.parts):
            continue
        content = source.read_text(encoding="utf-8-sig")
        for pattern in patterns:
            referenced_keys.update(pattern.findall(content))

    assert referenced_keys
    assert all(referenced_keys <= resource_keys(language) for language in LANGUAGES)


def test_wpf_translation_placeholders_match_in_every_language() -> None:
    values_by_language = {language: language_section(language, "wpf") for language in LANGUAGES}

    for key, english_value in values_by_language["en"].items():
        expected = set(re.findall(r"\{\d+(?::[^}]*)?\}", english_value))
        for language in LANGUAGES:
            actual = set(re.findall(r"\{\d+(?::[^}]*)?\}", values_by_language[language][key]))
            assert actual == expected, f"{language}:{key} has mismatched format placeholders"


def test_insufficient_disk_space_panel_is_translated() -> None:
    required_keys = {
        "ErrorPanelSystemRequirements",
        "NotEnoughSpace",
        "FreeUpSpace",
        "ResizeDiskAdditionalSpace",
    }

    assert all(required_keys <= resource_keys(language) for language in LANGUAGES)


def test_confirmations_use_libertix_language_instead_of_windows_button_captions() -> None:
    project = (ROOT / "Libertix.csproj").read_text(encoding="utf-8-sig")
    dialog = (ROOT / "Dialogs/LocalizedConfirmationDialog.xaml").read_text(encoding="utf-8-sig")
    sources = "\n".join(
        (ROOT / relative).read_text(encoding="utf-8-sig")
        for relative in (
            "MainWindow.xaml.cs",
            "Pages/ApplyChanges.xaml.cs",
            "Pages/ApplyChanges.Cancellation.cs",
        )
    )

    assert '<Page Include="Dialogs\\LocalizedConfirmationDialog.xaml" />' in project
    assert 'x:Name="YesButton"' in dialog
    assert 'x:Name="NoButton"' in dialog
    assert sources.count("LocalizedConfirmationDialog.Show(") == 3
    assert "MessageBoxButton.YesNo" not in sources


def test_bcdedit_output_is_decoded_with_the_windows_oem_code_page() -> None:
    system = (ROOT / "Pages/ApplyChanges.System.cs").read_text(encoding="utf-8-sig")
    bcd_sources = "\n".join(
        (ROOT / relative).read_text(encoding="utf-8-sig")
        for relative in (
            "Pages/ApplyChanges.Bios.cs",
            "Pages/ApplyChanges.Processes.cs",
            "Pages/ApplyChanges.Windows.cs",
        )
    )

    assert "TextInfo.OEMCodePage" in system
    assert bcd_sources.count("GetWindowsConsoleEncoding()") >= 3


def test_apply_changes_progress_does_not_embed_french_fallbacks() -> None:
    sources = "\n".join(
        path.read_text(encoding="utf-8-sig") for path in (ROOT / "Pages").glob("ApplyChanges*.cs")
    )
    forbidden = (
        'UpdateProgress(5, "Préparation',
        'UpdateProgress(8, "Vérification',
        'UpdateProgress(18, "Déchiffrement',
        'UpdateProgress(0, "Annulation',
        'UpdateProgress(0, "Installation annulée',
        'UpdateProgress(0, "Rollback incomplet',
    )

    assert all(text not in sources for text in forbidden)


def test_reported_wizard_layouts_keep_text_and_controls_inside_the_window() -> None:
    welcome = (ROOT / "Pages/Welcome.xaml").read_text(encoding="utf-8-sig")
    compatibility = (ROOT / "Pages/CompatibilityCheck.xaml").read_text(encoding="utf-8-sig")
    warning = (ROOT / "Pages/WarningConfirmation.xaml").read_text(encoding="utf-8-sig")

    about = welcome.split('Content="{DynamicResource AboutButton}"', 1)[1]
    assert 'HorizontalAlignment="Right"' in about
    assert 'VerticalAlignment="Bottom"' in about

    description = compatibility.split('Text="{DynamicResource CompatibilityDescription}"', 1)[
        1
    ].split("/>", 1)[0]
    assert 'TextWrapping="Wrap"' in description
    assert 'TextAlignment="Center"' in description
    assert 'MaxWidth="880"' in description
    status = compatibility.split('x:Name="StatusText"', 1)[1].split("/>", 1)[0]
    assert 'Grid.Row="3"' in status
    assert 'FontWeight="SemiBold"' in status

    assert "<ScrollViewer" not in warning
    warning_content = warning.split('<Border Grid.Row="1"', 1)[1].split("</Border>", 1)[0]
    assert 'Width="640"' in warning_content
    assert 'VerticalAlignment="Center"' in warning_content
    assert 'Padding="12"' in warning_content
    assert 'LineHeight="20"' in warning_content
    for resource_key in (
        "WarningMessage",
        "WarningRisks",
        "WarningRecommendations",
        "WarningHibernationNotice",
    ):
        text_block = warning.split(f'Text="{{DynamicResource {resource_key}}}"', 1)[1].split(
            "/>", 1
        )[0]
        assert 'TextAlignment="Left"' in text_block
    checkbox = warning.split('x:Name="ConfirmCheckBox"', 1)[1].split(">", 1)[0]
    assert 'Grid.Column="1"' in checkbox
    assert 'MinHeight="40"' in checkbox
    assert 'HorizontalContentAlignment="Center"' in checkbox
    assert 'VerticalContentAlignment="Center"' in checkbox
    assert 'AutomationProperties.AutomationId="WarningAcknowledgement"' in checkbox
    checkbox_text = warning.split('Text="{DynamicResource WarningConfirmCheckbox}"', 1)[1].split(
        "/>", 1
    )[0]
    assert 'TextWrapping="NoWrap"' in checkbox_text
    assert 'TextAlignment="Center"' in checkbox_text
    confirm = warning.split('x:Name="ConfirmButton"', 1)[1].split("/>", 1)[0]
    assert 'Grid.Column="2"' in confirm
    assert 'AutomationProperties.AutomationId="WarningConfirmButton"' in confirm


def test_resize_slider_supports_direct_precise_track_interaction() -> None:
    resize = (ROOT / "Pages/ResizeDisk.xaml").read_text(encoding="utf-8-sig")
    slider = resize.split('x:Name="PartitionSlider"', 1)[1].split("/>", 1)[0]

    assert 'IsMoveToPointEnabled="True"' in slider
    assert 'SmallChange="1"' in slider
    assert 'LargeChange="5"' in slider
    assert 'IsSnapToTickEnabled="True"' in slider
    assert 'AutoToolTipPlacement="TopLeft"' in slider
    assert 'AutoToolTipPrecision="0"' in slider
    assert '<Border Height="8"' in resize
    assert '<Ellipse Width="28" Height="28"' in resize


def test_unattended_warning_has_dedicated_localized_copy() -> None:
    catalog = json.loads(
        (ROOT / "Resources/Libertix.Translations.json").read_text(encoding="utf-8")
    )
    dialog = (ROOT / "Dialogs/UnattendedWarningDialog.xaml").read_text(encoding="utf-8")

    assert "UnattendedWarningTitle" in dialog
    assert "UnattendedWarningMessage" in dialog
    for language in ("en", "fr", "es"):
        strings = catalog["languages"][language]["wpf"]
        assert strings["UnattendedWarningTitle"].strip()
        assert strings["UnattendedWarningMessage"].strip()


def test_resize_labels_and_windows_sharing_are_generic_and_localized() -> None:
    required_keys = {
        "ResizeDiskWindowsFreeInside",
        "ResizeDiskWindowsUsedLegend",
        "ResizeDiskWindowsFreeLegend",
        "ResizeDiskSizeValue",
        "ResizeDiskLinuxLegend",
        "ResizeDiskWindowsTotalLegend",
        "ResizeDiskUsedDetail",
        "ResizeDiskFreeDetail",
        "ResizeDiskSizeUnit",
        "SharingWindowsToLinuxTitle",
    }
    resize = (ROOT / "Pages/ResizeDisk.xaml").read_text(encoding="utf-8-sig")

    assert all(required_keys <= resource_keys(language) for language in LANGUAGES)
    assert "Windows used:" not in resize
    assert "Windows free:" not in resize
    assert "StringFormat=Used:" not in resize
    assert "StringFormat=Free:" not in resize

    for language in LANGUAGES:
        values = language_section(language, "wpf")
        assert "Mint" not in values["SharingWindowsToLinuxTitle"]
        assert "Linux" in values["SharingWindowsToLinuxTitle"]
