from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o755)


def update_grub_environment(tmp_path: Path) -> tuple[dict[str, str], Path]:
    boot = tmp_path / "boot" / "grub"
    boot.mkdir(parents=True)
    config = boot / "grub.cfg"
    config.write_text("last-known-good\n", encoding="utf-8")
    log = tmp_path / "logs" / "boot-maintenance.log"
    lock = tmp_path / "locks" / "update-grub.lock"
    validator = tmp_path / "validator"
    sync = tmp_path / "sync-efi"
    write_executable(validator, '#!/bin/sh\nexit "${VALIDATOR_RESULT:-0}"\n')
    write_executable(sync, '#!/bin/sh\nprintf synced > "$SYNC_MARKER"\n')
    environment = {
        **os.environ,
        "LIBERTIX_GRUB_CONFIG": str(config),
        "LIBERTIX_GRUB_VALIDATOR": str(validator),
        "LIBERTIX_PLAN_PATH": str(tmp_path / "installation-plan.json"),
        "LIBERTIX_BOOT_MAINTENANCE_LOG": str(log),
        "LIBERTIX_UPDATE_GRUB_LOCK": str(lock),
        "LIBERTIX_EFI_SYNC": str(sync),
        "SYNC_MARKER": str(tmp_path / "sync.marker"),
    }
    return environment, config


def test_update_grub_preserves_last_known_good_configuration_on_validation_failure(
    tmp_path: Path,
) -> None:
    environment, config = update_grub_environment(tmp_path)
    generator = tmp_path / "grub-mkconfig"
    write_executable(
        generator,
        '#!/bin/sh\n[ "$1" = -o ]\nprintf \'invalid candidate\\n\' > "$2"\n',
    )
    environment["LIBERTIX_GRUB_MKCONFIG"] = str(generator)
    environment["VALIDATOR_RESULT"] = "1"

    result = subprocess.run(
        ["bash", str(ROOT / "assets/live/libertix-update-grub.sh")],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode != 0
    assert config.read_text(encoding="utf-8") == "last-known-good\n"
    assert not list(config.parent.glob(".libertix-grub.cfg.*"))
    assert not (tmp_path / "sync.marker").exists()


def test_update_grub_atomically_publishes_validated_configuration_then_syncs_efi(
    tmp_path: Path,
) -> None:
    environment, config = update_grub_environment(tmp_path)
    generator = tmp_path / "grub-mkconfig"
    write_executable(
        generator,
        '#!/bin/sh\n[ "$1" = -o ]\nprintf \'verified candidate\\n\' > "$2"\n',
    )
    environment["LIBERTIX_GRUB_MKCONFIG"] = str(generator)

    subprocess.run(
        ["bash", str(ROOT / "assets/live/libertix-update-grub.sh")],
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )

    assert config.read_text(encoding="utf-8") == "verified candidate\n"
    assert (tmp_path / "sync.marker").read_text(encoding="utf-8") == "synced"


def test_update_grub_defers_efi_sync_until_package_transaction_completes(
    tmp_path: Path,
) -> None:
    environment, config = update_grub_environment(tmp_path)
    generator = tmp_path / "grub-mkconfig"
    write_executable(
        generator,
        '#!/bin/sh\n[ "$1" = -o ]\nprintf \'package candidate\\n\' > "$2"\n',
    )
    environment["LIBERTIX_GRUB_MKCONFIG"] = str(generator)
    environment["DPKG_MAINTSCRIPT_PACKAGE"] = "grub-efi-amd64-signed"

    result = subprocess.run(
        ["bash", str(ROOT / "assets/live/libertix-update-grub.sh")],
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )

    assert config.read_text(encoding="utf-8") == "package candidate\n"
    assert "EFI synchronization deferred" in result.stdout
    assert not (tmp_path / "sync.marker").exists()


def test_grub_validator_preserves_root_menu_and_advanced_submenu(tmp_path: Path) -> None:
    commands = tmp_path / "commands"
    commands.mkdir()
    write_executable(commands / "grub-script-check", "#!/bin/sh\nexit 0\n")
    plan = {
        "firmware": "uefi",
        "distribution": {
            "grubDisplayName": "Zorin OS 18.1 Core",
            "grubIcon": "zorin",
        },
    }
    plan_path = tmp_path / "installation-plan.json"
    plan_path.write_text(json.dumps(plan), encoding="utf-8")
    config = tmp_path / "grub.cfg"
    config.write_text(
        "menuentry 'Zorin OS 18.1 Core' --class zorin --id libertix-linux {\n}\n"
        "menuentry 'Windows Boot Manager' --class windows --id libertix-windows {\n}\n"
        "menuentry 'Shutdown' --class shutdown --id libertix-shutdown {\n}\n"
        "submenu 'Advanced options' --class efi --id libertix-advanced {\n"
        "  menuentry 'Older kernel' --id old-kernel {\n  }\n"
        '  if [ "$grub_platform" = "efi" ]; then\n'
        "    menuentry 'UEFI Firmware Settings' $menuentry_id_option "
        "'uefi-firmware' {\n    }\n  fi\n}\n",
        encoding="utf-8",
    )

    result = subprocess.run(
        [
            "bash",
            str(ROOT / "assets/live/libertix-validate-grub.sh"),
            str(config),
            str(plan_path),
        ],
        env={**os.environ, "PATH": f"{commands}:{os.environ['PATH']}"},
        capture_output=True,
        text=True,
        check=True,
    )

    assert "firmware=uefi roots=4" in result.stdout


def create_efi_sync_fixture(
    tmp_path: Path,
    *,
    secure_boot_enabled: bool,
    trusted: list[str],
    supported: list[str],
    firmware_authorities: list[str],
) -> tuple[dict[str, str], Path, Path]:
    commands = tmp_path / "commands"
    shim = tmp_path / "packages" / "shim"
    grub = tmp_path / "packages" / "grub"
    esp = tmp_path / "esp"
    efi = esp / "EFI" / "Libertix"
    for directory in (commands, shim, grub, efi):
        directory.mkdir(parents=True, exist_ok=True)
    run_id = "d" * 32
    (efi / ".libertix-owner").write_text(run_id + "\n", encoding="ascii")
    for name in ("shimx64.efi", "grubx64.efi", "mmx64.efi"):
        (efi / name).write_text(f"old-{name}\n", encoding="ascii")
    (efi / "grub.cfg").write_text("configfile /boot/grub/grub.cfg\n", encoding="ascii")

    (shim / "shimx64.efi.signed.2011").write_text("shim-2011\n", encoding="ascii")
    (shim / "mmx64.efi.signed").write_text("mok-manager\n", encoding="ascii")
    (grub / "grubx64.efi.signed").write_text("signed-grub\n", encoding="ascii")
    plan = {
        "firmware": "uefi",
        "distribution": {"secureBootMicrosoftAuthorities": supported},
        "runtime": {
            "recoveryRunId": run_id,
            "secureBootEnabled": secure_boot_enabled,
            "trustedMicrosoftUefiAuthorities": trusted,
        },
    }
    plan_path = tmp_path / "installation-plan.json"
    plan_path.write_text(json.dumps(plan), encoding="utf-8")

    write_executable(
        commands / "dpkg-query",
        """#!/bin/sh
case "$2" in
  */grubx64*) printf 'grub-efi-amd64-signed: %s\\n' "$2" ;;
  *) printf 'shim-signed: %s\\n' "$2" ;;
esac
""",
    )
    write_executable(
        commands / "sbverify",
        """#!/bin/sh
printf 'signature 1\\n'
if grep -Fq 'shim-2011' "$2"; then
  printf 'subject: CN=Microsoft Corporation UEFI CA 2011\\n'
elif grep -Fq 'shim-2023' "$2"; then
  printf 'subject: CN=Microsoft UEFI CA 2023\\n'
else
  printf 'subject: CN=Canonical Secure Boot Signing 2022\\n'
fi
""",
    )
    db_lines = "".join(
        "Microsoft Corporation UEFI CA 2011\n"
        if authority == "2011"
        else "Microsoft UEFI CA 2023\n"
        for authority in firmware_authorities
    )
    state = "enabled" if secure_boot_enabled else "disabled"
    write_executable(
        commands / "mokutil",
        f"""#!/bin/sh
case "$1" in
  --sb-state) printf 'SecureBoot {state}\\n' ;;
  --db) cat <<'EOF'
{db_lines}EOF
  ;;
esac
""",
    )
    write_executable(
        commands / "secure-boot-verifier",
        """#!/bin/sh
output=
while [ "$#" -gt 0 ]; do
  if [ "$1" = --output ]; then output="$2"; shift 2; else shift; fi
done
[ -n "$output" ]
printf '{"status":"verified"}\n' > "$output"
""",
    )
    write_executable(commands / "mountpoint", "#!/bin/sh\nexit 0\n")

    environment = {
        **os.environ,
        "PATH": f"{commands}:{os.environ['PATH']}",
        "LIBERTIX_PLAN_PATH": str(plan_path),
        "LIBERTIX_ESP_MOUNT": str(esp),
        "LIBERTIX_EFI_HISTORY_ROOT": str(tmp_path / "history"),
        "LIBERTIX_BOOT_MAINTENANCE_LOG": str(tmp_path / "logs" / "boot.log"),
        "LIBERTIX_EFI_SYNC_LOCK": str(tmp_path / "locks" / "efi.lock"),
        "LIBERTIX_SHIM_DIRECTORY": str(shim),
        "LIBERTIX_GRUB_SIGNED_DIRECTORY": str(grub),
        "LIBERTIX_SECURE_BOOT_VERIFIER": str(commands / "secure-boot-verifier"),
    }
    return environment, efi, shim


def test_efi_sync_uses_distribution_2011_chain_when_secure_boot_is_disabled(
    tmp_path: Path,
) -> None:
    environment, efi, shim = create_efi_sync_fixture(
        tmp_path,
        secure_boot_enabled=False,
        trusted=["2023"],
        supported=["2011"],
        firmware_authorities=["2023"],
    )

    subprocess.run(
        ["bash", str(ROOT / "assets/live/libertix-sync-efi.sh")],
        env=environment,
        capture_output=True,
        text=True,
        check=True,
    )

    assert (efi / "shimx64.efi").read_bytes() == (shim / "shimx64.efi.signed.2011").read_bytes()
    histories = list((tmp_path / "history").iterdir())
    assert len(histories) == 1
    assert (histories[0] / "SHA256SUMS").is_file()


def test_efi_sync_refuses_2011_chain_on_2023_only_secure_boot_firmware(
    tmp_path: Path,
) -> None:
    environment, efi, _shim = create_efi_sync_fixture(
        tmp_path,
        secure_boot_enabled=True,
        trusted=["2023"],
        supported=["2011"],
        firmware_authorities=["2023"],
    )

    result = subprocess.run(
        ["bash", str(ROOT / "assets/live/libertix-sync-efi.sh")],
        env=environment,
        capture_output=True,
        text=True,
        check=False,
    )

    assert result.returncode != 0
    assert "No distribution shim" in result.stdout + result.stderr
    assert (efi / "shimx64.efi").read_text(encoding="ascii") == "old-shimx64.efi\n"
    assert not list((tmp_path / "history").iterdir())
