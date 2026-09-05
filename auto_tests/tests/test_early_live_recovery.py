from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

from .test_installation_contracts import make_plan

ROOT = Path(__file__).resolve().parents[2]

# Keep the real policy, JSON validators, manifest resolver and state transitions.
# Only device observations, mounts and physical rollback operations are simulated.
SHELL_ENVIRONMENT = r"""
set -Eeuo pipefail
ROOT="$1"
LOG_DIR="$2"
FIRMWARE="$3"
TEST_PYTHON="$4"
source "$ROOT/assets/live/libertix-installation-plan.sh"
source "$ROOT/assets/live/libertix-live-context.sh"
source "$ROOT/assets/live/libertix-storage-common.sh"
source "$ROOT/assets/live/libertix-rollback-common.sh"
source "$ROOT/assets/live/libertix-$FIRMWARE-adapter.sh"
function /usr/local/lib/libertix/libertix-installation-plan.py() {
    "$TEST_PYTHON" "$ROOT/assets/live/libertix-installation-plan.py" "$@"
}
function /usr/local/lib/libertix/libertix-installation-state.py() {
    "$TEST_PYTHON" "$ROOT/assets/live/libertix-installation-state.py" "$@"
}
function /usr/local/lib/libertix/libertix_installation_policy.py() {
    "$TEST_PYTHON" "$ROOT/assets/live/libertix_installation_policy.py" "$@"
}
function [() {
    if [[ "$1" == -b ]]; then
        [[ "$2" == /dev/test-disk || "$2" == /dev/test-disk[124] ]]
    elif [[ "$1" == -x && "$2" == /usr/local/lib/libertix/*.py ]]; then
        return 0
    elif [[ "$1" == -f && "$2" == /run/live/* ||
            "$1" == -f && "$2" == /lib/live/* ||
            "$1" == -f && "$2" == /cdrom/* ]]; then
        return 1
    else
        builtin [ "$@"
    fi
}
candidate_disks() { echo /dev/test-disk; }
partitions_of_disk() { printf '%s\n' /dev/test-disk1 /dev/test-disk2; }
partition_start_bytes() {
    case "$2" in
        /dev/test-disk1) echo 1048576 ;;
        /dev/test-disk2) echo 1073741824 ;;
        *) return 1 ;;
    esac
}
blockdev() { echo 274877906944; }
parted() {
    local style=gpt
    [ "$FIRMWARE" != bios ] || style=msdos
    printf 'BYT;\n/dev/test-disk:256GB:scsi:512:512:%s:test:;\n' "$style"
}
blkid() {
    if [ "$1" = -o ]; then echo /dev/test-disk4; return 0; fi
    case "$2" in
        LABEL) /usr/local/lib/libertix/libertix_installation_policy.py staging-volume-label ;;
        PTUUID)
            local count
            count="$(cat "$LOG_DIR/settles" 2>/dev/null || echo 0)"
            [ "$count" -ge "${REQUIRED_SETTLES:-0}" ] || return 1
            if [ "$FIRMWARE" = bios ]; then echo 1234abcd;
            else echo 12345678-1234-1234-1234-123456789abc; fi ;;
        TYPE) echo ntfs ;;
        *) return 1 ;;
    esac
}
find() {
    case "$1" in
        "$LOG_DIR"/*) command find "$@" ;;
        *) return 1 ;;
    esac
}
mount() {
    [ "$1" = -t ] && [ "$2" = vfat ] || return 1
    cp "$LOG_DIR"/source/*.json "${@: -1}/"
}
mountpoint() { return 1; }
umount() { return 0; }
udevadm() {
    local count
    count="$(cat "$LOG_DIR/settles" 2>/dev/null || echo 0)"
    echo "$((count + 1))" > "$LOG_DIR/settles"
}
sleep() { return 0; }
mark() { echo "STAGE: $1"; }
die() { echo "DIE: $*"; exit 1; }
load_libertix_live_context "$FIRMWARE"
[ -z "${LIBERTIX_STAGING_VOLUME_LABEL:-}" ]
echo CONTEXT_LOADED_WITHOUT_LABEL
"""


def run_early_live(tmp_path: Path, firmware: str, command: str) -> subprocess.CompletedProcess[str]:
    source = tmp_path / "source"
    source.mkdir()
    (source / "installation-plan.json").write_text(
        json.dumps(make_plan(firmware, 20)), encoding="utf-8"
    )
    state = {
        "schemaVersion": 1,
        "planId": "a" * 32,
        "revision": 14,
        "status": "running",
        "phase": "windows",
        "activeStep": None,
        "completedSteps": [
            "windows.preflight-verified",
            "windows.artifacts-verified",
            "windows.recovery-armed",
            "windows.system-volume-shrunk",
            "windows.installer-partition-created",
            "windows.live-media-prepared",
            "windows.temporary-boot-prepared",
        ],
        "compensatedSteps": [],
        "failure": None,
        "updatedAtUtc": "2026-07-15T12:00:00Z",
    }
    (source / "installation-state.json").write_text(json.dumps(state), encoding="utf-8")
    installer = (ROOT / "assets/live/libertix-install-main.sh").read_text(encoding="utf-8")
    bootstrap = 'DISK=""' + installer.split('DISK=""', 1)[1].split('PASSWORD_HASH=""', 1)[0]
    return subprocess.run(
        [
            "bash",
            "-c",
            SHELL_ENVIRONMENT + bootstrap + command,
            "early-live-test",
            str(ROOT),
            str(tmp_path),
            firmware,
            sys.executable,
        ],
        env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        capture_output=True,
        text=True,
        check=False,
        timeout=30,
    )


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
@pytest.mark.parametrize("scenario", ["ready", "unlabeled", "wrong-label", "no-disk", "no-policy"])
def test_prerequisites_find_staging_after_runner_context_load(
    tmp_path: Path, firmware: str, scenario: str
) -> None:
    setup = {
        "ready": "",
        "unlabeled": 'blkid() { if [ "$1" = -o ]; then echo /dev/test-disk4; fi; }',
        "wrong-label": (
            'blkid() { if [ "$1" = -o ]; then echo /dev/test-disk4; else echo OTHER; fi; }'
        ),
        "no-disk": "candidate_disks() { return 0; }",
        "no-policy": (
            "function /usr/local/lib/libertix/libertix_installation_policy.py() { return 1; }"
        ),
    }[scenario]
    result = run_early_live(
        tmp_path, firmware, "\n" + setup + "\nwait_for_prereqs\necho PREREQUISITES_READY\n"
    )

    assert "CONTEXT_LOADED_WITHOUT_LABEL" in result.stdout, result.stderr
    assert result.returncode == (0 if scenario == "ready" else 1), result.stdout + result.stderr
    assert ("PREREQUISITES_READY" in result.stdout) == (scenario == "ready")
    assert "unbound variable" not in result.stderr
    if scenario in {"unlabeled", "wrong-label", "no-disk"}:
        assert "live prerequisites not ready after 60s" in result.stdout
    elif scenario == "no-policy":
        assert "staging volume label could not be loaded" in result.stdout


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
@pytest.mark.parametrize("required_settles", [1, 3])
def test_early_rollback_completes_real_state_after_disk_resolution(
    tmp_path: Path, firmware: str, required_settles: int
) -> None:
    command = r"""
REQUIRED_SETTLES="$5"
# Fail before the real mirroring implementation could mount a host filesystem.
# Successful mirror calls retain the actual atomic state publication in tmp_path.
mount() {
    [ "$1" = -t ] && [ "$2" = ntfs-3g ] && [ "$5" = /dev/test-disk2 ]
}
findmnt() { return 1; }
mkdir() {
    if [ "${@: -1}" = /mnt/libertix-state-mirror ]; then return 0; fi
    command mkdir "$@"
}
eval "$(declare -f publish_installation_state_mirror |
    sed '1s/publish_installation_state_mirror/publish_test_state_mirror/')"
publish_installation_state_mirror() {
    publish_test_state_mirror "$LOG_DIR/windows"
}
sync() { return 0; }
cleanup_live_mounts_best_effort() { return 0; }
swapoff() { return 0; }
restore_pre_grub_mbr_best_effort() { return 0; }
firmware_prepare_rollback_best_effort() { return 0; }
delete_transaction_partition_best_effort() { return 0; }
firmware_cleanup_partition_container_best_effort() { return 0; }
restore_windows_partition_best_effort() { echo PHYSICAL_RESTORE_SIMULATED; }
firmware_restore_boot_state_best_effort() { return 0; }
debug_disk_state() { return 0; }
fail_installation_state_best_effort 1 'early stage failure'
rollback_windows_layout_best_effort
""".replace('REQUIRED_SETTLES="$5"', f"REQUIRED_SETTLES={required_settles}")
    result = run_early_live(tmp_path, firmware, command)

    assert "CONTEXT_LOADED_WITHOUT_LABEL" in result.stdout, result.stderr
    assert result.returncode == 0, result.stdout + result.stderr
    assert int((tmp_path / "settles").read_text()) == required_settles
    runtime_state = json.loads((tmp_path / "installation-state.json").read_text())
    mirror = tmp_path / "windows/ProgramData/Libertix/Recovery/installation-state.json"
    assert json.loads(mirror.read_text()) == runtime_state
    assert runtime_state["status"] == "rolled-back"
    assert runtime_state["compensatedSteps"] == list(reversed(runtime_state["completedSteps"][2:]))
    assert runtime_state["failure"]["message"] == "early stage failure"
