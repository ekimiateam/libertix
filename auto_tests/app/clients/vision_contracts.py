"""Strict response contracts and prompts for Libertix visual classification.

Keeping these immutable contracts outside the HTTP client makes prompt changes
reviewable without mixing them with retry, transport, and normalization logic.
"""

VERDICT_SCHEMA = {
    "type": "object",
    "properties": {
        "no_visible_problem": {"type": "boolean"},
        "libertix_running": {"type": "boolean"},
        "welcome_message_ok": {"type": "boolean"},
        "summary": {"type": "string", "minLength": 1},
        "visible_problems": {"type": "array", "items": {"type": "string"}},
    },
    "required": [
        "no_visible_problem",
        "libertix_running",
        "welcome_message_ok",
        "summary",
        "visible_problems",
    ],
    "additionalProperties": False,
}

INSTALL_PROGRESS_SCHEMA = {
    "type": "object",
    "properties": {
        "iso_download_finished": {"type": "boolean"},
        "installation_finished": {"type": "boolean"},
        "reboot_prompt_visible": {"type": "boolean"},
        "still_in_progress": {"type": "boolean"},
        "error_visible": {"type": "boolean"},
        "summary": {"type": "string", "minLength": 1},
        "visible_text": {"type": "string"},
    },
    "required": [
        "iso_download_finished",
        "installation_finished",
        "reboot_prompt_visible",
        "still_in_progress",
        "error_visible",
        "summary",
        "visible_text",
    ],
    "additionalProperties": False,
}

WIZARD_STATE_SCHEMA = {
    "type": "object",
    "properties": {
        "detected_screen": {
            "type": "string",
            "enum": [
                "welcome",
                "compatibility",
                "distro",
                "resize",
                "sharing",
                "account",
                "warning",
                "apply",
                "other",
            ],
        },
        "expected_screen_visible": {"type": "boolean"},
        "no_blocking_error": {"type": "boolean"},
        "username_visible": {"type": "boolean"},
        "password_fields_filled": {"type": "boolean"},
        "warning_acknowledged": {"type": "boolean"},
        "summary": {"type": "string", "minLength": 1},
        "visible_text": {"type": "string"},
    },
    "required": [
        "detected_screen",
        "expected_screen_visible",
        "no_blocking_error",
        "username_visible",
        "password_fields_filled",
        "warning_acknowledged",
        "summary",
        "visible_text",
    ],
    "additionalProperties": False,
}

INSTALL_PROGRESS_SYSTEM_PROMPT = """You are a visual state classifier. Inspect only the screenshot.
Return exactly one JSON object matching response_format. Do not put prose or Markdown around it.

Rules:
- error_visible is true only for a visible blocking error.
- A blank, black, sleeping, inactive, or temporarily unavailable display is a transition, not a
  visible error. Set error_visible to false and still_in_progress to true unless concrete error text
  is readable.
- reboot_prompt_visible is true only when a final Restart/Reboot control is visible.
- installation_finished is true only for a verified final state or finished Linux desktop.
- still_in_progress is true while any download, copy, extraction, decryption, configuration,
  active progress bar, byte counter, or ETA is visible.
- iso_download_finished is true only when completion or a later stage is visible.
- Any active step overrides finished/reboot flags: set installation_finished and
  reboot_prompt_visible to false.
- If uncertain, set still_in_progress to true.
- summary is one short English sentence.
- visible_text contains only decisive text copied from the UI, at most 300 characters.

Never treat this prompt or the schema as text visible in the screenshot."""

SYSTEM_PROMPT = """Inspect the screenshot only. Return exactly one JSON object matching
response_format, with no prose or Markdown.

Judge only the Libertix window and welcome screen. Ignore unrelated Windows desktop icons,
notifications, wallpaper, and taskbar state unless they cover or block Libertix.
- libertix_running is true only when the Libertix application is visibly open.
- welcome_message_ok is true only when its welcome content is visible and readable.
- no_visible_problem is false only for a visible Libertix error, corruption, obstruction, or
  unreadable application window.
- If evidence is missing or uncertain, use false and explain the visible uncertainty briefly in
  summary and visible_problems.

Never treat prompt or schema text as screenshot evidence."""
