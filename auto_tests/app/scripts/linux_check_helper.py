"""Read-only JSON checks run on the installed Linux system by the auto-test controller.

Usage: python3 linux_check_helper.py COMMAND [ARGUMENTS...]
Each command exits with status 0 on success and prints the failed expectation otherwise.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import time
from pathlib import Path


class CheckFailed(Exception):
    pass


def load_json(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def require(condition: bool, message: str) -> None:
    if not condition:
        raise CheckFailed(message)


def require_equal(actual: object, expected: object, field: str) -> None:
    require(actual == expected, f"{field}: expected {expected!r}, found {actual!r}")


def desktop_source(locale: dict) -> str:
    variant = locale.get("keyboardVariant")
    return locale["keyboardLayout"] + ("+" + variant if variant else "")


def result_fingerprint(state: dict) -> str:
    fields = {
        key: state.get(key) for key in ("planId", "status", "updatedAtUtc", "error", "attemptId")
    }
    return hashlib.sha256(json.dumps(fields, sort_keys=True).encode()).hexdigest()


def print_json_value(args: argparse.Namespace) -> int:
    value = load_json(args.file)
    keys = args.key.split(".")
    for key in keys[:-1]:
        value = value[key]
    print(value.get(keys[-1], "") if args.optional else value[keys[-1]])
    return 0


def wait_first_boot_verification(args: argparse.Namespace) -> int:
    for _ in range(args.attempts):
        try:
            status = load_json(args.state).get("status", "")
        except (OSError, ValueError, AttributeError):
            status = ""
        if status in {"succeeded", "failed"}:
            break
        time.sleep(args.interval)
    state = load_json(args.state)
    failed = [
        {"name": check.get("name"), "message": check.get("message")}
        for check in state.get("checks", [])
        if not check.get("passed")
    ]
    summary = {"status": state.get("status"), "error": state.get("error"), "failedChecks": failed}
    print(json.dumps(summary, ensure_ascii=True))
    return 0 if state.get("status") == "succeeded" else 1


def check_result_acknowledged(_args: argparse.Namespace) -> int:
    ack = load_json(Path.home() / ".local/state/libertix/first-boot-result-ack.json")
    require_equal(ack["schemaVersion"], 1, "schemaVersion")
    require_equal(len(ack["fingerprint"]), 64, "fingerprint length")
    return 0


def check_keyboard_marker(args: argparse.Namespace) -> int:
    locale = load_json(args.plan)["locale"]
    marker = load_json(args.marker)
    require_equal(marker["status"], "succeeded", "marker status")
    require_equal(marker["sessionLanguage"], locale["systemLanguage"], "marker sessionLanguage")
    require_equal(marker["desktopSource"], desktop_source(locale), "marker desktopSource")
    return 0


def check_first_boot_evidence(args: argparse.Namespace) -> int:
    state = load_json(args.state)
    plan = load_json(args.plan)
    ack = load_json(args.ack)
    system = state["system"]
    require_equal(state["schemaVersion"], 1, "schemaVersion")
    require_equal(state["status"], "succeeded", "status")
    require_equal(state["planId"], plan["planId"], "planId")
    require(not state.get("error"), f"error: {state.get('error')!r}")
    require_equal(state["distribution"]["id"], args.distribution, "distribution.id")
    require_equal(state["distribution"]["osReleaseId"], args.os_release_id, "osReleaseId")
    require_equal(state["root"]["filesystem"], "ext4", "root.filesystem")
    require_equal(system["username"], args.username, "system.username")
    for flag in ("rootReadWrite", "sudoMember", "passwordActive", "dpkgAuditClean"):
        require(system[flag] is True, f"system.{flag} is not true")
    require_equal(system["failedSystemdUnits"], 0, "system.failedSystemdUnits")

    locale = plan["locale"]
    localization = state["localization"]
    expected_locales = sorted(
        {locale["systemLanguage"].casefold().replace("utf-8", "utf8"), "en_us.utf8"}
    )
    require(localization["verified"] is True, "localization.verified is not true")
    expected_localization = {
        "languageCode": locale["languageCode"],
        "systemLocale": locale["systemLanguage"],
        "compiledUtf8Locales": expected_locales,
        "keyboardLayout": locale["keyboardLayout"],
        "keyboardVariant": locale.get("keyboardVariant", ""),
        "keyboardModel": locale["keyboardModel"],
        "desktopSource": desktop_source(locale),
    }
    for field, expected in expected_localization.items():
        require_equal(localization[field], expected, f"localization.{field}")
    require(state["grub"]["bootChain"]["verified"] is True, "grub.bootChain.verified is not true")
    require(bool(state.get("windowsEvidencePath")), "windowsEvidencePath is missing")

    # The acknowledgement proves the user saw this exact verification result.
    fingerprint = result_fingerprint(state)
    require_equal(ack["fingerprint"], fingerprint, "acknowledgement fingerprint")
    return 0


def parse_arguments(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)

    value = commands.add_parser("json-value", help="print one dotted key from a JSON file")
    value.add_argument("file")
    value.add_argument("key")
    value.add_argument(
        "--optional", action="store_true", help="print '' when the last key is absent"
    )
    value.set_defaults(handler=print_json_value)

    wait = commands.add_parser("wait-first-boot-verification")
    wait.add_argument("state")
    wait.add_argument("--attempts", type=int, default=120)
    wait.add_argument("--interval", type=float, default=2)
    wait.set_defaults(handler=wait_first_boot_verification)

    acknowledged = commands.add_parser("result-acknowledged")
    acknowledged.set_defaults(handler=check_result_acknowledged)

    keyboard = commands.add_parser("keyboard-marker")
    keyboard.add_argument("plan")
    keyboard.add_argument("marker")
    keyboard.set_defaults(handler=check_keyboard_marker)

    evidence = commands.add_parser("first-boot-evidence")
    for name in ("state", "plan", "ack", "distribution", "os_release_id", "username"):
        evidence.add_argument(name)
    evidence.set_defaults(handler=check_first_boot_evidence)
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_arguments(argv)
    try:
        return args.handler(args)
    except CheckFailed as failure:
        print(f"CHECK FAILED: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
