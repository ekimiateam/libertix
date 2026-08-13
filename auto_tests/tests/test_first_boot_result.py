from __future__ import annotations

import importlib.util
from pathlib import Path
from types import ModuleType

import pytest

ROOT = Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def result_ui() -> ModuleType:
    path = ROOT / "assets/live/libertix-first-boot-result.py"
    spec = importlib.util.spec_from_file_location("libertix_first_boot_result", path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_all_supported_languages_have_success_and_failure_messages(result_ui: ModuleType) -> None:
    assert set(result_ui.TRANSLATIONS) == {"en", "fr", "es", "ja"}
    for translation in result_ui.TRANSLATIONS.values():
        assert all(translation[key].strip() for key in translation)


def test_acknowledgement_fingerprint_changes_with_terminal_result(result_ui: ModuleType) -> None:
    success = {
        "planId": "a" * 32,
        "status": "succeeded",
        "updatedAtUtc": "2026-08-12T10:00:00Z",
        "error": None,
    }
    failure = dict(success, status="failed", error="GRUB invalid")

    assert result_ui.status_fingerprint(success) != result_ui.status_fingerprint(failure)


def test_dialog_uses_a_modal_provider_before_notifications(
    result_ui: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[list[str]] = []
    monkeypatch.setattr(result_ui, "show_gtk_dialog", lambda *_args: False)
    monkeypatch.setattr(
        result_ui.shutil,
        "which",
        lambda name: f"/usr/bin/{name}" if name in {"zenity", "notify-send"} else None,
    )

    class Completed:
        returncode = 0

    def fake_run(command: list[str], check: bool) -> Completed:
        assert check is False
        calls.append(command)
        return Completed()

    monkeypatch.setattr(result_ui.subprocess, "run", fake_run)

    assert result_ui.show_dialog("Verified", "Everything is valid", False) is True
    assert calls[0][0] == "zenity"
    assert "--info" in calls[0]


def test_dialog_prefers_keep_above_gtk_provider(
    result_ui: ModuleType, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[tuple[str, str, bool]] = []
    monkeypatch.setattr(
        result_ui,
        "show_gtk_dialog",
        lambda title, message, failed: calls.append((title, message, failed)) or True,
    )
    monkeypatch.setattr(
        result_ui.subprocess,
        "run",
        lambda *_args, **_kwargs: pytest.fail("fallback provider must not run"),
    )

    assert result_ui.show_dialog("Verified", "Everything is valid", False) is True
    assert calls == [("Verified", "Everything is valid", False)]
