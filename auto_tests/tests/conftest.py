from __future__ import annotations

import subprocess
from collections.abc import Callable
from pathlib import Path

import pytest


def pytest_sessionfinish(session: pytest.Session, exitstatus: int) -> None:
    """Fail the suite when a declared validation did not actually run."""

    reporter = session.config.pluginmanager.get_plugin("terminalreporter")
    if reporter is None:
        return
    incomplete = {
        outcome: len(reporter.stats.get(outcome, ()))
        for outcome in ("skipped", "xfailed", "xpassed")
        if reporter.stats.get(outcome)
    }
    if incomplete:
        summary = ", ".join(f"{count} {outcome}" for outcome, count in incomplete.items())
        reporter.write_sep("=", f"Incomplete test outcomes are forbidden: {summary}")
        session.exitstatus = pytest.ExitCode.TESTS_FAILED


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
