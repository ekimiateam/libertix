import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("firmware", ["bios", "uefi"])
@pytest.mark.parametrize("direct_installer", [False, True])
def test_label_reaches_child_installer_and_prerequisite_label_scan(
    tmp_path: Path, firmware: str, direct_installer: bool
):
    context = (ROOT / "assets/live/libertix-live-context.sh").read_text()
    context = context.replace(
        "/usr/local/lib/libertix/libertix_installation_policy.py staging-volume-label",
        "printf '%s\\n' LTXINSTALL",
    )
    context_path = tmp_path / "context.sh"
    context_path.write_text(context)
    adapter = (ROOT / f"assets/live/libertix-{firmware}-adapter.sh").read_text()
    wait = adapter.split("wait_for_prereqs() {", 1)[1].split("\n}\n", 1)[0]
    wait = "wait_for_prereqs() {" + wait + "\n}\n"
    wait = wait.replace('-b "$candidate"', '-c "$candidate"')
    child = tmp_path / "child.sh"
    child.write_text(
        'set -euo pipefail\n. "$CONTEXT"\n'
        'mark() { :; }; die() { echo "$*" >&2; exit 1; }\n'
        "candidate_disks() { echo /dev/null; }; find() { :; }; udevadm() { :; }\n"
        'blkid() { if [ "$1" = -o ]; then echo /dev/null; else echo LTXINSTALL; fi; }\n'
        + wait
        + '\nwait_for_prereqs\nprintf "CHILD_LABEL=%s\\n" "$LIBERTIX_STAGING_VOLUME_LABEL"\n'
    )
    script = 'set -euo pipefail\nunset LIBERTIX_STAGING_VOLUME_LABEL\n. "$CONTEXT"\n'
    if not direct_installer:
        script += (
            "find_libertix_installation_plan() (\n"
            "load_libertix_staging_volume_label; echo /plan.json\n)\n"
            f"load_libertix_installation_plan() {{ INSTALLATION_FIRMWARE={firmware}; }}\n"
            "LOG_DIR=/run/libertix\n"
            f"load_libertix_live_context {firmware}\n"
            "bash -c 'test \"$LIBERTIX_STAGING_VOLUME_LABEL\" = LTXINSTALL'\n"
        )
    script += 'bash "$CHILD"\n'
    result = subprocess.run(
        ["bash", "-c", script],
        env={**os.environ, "CONTEXT": str(context_path), "CHILD": str(child)},
        capture_output=True,
        text=True,
        timeout=10,
        check=False,
    )
    assert result.returncode == 0, result.stderr
    assert "CHILD_LABEL=LTXINSTALL" in result.stdout
