import json
from pathlib import Path

import httpx
import pytest
from PIL import Image

from app.clients.vision_llm import INSTALL_PROGRESS_SYSTEM_PROMPT, VisionLLMClient
from app.errors import WorkflowError


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


def test_install_progress_fallback_never_uses_prompt_assignments_as_evidence() -> None:
    reasoning = """
    Schema rule: installation_finished=true when complete.
    Fields to determine: reboot_prompt_visible=true.
    The image is a Windows desktop showing Downloading Mint ISO... 42%.
    Visible text: Downloading Mint ISO... 42% 1.2GiB/2.8GiB ETA 4m.
    """

    verdict = VisionLLMClient._progress_from_reasoning_text(reasoning)  # noqa: SLF001

    assert verdict["analysis_source"] == "reasoning_fallback"
    assert verdict["installation_finished"] is False
    assert verdict["reboot_prompt_visible"] is False
    assert verdict["still_in_progress"] is True


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


def test_install_progress_fallback_does_not_turn_negative_error_text_into_error() -> None:
    reasoning = """
    Scene: Libertix installer.
    Downloading Mint ISO... 35%
    1.0GiB/2.8GiB (35%), ETA 29m52s.
    Aucun message d'erreur n'est présent et aucune invite de redémarrage n'est visible.
    error_visible: false
    """

    verdict = VisionLLMClient._progress_from_reasoning_text(reasoning)  # noqa: SLF001

    assert verdict["still_in_progress"] is True
    assert verdict["error_visible"] is False


def test_install_progress_fallback_accepts_final_reboot_screen() -> None:
    reasoning = """
    Visible text:
    Partitionnement termine !
    100%
    Boot entry configured successfully.
    GRUB4DOS installed.
    Next reboot will automatically boot Install Linux.
    Buttons: Retour, Redemarrer.
    The model accidentally writes still_in_progress: true later in its reasoning.
    error_visible: false
    """

    verdict = VisionLLMClient._progress_from_reasoning_text(reasoning)  # noqa: SLF001

    assert verdict["iso_download_finished"] is True
    assert verdict["installation_finished"] is True
    assert verdict["reboot_prompt_visible"] is True
    assert verdict["still_in_progress"] is False
    assert verdict["error_visible"] is False


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


def test_install_progress_reads_only_complete_json_from_reasoning(
    monkeypatch, tmp_path: Path
) -> None:
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
    verdict = VisionLLMClient(
        "key", "https://example.test/v1", "thinking-model", 1, max_attempts=1
    ).analyze_install_progress(image, "vm2", "Windows UEFI")

    assert verdict.analysis_source == "reasoning_json"
    assert verdict.installation_finished is False
    assert verdict.still_in_progress is True
    assert verdict.visible_text == "Extraction de Mint 54%"


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


def test_install_progress_uses_short_english_prompt_and_thinking_budget(
    monkeypatch, tmp_path: Path
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
        "key", "https://example.test/v1", "thinking-model", 1, max_attempts=1
    ).analyze_install_progress(image, "vm2", "Windows UEFI")

    messages = captured_payload["messages"]
    assert isinstance(messages, list)
    assert messages[0]["content"] == INSTALL_PROGRESS_SYSTEM_PROMPT
    assert len(INSTALL_PROGRESS_SYSTEM_PROMPT) < 1400
    assert captured_payload["max_tokens"] == 2048


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


def test_wizard_reasoning_uses_only_complete_verdict_json() -> None:
    reasoning = """
    Prompt mentions {detected_screen: account} but this is not JSON evidence.
    Final answer:
    {"detected_screen":"distro","expected_screen_visible":false,
     "no_blocking_error":true,"visible_text":["Linux Mint 22.3", "Suivant"]}
    """

    verdict = VisionLLMClient._load_wizard_json(reasoning)  # noqa: SLF001

    assert verdict["detected_screen"] == "distro"
    assert verdict["expected_screen_visible"] is False
    assert verdict["username_visible"] is False
    assert verdict["password_fields_filled"] is False
    assert verdict["visible_text"] == "Linux Mint 22.3\nSuivant"


def test_wizard_normalizes_bare_false_when_account_evidence_is_complete(
    monkeypatch, tmp_path: Path
) -> None:
    image = tmp_path / "screen.png"
    Image.new("RGB", (32, 32), "white").save(image)
    content = json.dumps(
        {
            "detected_screen": "account",
            "expected_screen_visible": True,
            "no_blocking_error": False,
            "username_visible": True,
            "password_fields_filled": True,
            "summary": "Compte et champs remplis; aucune erreur visible.",
            "visible_text": "Créez votre compte Linux test Mot de passe Confirmer le mot de passe",
        }
    )

    def fake_post(*_args, **_kwargs):
        return httpx.Response(
            200,
            json={"choices": [{"message": {"content": content}}]},
            request=httpx.Request("POST", "https://example.test"),
        )

    monkeypatch.setattr(httpx, "post", fake_post)
    verdict = VisionLLMClient("key", "https://example.test/v1", "model", 1).analyze_wizard_state(
        image,
        "vm3",
        "Windows 11 UEFI",
        expected_screen="account",
        expected_username="test",
    )

    assert verdict.no_blocking_error is True
