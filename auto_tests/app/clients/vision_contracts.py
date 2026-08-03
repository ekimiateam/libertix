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
        "summary": {"type": "string", "minLength": 1},
        "visible_text": {"type": "string"},
    },
    "required": [
        "detected_screen",
        "expected_screen_visible",
        "no_blocking_error",
        "username_visible",
        "password_fields_filled",
        "summary",
        "visible_text",
    ],
    "additionalProperties": False,
}

INSTALL_PROGRESS_SYSTEM_PROMPT = """You are a visual state classifier. Inspect only the screenshot.
Return exactly one JSON object matching response_format. Do not put prose or Markdown around it.

Rules:
- error_visible is true only for a visible blocking error.
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

SYSTEM_PROMPT = """Tu es un auditeur visuel strict chargé de valider l'écran de Libertix.

CONTRAT DE SORTIE ABSOLU ET OBLIGATOIRE :
- Ta réponse visible entière doit être UN SEUL objet JSON valide.
- Elle doit respecter exactement le JSON Schema fourni par response_format.
- N'ajoute aucun texte avant ou après l'objet JSON.
- N'utilise jamais de bloc Markdown, de balises, de commentaire ou de clé supplémentaire.
- Les cinq clés obligatoires sont : no_visible_problem, libertix_running,
  welcome_message_ok, summary et visible_problems.
- Les trois premières valeurs sont obligatoirement des booléens JSON true ou false,
  jamais des chaînes.
- visible_problems est obligatoirement un tableau JSON de chaînes.
- En cas de doute, d'écran illisible ou d'information non visible, utilise false et explique
  précisément le doute dans summary et visible_problems.

Inspecte réellement l'image. Ne déduis jamais qu'une application fonctionne uniquement parce que la
question le prétend. Le raisonnement interne peut être détaillé, mais la réponse visible finale doit
rester exclusivement l'objet JSON demandé.

PÉRIMÈTRE DE VALIDATION :
- Le verdict concerne uniquement la fenêtre Libertix, son lancement et son écran de bienvenue.
- Ignore les icônes du bureau Windows, raccourcis, croix rouges sur icônes réseau, barre des tâches,
  notifications système ou fond d'écran, sauf si ces éléments couvrent Libertix ou empêchent
  clairement de lire/utiliser l'application.
- no_visible_problem doit donc être false uniquement si un problème est visible dans Libertix
  lui-même, si Libertix est masqué/illisible, ou si une erreur bloque son écran d'accueil."""
