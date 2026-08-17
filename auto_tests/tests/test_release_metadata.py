from __future__ import annotations

import base64
import importlib.util
import json
from pathlib import Path

import jsonschema
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding, rsa

REPO_ROOT = Path(__file__).parents[2]


def load_script(name: str, filename: str):
    script = REPO_ROOT / "iso-tools" / filename
    spec = importlib.util.spec_from_file_location(name, script)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_release_config_matches_schema_and_packages_every_grub_icon() -> None:
    config = json.loads((REPO_ROOT / "release-config.json").read_text(encoding="utf-8"))
    schema = json.loads(
        (REPO_ROOT / "schemas/release-config.schema.json").read_text(encoding="utf-8")
    )
    jsonschema.Draft202012Validator(schema, format_checker=jsonschema.FormatChecker()).validate(
        config
    )

    assert {entry["id"] for entry in config["distributions"]} == {"mint", "zorin"}
    for distribution in config["distributions"]:
        assert (REPO_ROOT / "assets/grub-theme/icons" / f"{distribution['grubIcon']}.png").is_file()


def test_metadata_generator_separates_dev_and_main_channels(tmp_path: Path) -> None:
    module = load_script("generate_release_metadata", "generate-release-metadata.py")
    config = module.load_config(REPO_ROOT / "release-config.json")
    bios = tmp_path / "libertix-installer-bios.iso"
    uefi = tmp_path / "libertix-installer-uefi.iso"
    wpf = tmp_path / "Libertix-a881918.zip"
    aria2 = tmp_path / "aria2-64.zip"
    ext4 = tmp_path / "ext4-win-driver.exe"
    grldr = tmp_path / "grldr"
    grldr_mbr = tmp_path / "grldr.mbr"
    bios.write_bytes(b"bios")
    uefi.write_bytes(b"uefi")
    wpf.write_bytes(b"wpf")
    aria2.write_bytes(b"aria2")
    ext4.write_bytes(b"ext4")
    grldr.write_bytes(b"grldr")
    grldr_mbr.write_bytes(b"grldr.mbr")
    commit = "a881918" + "0" * 33
    main_version = config["mainRelease"]["version"]

    dev_catalog, dev_releases = module.generate_metadata(
        config,
        channel="dev",
        tag="a881918",
        commit=commit,
        bios_iso=bios,
        uefi_iso=uefi,
        wpf_zip=wpf,
        aria2_archive=aria2,
        ext4_driver=ext4,
        grub4dos_loader=grldr,
        grub4dos_mbr=grldr_mbr,
        published_at="2026-08-10T00:00:00Z",
    )
    main_wpf = tmp_path / f"Libertix-{main_version}.zip"
    main_wpf.write_bytes(wpf.read_bytes())
    main_catalog, main_releases = module.generate_metadata(
        config,
        channel="main",
        tag=main_version,
        commit=commit,
        bios_iso=bios,
        uefi_iso=uefi,
        wpf_zip=main_wpf,
        aria2_archive=aria2,
        ext4_driver=ext4,
        grub4dos_loader=grldr,
        grub4dos_mbr=grldr_mbr,
        published_at="2026-08-10T00:00:00Z",
    )

    assert dev_releases["latest"]["version"] == "dev_a881918"
    assert dev_catalog["artifacts"]["wpf"]["fileName"] == "Libertix-a881918.zip"
    assert main_catalog["artifacts"]["wpf"]["fileName"] == f"Libertix-{main_version}.zip"
    assert dev_releases["latest"]["notes"] == ("Automated Libertix alpha build for commit a881918.")
    assert main_releases["latest"]["version"] == main_version
    assert main_releases["latest"]["notes"] == config["mainRelease"]["notes"]
    assert "/a881918/" in dev_catalog["artifacts"]["miniIso"]["bios"]["url"]
    assert f"/{main_version}/" in main_catalog["artifacts"]["miniIso"]["bios"]["url"]
    assert (
        dev_catalog["artifacts"]["miniIso"]["bios"]["sha256"]
        == main_catalog["artifacts"]["miniIso"]["bios"]["sha256"]
    )
    assert (
        dev_catalog["distributions"][0]["isoInstallerSha256"]
        == config["distributions"][0]["isoInstallerSha256"]
    )
    assert "isoUrl" not in dev_catalog["distributions"][0]
    assert dev_catalog["artifacts"]["support"]["aria2Archive"]["url"] == "aria2-64.zip"


def test_versioned_support_artifacts_match_the_shared_catalog() -> None:
    module = load_script("prepare_support_artifacts", "prepare-support-artifacts.py")
    catalog_path = REPO_ROOT / "Scripts/config/Libertix.Artifacts.json"
    artifacts = module.load_support_artifacts(catalog_path)

    assert {artifact.file_name for artifact in artifacts} == {
        "aria2-64.zip",
        "ext4-win-driver.exe",
        "grldr",
        "grldr.mbr",
    }
    for artifact in artifacts:
        path = REPO_ROOT / "auto_tests/app/filepool" / artifact.file_name
        assert path.is_file()
        assert module.file_sha256(path) == artifact.sha256


def test_signer_rejects_a_key_that_is_not_the_application_key(tmp_path: Path) -> None:
    module = load_script("sign_release_metadata", "sign-release-metadata.py")
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    private_path = tmp_path / "private.pem"
    private_path.write_bytes(
        private_key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    manifest = tmp_path / "catalog.json"
    manifest.write_text('{"schemaVersion":1}\n', encoding="utf-8")

    try:
        module.sign_files(
            private_path,
            REPO_ROOT / "Scripts/config/Libertix.CatalogPublicKey.xml",
            [manifest],
        )
    except ValueError as error:
        assert "does not match" in str(error)
    else:
        raise AssertionError("a foreign private key was accepted")


def test_versioned_catalog_signature_is_pkcs1_sha256() -> None:
    module = load_script("sign_release_metadata_fixture", "sign-release-metadata.py")
    manifest = REPO_ROOT / "auto_tests/app/filepool/catalog.json"
    signature = base64.b64decode(
        (REPO_ROOT / "auto_tests/app/filepool/catalog.json.sig")
        .read_text(encoding="ascii")
        .strip(),
        validate=True,
    )
    public_numbers = module.load_application_public_numbers(
        REPO_ROOT / "Scripts/config/Libertix.CatalogPublicKey.xml"
    )
    public_numbers.public_key().verify(
        signature,
        manifest.read_bytes(),
        padding.PKCS1v15(),
        hashes.SHA256(),
    )
