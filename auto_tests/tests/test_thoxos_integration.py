"""ThoxOS integration contracts.

ThoxOS is shipped as a branded Ubuntu 26.10 workstation inside the existing
distribution mechanism: one signed catalog entry plus an additive brand layer.
These tests pin the parts that would silently break the installation if they
drifted — the catalog entry itself, the icon the GRUB theme must ship, the
payload the ISO must stage, and the os-release rule that ThoxOS branding never
changes the distribution identity the installer verifies.
"""

from __future__ import annotations

import json
import re
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
DISTRIBUTION_ID = "thoxos"
# ThoxOS is a branded Ubuntu base. Libertix accepts only Debian/Ubuntu-family
# payloads and verifies the plan's osReleaseId against the extracted rootfs, so
# branding must never rewrite this value.
UPSTREAM_OS_RELEASE_ID = "ubuntu"

THOXOS_TOKEN_PATH = REPO_ROOT / "assets" / "thoxos" / "tokens" / "thoxos-tokens.json"
THOXOS_LAYER_SCRIPT = REPO_ROOT / "assets" / "live" / "thoxos-configure-target.sh"
THOXOS_ENTRYPOINT = REPO_ROOT / "assets" / "live" / "configure-thoxos-target.sh"

BRAND_FILES = (
    "fonts/Xolonium-Regular.otf",
    "fonts/Xolonium-Bold.otf",
    "fonts/OFL.txt",
    "logo/thox-icon.svg",
    "logo/thox-horizontal.svg",
    "logo/thox-wordmark.svg",
    "logo/thox-stacked.svg",
    "logo/thox-app-icon.svg",
    "logo/thox-app-icon-256.png",
    "logo/favicon.ico",
    "logo/on-light/thox-horizontal.svg",
    "tokens/thoxos-tokens.json",
    "wallpaper/thoxos-desk-wallpaper.jpg",
)


def read(relative: str) -> str:
    return (REPO_ROOT / relative).read_text(encoding="utf-8")


def catalog_distributions(path: Path) -> list[dict]:
    return json.loads(path.read_text(encoding="utf-8"))["distributions"]


def thoxos_entry(entries: list[dict]) -> dict:
    matches = [entry for entry in entries if entry.get("id") == DISTRIBUTION_ID]
    assert len(matches) == 1, "the ThoxOS catalog entry must exist exactly once"
    return matches[0]


def test_release_config_declares_a_contract_complete_thoxos_entry() -> None:
    entry = thoxos_entry(catalog_distributions(REPO_ROOT / "release-config.json"))

    assert entry["osReleaseId"] == UPSTREAM_OS_RELEASE_ID
    assert entry["grubDisplayName"] == "ThoxOS 26.10 (Kubuntu 26.10 Plasma)"
    assert entry["grubIcon"] == "thoxos"
    assert entry["isoInstaller"].startswith("https://")
    assert entry["isoInstallerFileName"] == "kubuntu-26.10-snapshot4-desktop-amd64.iso"
    assert re.fullmatch(r"[0-9a-f]{64}", entry["isoInstallerSha256"])
    assert entry["isoInstallerSizeBytes"] > 0
    assert entry["sizeInGB"] >= 20
    # Both Microsoft UEFI authorities: ThoxOS installs a shim-signed chain and
    # must keep working on 2023-CA-only firmware as well as the older 2011 CA.
    assert sorted(entry["secureBootMicrosoftAuthorities"]) == ["2011", "2023"]


def test_served_and_fixture_catalogs_carry_the_same_thoxos_entry() -> None:
    served = REPO_ROOT / "auto_tests" / "app" / "filepool" / "catalog.json"
    fixture = REPO_ROOT / "Libertix.Tests" / "TestData" / "catalog.json"

    assert served.read_bytes() == fixture.read_bytes()
    entry = thoxos_entry(catalog_distributions(served))
    assert entry["grubIcon"] == "thoxos"


def test_thoxos_grub_icon_is_packaged_in_the_shared_theme() -> None:
    icon = REPO_ROOT / "assets" / "grub-theme" / "icons" / "thoxos.png"
    assert icon.is_file()
    # The shared theme renders one icon grid; the new mark must match it.
    assert icon.read_bytes()[:8] == b"\x89PNG\r\n\x1a\n"


def test_iso_pin_matches_the_recorded_canonical_provenance() -> None:
    provenance = json.loads(
        (REPO_ROOT / "assets" / "thoxos" / "iso-provenance.json").read_text(encoding="utf-8")
    )
    entry = thoxos_entry(catalog_distributions(REPO_ROOT / "release-config.json"))

    assert provenance["distribution"] == DISTRIBUTION_ID
    assert provenance["isoInstallerSha256"] == entry["isoInstallerSha256"]
    assert provenance["isoInstallerSizeBytes"] == entry["isoInstallerSizeBytes"]
    assert provenance["isoUrl"] == entry["isoInstaller"]
    assert provenance["isoFileName"] == entry["isoInstallerFileName"]
    assert provenance["sha256SumsUrl"].startswith("https://")


@pytest.mark.parametrize("relative", BRAND_FILES)
def test_thoxos_brand_payload_is_present(relative: str) -> None:
    path = REPO_ROOT / "assets" / "thoxos" / relative
    assert path.is_file(), f"missing ThoxOS brand payload: {relative}"
    assert path.stat().st_size > 0


def test_every_required_brand_payload_path_exists_in_the_repository() -> None:
    """The layer aborts the install if its own payload guard can fail.

    Every path the guard demands must exist under assets/thoxos/, otherwise a
    ThoxOS installation would stop after the filesystem was already written.
    """
    script = THOXOS_LAYER_SCRIPT.read_text(encoding="utf-8")
    declaration = re.search(
        r"THOXOS_REQUIRED_PAYLOAD=\((.*?)\n\)", script, re.S
    )
    assert declaration is not None, "THOXOS_REQUIRED_PAYLOAD was not found"
    required = re.findall(r'"([^"]+)"', declaration.group(1))
    assert required, "the payload guard lists no files"

    layer_root = REPO_ROOT / "assets" / "thoxos"
    missing = [relative for relative in required if not (layer_root / relative).is_file()]
    assert not missing, f"the brand layer guard requires missing files: {missing}"


def test_thoxos_palette_uses_the_official_brand_green_and_zinc_surfaces() -> None:
    tokens = json.loads(THOXOS_TOKEN_PATH.read_text(encoding="utf-8"))
    palette = tokens["palette"]

    assert palette["brandGreen"] == "#05a451"
    assert palette["lightText"] == "#f9f9f9"
    assert palette["monoBlack"] == "#000000"
    # ThoxOS Desk surface roles.
    assert palette["surfaceBase"] == "#09090b"
    assert palette["surfaceCanvas"] == "#0b0f12"
    assert palette["surfacePanel"] == "#11161c"
    assert palette["borderDefault"] == "#3f3f46"
    assert tokens["typography"]["uiFamily"] == "Xolonium"

    # The dual-boot contract travels with the palette so the two cannot drift:
    # the icon class the GRUB theme must render and the authorities the UEFI
    # chain is verified against.
    dual = tokens["dualBoot"]
    entry = thoxos_entry(catalog_distributions(REPO_ROOT / "release-config.json"))
    assert dual["grubIconClass"] == entry["grubIcon"]
    assert sorted(dual["secureBootMicrosoftAuthorities"]) == sorted(
        entry["secureBootMicrosoftAuthorities"]
    )


def test_wpf_theme_uses_the_thoxos_tokens_and_drops_the_previous_palette() -> None:
    theme = read("App.xaml").lower()

    for token in ("#09090b", "#18181b", "#3f3f46", "#fafafa", "#10b981", "#34d399", "#05a451"):
        assert token in theme, f"App.xaml is missing ThoxOS token {token}"

    # Rose Pine values from the previous theme must not survive anywhere.
    for retired in ("#232136", "#2a273f", "#3e8fb0", "#e0def4", "#908caa", "#c4a7e7", "#1e1c31"):
        assert retired not in theme, f"App.xaml still carries the retired colour {retired}"


def test_thoxos_branding_never_rewrites_the_distribution_identity() -> None:
    script = THOXOS_LAYER_SCRIPT.read_text(encoding="utf-8")

    # The branding pass must key off the target's own os-release, not a static
    # file, and must assert the identity afterwards.
    assert "/usr/lib/os-release.upstream" in script
    assert "ThoxOS branding changed the os-release identity" in script
    assert "DISTRIBUTION_OS_RELEASE_ID" in script
    # ID and ID_LIKE are never in the override table.
    override_block = script.split("override[", 1)[1]
    assert 'override["ID"]' not in override_block
    assert 'override["ID_LIKE"]' not in override_block


def test_thoxos_layer_applies_to_the_target_only_for_the_thoxos_distribution() -> None:
    target = read("assets/live/configure-target-main.sh")
    # Scope the ordering check to main(), which is the real execution order.
    main_body = target.split("main() {", 1)[1]

    assert "configure_thoxos_variant" in target
    assert '[ "$DISTRIBUTION_ID" = "thoxos" ] || return 0' in target
    # Additive by construction: the shared configuration still runs in full.
    for shared in (
        "assert_target_distribution_identity",
        "configure_user",
        "configure_locale",
        "configure_grub",
        "enable_first_boot_resize",
    ):
        assert shared in main_body
    # The variant hook runs after the payload is installed and before GRUB is
    # rendered, so the installed system is already complete when it starts.
    assert main_body.index("configure_thoxos_variant") < main_body.index("configure_grub")


def _bash_syntax_check(path: Path) -> subprocess.CompletedProcess:
    """Run `bash -n` on a repo script.

    The script is piped in on stdin rather than passed as an argument: a native
    Windows bash cannot translate a drive-letter path, and the repository must
    stay testable on the maintainer's Windows and Linux hosts alike.

    The payload is piped as bytes. Passing a str would let Python's text-mode
    stdin writer translate every ``\\n`` into ``\\r\\n`` on Windows, which makes
    bash report a syntax error on a perfectly valid LF script.
    """
    return subprocess.run(
        ["bash", "-n"],
        input=path.read_bytes(),
        check=False,
        capture_output=True,
        text=False,
    )


def test_target_common_stages_the_thoxos_payload_for_both_firmware_modes() -> None:
    common = read("assets/live/libertix-target-common.sh")

    assert "install_thoxos_variant_payload" in common
    assert "/usr/local/lib/libertix/thoxos-layer" in common
    assert "/mnt/target/tmp/thoxos-layer" in common
    # An empty payload must abort rather than install a half-branded system.
    assert "ThoxOS brand layer payload is empty" in common


def test_iso_builder_stages_the_thoxos_layer_into_the_live_system() -> None:
    builder = read("iso-tools/build-iso.sh")

    assert "libertix-thoxos-configure-target.sh" in builder
    assert "libertix-configure-thoxos.sh" in builder
    assert "/usr/local/lib/libertix/thoxos-layer" in builder
    assert "ThoxOS brand layer is missing" in builder


def test_thoxos_entrypoint_requires_the_firmware_mode_before_sourcing_the_layer() -> None:
    entrypoint = THOXOS_ENTRYPOINT.read_text(encoding="utf-8")

    assert "LIBERTIX_FIRMWARE_MODE is required" in entrypoint
    assert ". /tmp/thoxos-configure-target.sh" in entrypoint
    assert "thoxos_configure_target" in entrypoint

    result = _bash_syntax_check(THOXOS_ENTRYPOINT)
    assert result.returncode == 0, result.stderr


def test_thoxos_layer_script_is_valid_bash() -> None:
    result = _bash_syntax_check(THOXOS_LAYER_SCRIPT)
    assert result.returncode == 0, result.stderr


def test_thoxos_branding_rewrites_presentation_keys_but_keeps_upstream_keys(
    tmp_path: Path,
) -> None:
    """Execute the real awk branding pass against a real Ubuntu os-release."""

    script = THOXOS_LAYER_SCRIPT.read_text(encoding="utf-8")
    function = re.search(r"thoxos_branded_os_release\(\) \{.*?\n\}\n", script, re.S)
    assert function is not None, "thoxos_branded_os_release was not found"
    awk_block = re.search(r"awk '\n(.*?)\n    ' \"\$upstream\"", function.group(0), re.S)
    assert awk_block is not None, "the os-release branding awk block was not found"

    upstream = (
        'PRETTY_NAME="Ubuntu Stonking Stingray (development branch)"\n'
        'NAME="Ubuntu"\n'
        'VERSION_ID="26.10"\n'
        'VERSION="26.10 (Stonking Stingray)"\n'
        "VERSION_CODENAME=stonking\n"
        "ID=ubuntu\n"
        "ID_LIKE=debian\n"
        'HOME_URL="https://www.ubuntu.com/"\n'
        'DOCUMENTATION_URL="https://docs.ubuntu.com"\n'
        'SUPPORT_URL="https://help.ubuntu.com/"\n'
        'BUG_REPORT_URL="https://bugs.launchpad.net/ubuntu/"\n'
        "LOGO=ubuntu-logo\n"
        'VENDOR_NAME="Canonical"\n'
        "UBUNTU_CODENAME=stonking\n"
    )

    # The awk program is fed to a temporary file via `awk -f`, exactly as the
    # shipped function does. The program is never re-quoted through the shell,
    # so its escaping cannot be mangled by the test harness.
    program = tmp_path / "brand-os-release.awk"
    program.write_text(awk_block.group(1) + "\n", encoding="utf-8")
    source = tmp_path / "os-release.upstream"
    source.write_text(upstream, encoding="utf-8")

    result = subprocess.run(
        ["awk", "-f", str(program).replace("\\", "/"), str(source).replace("\\", "/")],
        check=False,
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0, result.stderr

    values = dict(
        line.split("=", 1) for line in result.stdout.splitlines() if "=" in line
    )
    # Branding applied.
    assert values["PRETTY_NAME"] == '"ThoxOS 26.10 Workstation"'
    assert values["NAME"] == '"ThoxOS"'
    assert values["LOGO"] == "thoxos-logo"
    assert values["THOX_VARIANT_ID"] == "thoxos-workstation"
    # Identity and untouched upstream keys preserved verbatim.
    assert values["ID"] == "ubuntu"
    assert values["ID_LIKE"] == "debian"
    assert values["VERSION_ID"] == '"26.10"'
    assert values["VENDOR_NAME"] == '"Canonical"'
    assert values["DOCUMENTATION_URL"] == '"https://docs.ubuntu.com"'

    lines = [line for line in result.stdout.splitlines() if "=" in line]
    keys = [line.split("=", 1)[0] for line in lines]
    assert len(keys) == len(set(keys)), "branding duplicated an os-release key"
