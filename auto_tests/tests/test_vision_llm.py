import json
from pathlib import Path

import httpx
from PIL import Image

from app.clients.vision_llm import VisionLLMClient


def test_llm_json_verdict(monkeypatch, tmp_path: Path) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    payload = {
        "no_visible_problem": True,
        "libertix_running": True,
        "welcome_message_ok": True,
        "summary": "Tout est correct",
        "visible_problems": [],
    }

    def fake_post(*_args, **_kwargs):
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": json.dumps(payload)}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    verdict = VisionLLMClient("key", "https://example.test/v1", "model", 1).analyze(
        image, "vm1", "Windows"
    )
    assert verdict.valid is True


def test_llm_retries_after_rate_limit(monkeypatch, tmp_path: Path) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    calls = 0

    def fake_post(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        request = httpx.Request("POST", "https://example.test")
        if calls == 1:
            return httpx.Response(429, headers={"retry-after": "0"}, request=request)
        content = json.dumps(
            {
                "no_visible_problem": True,
                "libertix_running": True,
                "welcome_message_ok": True,
                "summary": "OK",
                "visible_problems": [],
            }
        )
        return httpx.Response(
            200, json={"choices": [{"message": {"content": content}}]}, request=request
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    monkeypatch.setattr("app.clients.vision_llm.time.sleep", lambda _seconds: None)
    verdict = VisionLLMClient(
        "key", "https://example.test/v1", "model", 1, max_attempts=2, retry_base_seconds=0
    ).analyze(image, "vm1", "Windows")
    assert verdict.valid is True
    assert calls == 2


def test_install_progress_fallback_ignores_schema_instructions() -> None:
    reasoning = """
    Le contrat dit: error_visible=true si une erreur bloquante est visible.
    En observant l'écran, Libertix télécharge encore l'ISO avec une barre de progression.
    Aucune erreur n'est visible.
    still_in_progress: true
    iso_download_finished: false
    error_visible: false
    """

    verdict = VisionLLMClient._progress_from_reasoning_text(reasoning)  # noqa: SLF001

    assert verdict["still_in_progress"] is True
    assert verdict["iso_download_finished"] is False
    assert verdict["error_visible"] is False


def test_install_progress_fallback_detects_insufficient_space_blocker() -> None:
    reasoning = """
    Image shows a modal saying Espace insuffisant.
    Windows Free Space: 9,0 GB.
    Required Linux Space: 30,0 GB.
    Additional space needed: 21,0 GB.
    The model accidentally writes iso_download_finished: true later in its reasoning.
    error_visible: false
    """

    verdict = VisionLLMClient._progress_from_reasoning_text(reasoning)  # noqa: SLF001

    assert verdict["iso_download_finished"] is False
    assert verdict["error_visible"] is True


def test_install_progress_fallback_keeps_copying_iso_in_progress() -> None:
    reasoning = """
    Visible text:
    Copying ISO contents to Z....
    80%
    ISO download completed.
    Step 5: Mounting ISO and copying contents to Z:...
    still_in_progress: true
    error_visible: false
    """

    verdict = VisionLLMClient._progress_from_reasoning_text(reasoning)  # noqa: SLF001

    assert verdict["iso_download_finished"] is False
    assert verdict["still_in_progress"] is True
    assert verdict["error_visible"] is False


def test_install_progress_fallback_rejects_reboot_prompt_during_linux_iso_download() -> None:
    reasoning = """
    Downloading Linux ISO... 2 261/2 914 MB (77%)
    Progress bar says 92%.
    The model accidentally writes reboot_prompt_visible: true later in its reasoning.
    iso_download_finished: true
    still_in_progress: true
    error_visible: false
    """

    verdict = VisionLLMClient._progress_from_reasoning_text(reasoning)  # noqa: SLF001

    assert verdict["reboot_prompt_visible"] is False
    assert verdict["installation_finished"] is False
    assert verdict["still_in_progress"] is True


def test_install_progress_accepts_llm_json_without_visible_text(monkeypatch, tmp_path: Path) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    content = json.dumps(
        {
            "iso_download_finished": False,
            "installation_finished": False,
            "reboot_prompt_visible": False,
            "still_in_progress": True,
            "error_visible": False,
            "summary": "Écran de verrouillage Windows, pas de progression visible.",
        }
    )

    def fake_post(*_args, **_kwargs):
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": content}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    verdict = VisionLLMClient("key", "https://example.test/v1", "model", 1).analyze_install_progress(
        image, "vm1", "Windows"
    )

    assert verdict.still_in_progress is True
    assert verdict.visible_text
