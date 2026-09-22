import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
ADAPTER = ROOT / "assets/live/libertix-uefi-adapter.sh"
RUN_ID = "0123456789abcdef0123456789abcdef"


@pytest.mark.parametrize("owner", [RUN_ID, "f" * 32, "", None])
def test_live_temporary_efi_cleanup_respects_owner(tmp_path: Path, owner: str | None) -> None:
    directory = tmp_path / "EFI/LibertixInstaller"
    directory.mkdir(parents=True)
    loader = directory / "BOOTX64.EFI"
    loader.write_bytes(b"preserve foreign loader")
    if owner is not None:
        (directory / ".libertix-owner").write_text(owner)
    result = subprocess.run(
        [
            "bash",
            "-c",
            'source "$1"; RECOVERY_RUN_ID="$2"; sync() { :; }; '
            'remove_owned_temporary_efi_files "$3"',
            "test",
            str(ADAPTER),
            RUN_ID,
            str(tmp_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if owner == RUN_ID:
        assert result.returncode == 0, result.stderr
        assert not directory.exists()
    else:
        assert result.returncode != 0
        assert loader.read_bytes() == b"preserve foreign loader"


def test_live_rollback_and_success_both_clean_the_owned_temporary_efi() -> None:
    source = ADAPTER.read_text()
    rollback = source.split("cleanup_final_uefi_bootloader_best_effort() (", 1)[1].split(
        "set_linux_partition_type_or_die()", 1
    )[0]
    assert 'remove_owned_temporary_efi_files "$esp_mount" || return 1' in rollback
    assert source.count('remove_owned_temporary_efi_files "$esp_mount"') == 2
