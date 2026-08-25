from __future__ import annotations

import importlib.util
import json
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
    catalogue = json.loads(
        (ROOT / "Resources/Libertix.Translations.json").read_text(encoding="utf-8")
    )
    assert catalogue["supportedLanguages"] == ["en", "fr", "es", "ko"]
    for language in catalogue["supportedLanguages"]:
        translation = result_ui.load_translations(language)
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
    monkeypatch.setattr(result_ui, "show_gtk_dialog", lambda *_args, **_kwargs: False)
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
        lambda title, message, failed, **_kwargs: calls.append((title, message, failed)) or True,
    )
    monkeypatch.setattr(
        result_ui.subprocess,
        "run",
        lambda *_args, **_kwargs: pytest.fail("fallback provider must not run"),
    )

    assert result_ui.show_dialog("Verified", "Everything is valid", False) is True
    assert calls == [("Verified", "Everything is valid", False)]


def test_session_localization_proof_matches_the_installation_plan(
    result_ui: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "home"
    marker = home / ".config/libertix/keyboard-initialized.json"
    marker.parent.mkdir(parents=True)
    marker.write_text(
        json.dumps(
            {
                "status": "succeeded",
                "sessionLanguage": "fr_FR.UTF-8",
                "configuredLanguage": "fr_FR.UTF-8",
                "layout": "fr",
                "variant": "",
                "desktopSource": "fr",
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(result_ui.Path, "home", lambda: home)
    plan = {
        "locale": {
            "systemLanguage": "fr_FR.UTF-8",
            "keyboardLayout": "fr",
            "keyboardVariant": "",
        }
    }

    assert result_ui.wait_for_session_localization(plan) is None


def test_session_localization_proof_rejects_an_unexpected_input_source(
    result_ui: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    home = tmp_path / "home"
    marker = home / ".config/libertix/keyboard-initialized.json"
    marker.parent.mkdir(parents=True)
    marker.write_text(
        json.dumps(
            {
                "status": "succeeded",
                "sessionLanguage": "fr_FR.UTF-8",
                "configuredLanguage": "fr_FR.UTF-8",
                "layout": "us",
                "variant": "",
                "desktopSource": "us",
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(result_ui.Path, "home", lambda: home)
    plan = {
        "locale": {
            "systemLanguage": "fr_FR.UTF-8",
            "keyboardLayout": "fr",
            "keyboardVariant": "",
        }
    }

    assert "differs" in result_ui.wait_for_session_localization(plan)


def test_session_localization_failure_is_not_acknowledged(
    result_ui: ModuleType, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    plan = {
        "planId": "a" * 32,
        "account": {"username": "test"},
        "locale": {
            "languageCode": "fr",
            "systemLanguage": "fr_FR.UTF-8",
            "keyboardLayout": "fr",
            "keyboardVariant": "",
        },
    }
    status = {
        "planId": plan["planId"],
        "status": "succeeded",
        "updatedAtUtc": "2026-08-13T00:00:00Z",
        "error": None,
        "logPath": "/var/log/libertix/first-boot-resize.log",
    }
    home = tmp_path / "home"
    monkeypatch.setattr(result_ui, "PLAN_PATH", tmp_path / "plan.json")
    monkeypatch.setattr(result_ui, "STATUS_PATH", tmp_path / "status.json")
    monkeypatch.setattr(result_ui.Path, "home", lambda: home)
    monkeypatch.setattr(
        result_ui.pwd, "getpwuid", lambda _uid: type("User", (), {"pw_name": "test"})()
    )
    monkeypatch.setattr(result_ui.os, "getuid", lambda: 1000)
    monkeypatch.setattr(result_ui.time, "sleep", lambda _seconds: None)
    monkeypatch.setattr(result_ui, "wait_for_session_localization", lambda _plan: "mismatch")
    monkeypatch.setattr(result_ui, "show_dialog", lambda *_args: True)
    monkeypatch.setenv("DISPLAY", ":0")
    result_ui.PLAN_PATH.write_text(json.dumps(plan), encoding="utf-8")
    result_ui.STATUS_PATH.write_text(json.dumps(status), encoding="utf-8")

    assert result_ui.main() == 0
    assert not (home / ".local/state/libertix/first-boot-result-ack.json").exists()
