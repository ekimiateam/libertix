from __future__ import annotations

import importlib.util
import json
from pathlib import Path
from types import ModuleType
from xml.etree import ElementTree

import pytest

ROOT = Path(__file__).resolve().parents[2]
LANGUAGES = ("en", "fr", "es", "ja")
XAML_KEY = "{http://schemas.microsoft.com/winfx/2006/xaml}Key"


def load_i18n_module() -> ModuleType:
    path = ROOT / "assets/live/libertix-i18n.py"
    spec = importlib.util.spec_from_file_location("libertix_i18n_tests", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"Cannot load live translation helper: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def resource_keys(language: str) -> set[str]:
    path = ROOT / f"Resources/Lang/Strings.{language}.xaml"
    tree = ElementTree.parse(path)
    return {element.attrib[XAML_KEY] for element in tree.getroot() if XAML_KEY in element.attrib}


def test_about_page_is_built_and_reachable_from_welcome() -> None:
    project = (ROOT / "Libertix.csproj").read_text(encoding="utf-8-sig")
    welcome = (ROOT / "MainWindow.xaml").read_text(encoding="utf-8-sig")
    code_behind = (ROOT / "MainWindow.xaml.cs").read_text(encoding="utf-8-sig")
    about = (ROOT / "Pages/About.xaml").read_text(encoding="utf-8-sig")

    assert '<Page Include="Pages\\About.xaml" />' in project
    assert '<Compile Include="Pages\\About.xaml.cs">' in project
    assert 'Click="AboutButton_Click"' in welcome
    assert "new About()" in code_behind
    assert "https://ekimia.fr/libertix/" in about
    assert "https://ekimia.fr/donations/campagne-libertix/" in about
    assert "https://github.com/ekimiateam/libertix" in about


def test_returning_from_about_clears_welcome_animation_clocks() -> None:
    code_behind = (ROOT / "MainWindow.xaml.cs").read_text(encoding="utf-8-sig")
    return_to_welcome = code_behind.split("public void ReturnToWelcome()", 1)[1].split(
        "private void LanguageComboBox_SelectionChanged", 1
    )[0]

    assert "BeginAnimation(UIElement.OpacityProperty, null)" in return_to_welcome
    assert "BeginAnimation(FrameworkElement.MarginProperty, null)" in return_to_welcome
    assert "welcomeElement.Opacity = 1.0" in return_to_welcome
    assert "welcomeFrameworkElement.Margin = new Thickness(0)" in return_to_welcome
    assert "if (MainFrame.CanGoBack)" in return_to_welcome
    assert "MainFrame.GoBack()" in return_to_welcome
    assert "MainFrame.Content = _welcomeContent" in return_to_welcome


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
        content = (ROOT / f"Resources/Lang/Strings.{language}.xaml").read_text(encoding="utf-8-sig")
        for name in (*required_names, *required_donors):
            assert name in content


def test_live_translation_catalogues_have_identical_keys() -> None:
    catalogue = json.loads(
        (ROOT / "assets/live/libertix-translations.json").read_text(encoding="utf-8")
    )

    assert set(catalogue) == set(LANGUAGES)
    assert len({frozenset(entries) for entries in catalogue.values()}) == 1
    assert all(catalogue[language] for language in LANGUAGES)


@pytest.mark.parametrize("language", LANGUAGES)
def test_live_translation_helper_loads_every_supported_language(language: str) -> None:
    module = load_i18n_module()
    translations = module.load_catalogue(language)

    assert translations["stage_120_unsquashfs"]
    assert translations["installation_success"]


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

    assert "string languageCode = Localization.CurrentLanguage" in runner
    assert '" -LanguageCode " + QuoteArgument(languageCode)' in runner
    assert '[ValidateSet("en", "fr", "es", "ja")]' in script
    assert 'COMPAT_010_PRIVILEGES = "Checking administrator privileges"' in script
    assert 'COMPAT_050_FILESYSTEM = "Checking NTFS, BitLocker, and shrinkable space"' in script
    assert 'BITLOCKER = "BitLocker is active;' in script
    assert 'Write-Check "COMPAT_010_PRIVILEGES"' in script
    assert 'Write-Check "COMPAT_050_FILESYSTEM"' in script
    assert 'Write-LocalizedWarning "BITLOCKER"' in script


def test_apply_changes_runtime_messages_are_translated_in_every_language() -> None:
    required_keys = {
        "ConfirmationYes",
        "ConfirmationNo",
        "ApplyChangesPreparingWindowsShare",
        "ApplyChangesPreparingUefi",
        "ApplyChangesCheckingSecureBoot",
        "ApplyChangesDecryptingWindowsInit",
        "ApplyChangesWindowsDecrypted",
        "ApplyChangesDecryptingWindows",
        "ApplyChangesDecryptingWindowsPercent",
        "ApplyChangesDownloading",
        "ApplyChangesDownloadingIso",
        "ApplyChangesDownloadingLinuxIso",
        "ApplyChangesDownloadingMint",
        "ApplyChangesDownloadingUefiIso",
        "ApplyChangesRollbackInProgress",
        "ApplyChangesCancelledRestored",
        "ApplyChangesErrorRollback",
        "ApplyChangesRollbackIncomplete",
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
