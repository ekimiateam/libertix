import os
import subprocess
from pathlib import Path


def test_installed_redirect_preserves_a_foreign_debian_configuration(tmp_path: Path):
    adapter = Path(__file__).resolve().parents[2] / "assets/live/libertix-uefi-adapter.sh"
    function = adapter.read_text().split("install_signed_uefi_bootloader_or_die() {", 1)[1]
    function = function.split("\ncleanup_temporary_uefi_bootentries()", 1)[0]
    function = "install_signed_uefi_bootloader_or_die() {" + function
    # Only the mount location and block-device predicate are replaced; the real
    # installation function performs all filesystem writes in the fixture ESP.
    function = function.replace("/mnt/target", str(tmp_path / "target"))
    function = function.replace('-b "$esp_part"', '-c "$esp_part"')
    esp = tmp_path / "target/boot/efi"
    foreign = esp / "EFI/debian/grub.cfg"
    foreign.parent.mkdir(parents=True)
    foreign.write_text("foreign boot configuration\n")
    script = (
        r"""
set -euo pipefail
find_esp_partition() { echo /dev/null; }
partition_number() { echo 1; }
blkid() { echo 11111111-2222-3333-4444-555555555555; }
mountpoint() { return 0; }
chroot() { :; }
sync() { :; }
umount() { :; }
ensure_windows_bootentry_for_current_esp_or_die() { :; }
set_libertix_bootentry_first_or_die() { LIBERTIX_FINAL_BOOTNUM=0002; }
die() { echo "$*" >&2; exit 1; }
RECOVERY_RUN_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
NEW_PART=/dev/null
LIBERTIX_BOOT_LOADER='\EFI\Libertix\shimx64.efi'
"""
        + function
        + "\ninstall_signed_uefi_bootloader_or_die\n"
    )
    result = subprocess.run(
        ["bash", "-c", script],
        env=os.environ.copy(),
        text=True,
        capture_output=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert foreign.read_text() == "foreign boot configuration\n"
    redirect = (esp / "EFI/Libertix/grub.cfg").read_text()
    assert "11111111-2222-3333-4444-555555555555" in redirect
    assert "configfile /boot/grub/grub.cfg" in redirect
