from __future__ import annotations

import json
import os
import subprocess
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.mark.parametrize("function", ["prepare_workdir", "purge_chroot_apt_cache", "cleanup"])
@pytest.mark.parametrize("mount_state", ["inside", "root", "query-error", "detached"])
def test_build_cleanup_requires_a_successful_unmounted_proof(
    function: str,
    mount_state: str,
) -> None:
    source = (ROOT / "iso-tools/build-iso.sh").read_text()
    functions = []
    for name in [
        "assert_workdir_unmounted",
        "prepare_workdir",
        "purge_chroot_apt_cache",
        "cleanup",
    ]:
        functions.append(
            name + "() {" + source.split(name + "() {", 1)[1].split("\n}", 1)[0] + "\n}"
        )
    script = (
        "\n".join(functions)
        + r"""
WORKDIR=/var/lib/libertix-work/bios
unmount_chroot_filesystems() { return 0; }
rm() { echo REMOVE; }
mkdir() { echo CREATE; }
findmnt() {
    case "$MOUNT_STATE" in
        inside) echo "$WORKDIR/chroot/var/cache/apt/archives" ;;
        root) echo "$WORKDIR" ;;
        query-error) return 1 ;;
        detached) printf '%s\n' / /var/lib/libertix-work/bios-other ;;
    esac
}
"$FUNCTION"
"""
    )
    result = subprocess.run(
        ["bash", "-c", script],
        env={"PATH": "/usr/bin:/bin", "MOUNT_STATE": mount_state, "FUNCTION": function},
        capture_output=True,
        text=True,
        check=False,
        timeout=5,
    )
    assert (result.returncode == 0) == (mount_state == "detached")
    assert ("REMOVE" in result.stdout) == (mount_state == "detached")


def test_two_checkouts_use_separate_docker_images_and_volumes(tmp_path: Path) -> None:
    commands = tmp_path / "commands"
    commands.mkdir()
    docker = commands / "docker"
    docker.write_text(
        "#!/usr/bin/env python3\n"
        "import json, os, sys\n"
        "with open(os.environ['DOCKER_CALLS'], 'a') as stream:\n"
        "    stream.write(json.dumps(sys.argv[1:]) + '\\n')\n",
        encoding="utf-8",
    )
    docker.chmod(0o755)

    def run_checkout(name: str) -> list[list[str]]:
        checkout = tmp_path / name
        script = checkout / "iso-tools/build-isos-docker.sh"
        script.parent.mkdir(parents=True)
        script.write_bytes((ROOT / "iso-tools/build-isos-docker.sh").read_bytes())
        versions = checkout / "docker/iso-builder/versions.env"
        versions.parent.mkdir(parents=True)
        versions.write_bytes((ROOT / "docker/iso-builder/versions.env").read_bytes())
        (checkout / "libertix-installer-bios.iso").write_bytes(b"isolated-test-artifact")
        calls = checkout / "docker-calls.jsonl"
        environment = dict(
            os.environ, PATH=f"{commands}:{os.environ['PATH']}", DOCKER_CALLS=str(calls)
        )
        for _ in range(2):
            result = subprocess.run(
                ["bash", str(script), "bios"],
                env=environment,
                cwd=checkout,
                capture_output=True,
                text=True,
                check=False,
                timeout=15,
            )
            assert result.returncode == 0, result.stderr
            assert "RESULT OK" in result.stdout
        return [json.loads(line) for line in calls.read_text().splitlines()]

    with ThreadPoolExecutor(max_workers=2) as executor:
        left, right = list(executor.map(run_checkout, ["checkout-one", "checkout-two"]))

    def resources(calls: list[list[str]]) -> tuple[str, ...]:
        runs = [call for call in calls if call[0] == "run"]
        assert len(runs) == 2
        assert runs[0] == runs[1]
        volumes = [runs[0][i + 1] for i, value in enumerate(runs[0]) if value == "--volume"]
        image = runs[0][-2]
        build = next(call for call in calls if call[0] == "build")
        assert build[build.index("--tag") + 1] == image
        return *volumes, image

    left_resources, right_resources = resources(left), resources(right)
    assert len(left_resources) == 4
    assert all(a != b for a, b in zip(left_resources, right_resources, strict=True))
