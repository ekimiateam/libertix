import json
from pathlib import Path

import httpx
import pytest
from PIL import Image

from app.clients.vision_llm import INSTALL_PROGRESS_SYSTEM_PROMPT, VisionLLMClient
from app.clients.vision_models import contains_final_reboot_prompt
from app.errors import WorkflowError


def test_install_progress_accepts_llm_json_without_visible_text(
    monkeypatch, tmp_path: Path
) -> None:
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
    verdict = VisionLLMClient(
        "key", "https://example.test/v1", "model", 1
    ).analyze_install_progress(image, "vm1", "Windows")

    assert verdict.still_in_progress is True
    assert verdict.visible_text


def test_install_progress_rejects_complete_json_from_reasoning(monkeypatch, tmp_path: Path) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    final_json = json.dumps(
        {
            "iso_download_finished": False,
            "installation_finished": False,
            "reboot_prompt_visible": False,
            "still_in_progress": True,
            "error_visible": False,
            "summary": "Mint extraction is still running.",
            "visible_text": "Extraction de Mint 54%",
        }
    )
    reasoning = (
        "The schema says installation_finished=true when complete. "
        "This sentence is reasoning and must not drive the verdict.\n"
        f"Final answer:\n{final_json}"
    )

    def fake_post(*_args, **_kwargs):
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": None, "reasoning": reasoning}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    with pytest.raises(WorkflowError):
        VisionLLMClient(
            "key", "https://example.test/v1", "thinking-model", 1, max_attempts=1
        ).analyze_install_progress(image, "vm2", "Windows UEFI")


def test_install_progress_does_not_infer_state_from_reasoning_prose(
    monkeypatch, tmp_path: Path
) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    reasoning = (
        "The screenshot shows Downloading Mint ISO 42%. "
        "still_in_progress should therefore be true, but no final JSON was produced."
    )

    def fake_post(*_args, **_kwargs):
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": None, "reasoning": reasoning}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    with pytest.raises(WorkflowError):
        VisionLLMClient(
            "key", "https://example.test/v1", "thinking-model", 1, max_attempts=1
        ).analyze_install_progress(image, "vm2", "Windows UEFI")


def test_install_progress_prefers_final_content_over_reasoning(monkeypatch, tmp_path: Path) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    content = json.dumps(
        {
            "iso_download_finished": False,
            "installation_finished": False,
            "reboot_prompt_visible": False,
            "still_in_progress": True,
            "error_visible": False,
            "summary": "Download is active.",
            "visible_text": "Downloading Mint ISO... 42%",
        }
    )
    contradictory_reasoning = json.dumps(
        {
            "iso_download_finished": True,
            "installation_finished": True,
            "reboot_prompt_visible": True,
            "still_in_progress": False,
            "error_visible": False,
            "summary": "Wrong reasoning verdict.",
            "visible_text": "Redemarrer 100%",
        }
    )

    def fake_post(*_args, **_kwargs):
        return httpx.Response(
            200,
            json={
                "choices": [
                    {
                        "message": {
                            "content": content,
                            "reasoning": contradictory_reasoning,
                        }
                    }
                ]
            },
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    verdict = VisionLLMClient(
        "key", "https://example.test/v1", "thinking-model", 1, max_attempts=1
    ).analyze_install_progress(image, "vm2", "Windows UEFI")

    assert verdict.analysis_source == "strict_json"
    assert verdict.installation_finished is False
    assert verdict.still_in_progress is True


@pytest.mark.parametrize(
    ("api_url", "reasoning_key", "reasoning_value"),
    [
        ("https://openrouter.ai/api/v1", "reasoning", {"effort": "medium"}),
        ("http://example.test:8000/v1", "reasoning_effort", "medium"),
    ],
)
@pytest.mark.parametrize("provider_only", [None, "openai/flex"])
def test_install_progress_uses_short_english_prompt_and_thinking_budget(
    monkeypatch, tmp_path: Path, api_url, reasoning_key, reasoning_value, provider_only
) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    captured_payload: dict[str, object] = {}
    content = json.dumps(
        {
            "iso_download_finished": False,
            "installation_finished": False,
            "reboot_prompt_visible": False,
            "still_in_progress": True,
            "error_visible": False,
            "summary": "Waiting for the next visible state.",
            "visible_text": "Downloading Mint ISO... 10%",
        }
    )

    def fake_post(*_args, **kwargs):
        captured_payload.update(kwargs["json"])
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": content}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    VisionLLMClient(
        "key",
        api_url,
        "thinking-model",
        1,
        reasoning_effort="medium",
        provider_only=provider_only,
        max_attempts=1,
    ).analyze_install_progress(image, "vm2", "Windows UEFI")

    messages = captured_payload["messages"]
    assert isinstance(messages, list)
    assert messages[0]["content"] == INSTALL_PROGRESS_SYSTEM_PROMPT
    assert len(INSTALL_PROGRESS_SYSTEM_PROMPT) < 1400
    assert captured_payload["max_tokens"] == 2048
    assert captured_payload[reasoning_key] == reasoning_value
    other_key = "reasoning_effort" if reasoning_key == "reasoning" else "reasoning"
    assert other_key not in captured_payload
    if reasoning_key == "reasoning":
        assert captured_payload["provider"]["require_parameters"] is True
        if provider_only:
            assert captured_payload["provider"]["only"] == [provider_only]
            assert captured_payload["provider"]["allow_fallbacks"] is False
        else:
            assert "only" not in captured_payload["provider"]
    else:
        assert "provider" not in captured_payload


def test_install_progress_normalizes_contradictory_final_reboot_json(
    monkeypatch, tmp_path: Path
) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    content = json.dumps(
        {
            "iso_download_finished": True,
            "installation_finished": False,
            "reboot_prompt_visible": False,
            "still_in_progress": True,
            "error_visible": False,
            "summary": "La préparation UEFI est réussie mais probablement intermédiaire.",
            "visible_text": "Partitionnement terminé ! 100% Retour Redémarrer",
        }
    )

    def fake_post(*_args, **_kwargs):
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": content}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    verdict = VisionLLMClient(
        "key", "https://example.test/v1", "model", 1
    ).analyze_install_progress(image, "vm2", "Windows 10 UEFI")

    assert verdict.installation_finished is True
    assert verdict.reboot_prompt_visible is True
    assert verdict.still_in_progress is False


@pytest.mark.parametrize("corrected", [True, False])
@pytest.mark.parametrize("api_url", ["https://openrouter.ai/api/v1", "http://example.test:8000/v1"])
def test_invalid_windows_path_requests_format_correction(
    monkeypatch, tmp_path: Path, caplog, corrected, api_url
) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    valid = json.dumps(
        {
            "iso_download_finished": False,
            "installation_finished": False,
            "reboot_prompt_visible": False,
            "still_in_progress": True,
            "error_visible": False,
            "summary": "Copying the UEFI installer.",
            "visible_text": r"Copying to D:\ UEFI copy phase",
        }
    )
    invalid = valid.replace("\\\\", "\\")
    calls = []
    delays = []

    def fake_post(*_args, **kwargs):
        calls.append(json.loads(json.dumps(kwargs["json"])))
        content = valid if corrected and len(calls) > 1 else invalid
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": content}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    monkeypatch.setattr("app.clients.vision_llm.time.sleep", delays.append)
    client = VisionLLMClient("key", api_url, "model", 1)
    if corrected:
        verdict = client.analyze_install_progress(image, "vm3", "Windows UEFI")
        assert verdict.visible_text == r"Copying to D:\ UEFI copy phase"
        assert len(calls) == 2 and delays == [3]
    else:
        with pytest.raises(WorkflowError) as failure:
            client.analyze_install_progress(image, "vm3", "Windows UEFI")
        assert failure.value.details["attempt"] == 3
        assert len(calls) == 3 and delays == [3, 6]
    assert calls[1]["messages"][-2] == {"role": "assistant", "content": invalid}
    correction = calls[1]["messages"][-1]
    assert correction["role"] == "user"
    assert "Escape backslashes" in correction["content"]
    feedback = [record for record in caplog.records if record.step == "llm.format_correction"]
    assert len(feedback) == len(calls) - 1


@pytest.mark.parametrize(
    "visible_text",
    [
        "Partitionnement termine ! 100% Redemarrer",
        "Partitioning complete! 100% Reboot",
        "Particionamiento completado! 100% Reiniciar",
    ],
)
def test_final_reboot_prompt_is_detected_in_every_supported_language(visible_text: str) -> None:
    assert contains_final_reboot_prompt(visible_text)


def test_install_progress_never_hides_error_during_active_download(
    monkeypatch, tmp_path: Path
) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    content = json.dumps(
        {
            "iso_download_finished": False,
            "installation_finished": False,
            "reboot_prompt_visible": False,
            "still_in_progress": True,
            "error_visible": True,
            "summary": "Libertix (Ne répond pas) pendant FileAlloc aria2.",
            "visible_text": (
                "Libertix (Ne répond pas). Downloading Linux ISO... 0%. "
                "[FileAlloc:#c04 1.4GiB/2.8GiB(51%)] "
                "aria2 Linux installer ISO: FILE: "
                "C:/Users/admin/AppData/Local/Temp/Libertix/mint.iso"
            ),
        }
    )

    def fake_post(*_args, **_kwargs):
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": content}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    verdict = VisionLLMClient(
        "key", "https://example.test/v1", "model", 1
    ).analyze_install_progress(image, "vm1", "Windows")

    assert verdict.still_in_progress is True
    assert verdict.error_visible is True


def test_install_progress_ignores_finished_flags_during_bitlocker_decryption(
    monkeypatch, tmp_path: Path
) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    content = json.dumps(
        {
            "iso_download_finished": True,
            "installation_finished": True,
            "reboot_prompt_visible": True,
            "still_in_progress": False,
            "error_visible": False,
            "summary": (
                "Fallback LLM: no strict JSON returned; final state is not confidently detected."
            ),
            "visible_text": (
                "Déchiffrement de Windows C: 75%. "
                "OperatingSystem C: 63,01 DecryptionInProgress 36. "
                "Waiting for C: decryption... 12% encrypted."
            ),
        }
    )

    def fake_post(*_args, **_kwargs):
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": content}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    verdict = VisionLLMClient(
        "key", "https://example.test/v1", "model", 1
    ).analyze_install_progress(image, "vm3", "Windows 11 UEFI")

    assert verdict.iso_download_finished is False
    assert verdict.installation_finished is False
    assert verdict.reboot_prompt_visible is False
    assert verdict.still_in_progress is True
