from __future__ import annotations

import subprocess
from collections.abc import Callable
from pathlib import Path

import pytest


@pytest.fixture
def run_shell_function() -> Callable[[Path, str, str], subprocess.CompletedProcess[str]]:
    """Source one shell library and invoke one exported function with literal arguments."""

    def run(
        library: Path,
        function_name: str,
        *arguments: str,
    ) -> subprocess.CompletedProcess[str]:
        command = 'source "$1"; shift; function_name="$1"; shift; "$function_name" "$@"'
        return subprocess.run(
            ["bash", "-c", command, "bash", str(library), function_name, *arguments],
            check=False,
            capture_output=True,
            text=True,
        )

    return run
