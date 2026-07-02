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
