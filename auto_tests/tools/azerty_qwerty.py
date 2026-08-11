#!/usr/bin/env python3
"""Translate text between physical French AZERTY and US QWERTY key positions.

The converter models what appears when a physical keyboard layout differs from
the layout selected by the guest OS. VNC automation uses it before sending text
so commands keep their intended characters without changing the guest layout.

Examples:
    python azerty_qwerty.py "salut mon claude"
    python azerty_qwerty.py --reverse "sqlut ;on clqude"
    python azerty_qwerty.py --selftest

The mapping follows Set 1 scan-code positions for legacy French AZERTY and US
layouts. Dead keys are handled explicitly. AltGr characters cannot always be
represented on US QWERTY; ``--altgr`` controls that case.
"""

from __future__ import annotations

import argparse
import sys
import unicodedata

# Each row describes one physical key as:
# (scan code, FR base, FR shift, FR AltGr, US base, US shift).
KEYS = [
    (0x29, "²", None, None, "`", "~"),
    (0x02, "&", "1", None, "1", "!"),
    (0x03, "é", "2", "~", "2", "@"),
    (0x04, '"', "3", "#", "3", "#"),
    (0x05, "'", "4", "{", "4", "$"),
    (0x06, "(", "5", "[", "5", "%"),
    (0x07, "-", "6", "|", "6", "^"),
    (0x08, "è", "7", "`", "7", "&"),
    (0x09, "_", "8", "\\", "8", "*"),
    (0x0A, "ç", "9", "^", "9", "("),
    (0x0B, "à", "0", "@", "0", ")"),
    (0x0C, ")", "°", "]", "-", "_"),
    (0x0D, "=", "+", "}", "=", "+"),
    (0x10, "a", "A", None, "q", "Q"),
    (0x11, "z", "Z", None, "w", "W"),
    (0x12, "e", "E", "€", "e", "E"),
    (0x13, "r", "R", None, "r", "R"),
    (0x14, "t", "T", None, "t", "T"),
    (0x15, "y", "Y", None, "y", "Y"),
    (0x16, "u", "U", None, "u", "U"),
    (0x17, "i", "I", None, "i", "I"),
    (0x18, "o", "O", None, "o", "O"),
    (0x19, "p", "P", None, "p", "P"),
    (0x1A, "^", "¨", None, "[", "{"),
    (0x1B, "$", "£", "¤", "]", "}"),
    (0x1E, "q", "Q", None, "a", "A"),
    (0x1F, "s", "S", None, "s", "S"),
    (0x20, "d", "D", None, "d", "D"),
    (0x21, "f", "F", None, "f", "F"),
    (0x22, "g", "G", None, "g", "G"),
    (0x23, "h", "H", None, "h", "H"),
    (0x24, "j", "J", None, "j", "J"),
    (0x25, "k", "K", None, "k", "K"),
    (0x26, "l", "L", None, "l", "L"),
    (0x27, "m", "M", None, ";", ":"),
    (0x28, "ù", "%", None, "'", '"'),
    (0x2B, "*", "µ", None, "\\", "|"),
    (0x56, "<", ">", None, "\\", "|"),
    (0x2C, "w", "W", None, "z", "Z"),
    (0x2D, "x", "X", None, "x", "X"),
    (0x2E, "c", "C", None, "c", "C"),
    (0x2F, "v", "V", None, "v", "V"),
    (0x30, "b", "B", None, "b", "B"),
    (0x31, "n", "N", None, "n", "N"),
    (0x32, ",", "?", None, "m", "M"),
    (0x33, ";", ".", None, ",", "<"),
    (0x34, ":", "/", None, ".", ">"),
    (0x35, "!", "§", None, "/", "?"),
]


# Legacy French dead-key combinations are intentionally finite. Expanding
# them through Unicode normalization would produce characters unavailable in
# the real keyboard driver and make VNC input diverge from physical input.
DEADKEYS = {
    "^": {
        "a": "â",
        "A": "Â",
        "e": "ê",
        "E": "Ê",
        "i": "î",
        "I": "Î",
        "o": "ô",
        "O": "Ô",
        "u": "û",
        "U": "Û",
        " ": "^",
    },
    "¨": {
        "a": "ä",
        "A": "Ä",
        "e": "ë",
        "E": "Ë",
        "i": "ï",
        "I": "Ï",
        "o": "ö",
        "O": "Ö",
        "u": "ü",
        "U": "Ü",
        "y": "ÿ",
        " ": "¨",
    },
}

ALTGR_DEADKEYS = {
    "~": {"a": "ã", "A": "Ã", "n": "ñ", "N": "Ñ", "o": "õ", "O": "Õ", " ": "~"},
    "`": {
        "a": "à",
        "A": "À",
        "e": "è",
        "E": "È",
        "i": "ì",
        "I": "Ì",
        "o": "ò",
        "O": "Ò",
        "u": "ù",
        "U": "Ù",
        " ": "`",
    },
}

FR_DEAD = set(DEADKEYS)

FR_TO_US: dict[str, str | None] = {}
for key in KEYS:
    for source, destination in ((key[1], key[4]), (key[2], key[5])):
        if source is not None:
            FR_TO_US.setdefault(source, destination)
for key in KEYS:
    if key[3] is not None:
        FR_TO_US.setdefault(key[3], None)

US_TO_FR: dict[str, str | None] = {}
for key in KEYS:
    for source, destination in ((key[4], key[1]), (key[5], key[2])):
        if source is not None:
            US_TO_FR.setdefault(source, destination)

FR_COMPOSED = {
    result: (dead, base)
    for dead, combinations in DEADKEYS.items()
    for base, result in combinations.items()
}
for dead, combinations in ALTGR_DEADKEYS.items():
    for base, result in combinations.items():
        if result not in FR_TO_US:
            FR_COMPOSED.setdefault(result, (dead, base))


def _decompose_fr(text: str) -> list[str]:
    """Convert composed French text into the corresponding physical strokes."""
    text = unicodedata.normalize("NFC", text)
    output: list[str] = []
    for index, character in enumerate(text):
        if character in FR_DEAD:
            following = text[index + 1] if index + 1 < len(text) else None
            if following is None or following in DEADKEYS[character]:
                output.extend([character, " "])
            else:
                output.append(character)
        elif character in FR_COMPOSED:
            output.extend(FR_COMPOSED[character])
        else:
            output.append(character)
    return output


def _compose_fr(characters: list[str]) -> str:
    """Apply the finite legacy French dead-key combinations."""
    output: list[str] = []
    pending: str | None = None
    for character in characters:
        if pending is not None:
            combinations = DEADKEYS[pending]
            if character in combinations:
                output.append(combinations[character])
                pending = None
            elif character in FR_DEAD:
                output.append(pending)
                pending = character
            else:
                output.extend([pending, character])
                pending = None
        elif character in FR_DEAD:
            pending = character
        else:
            output.append(character)
    if pending is not None:
        output.append(pending)
    return "".join(output)


def _apply(characters: list[str], mapping: dict[str, str | None], altgr: str) -> list[str]:
    output: list[str] = []
    for character in characters:
        if character not in mapping:
            output.append(character)
            continue
        destination = mapping[character]
        if destination is None:
            if altgr == "keep":
                output.append(character)
            elif altgr == "mark":
                output.append("\ufffd")
        else:
            output.append(destination)
    return output


def azerty_to_qwerty(text: str, altgr: str = "keep") -> str:
    """Return output produced by AZERTY strokes interpreted as US QWERTY."""
    return "".join(_apply(_decompose_fr(text), FR_TO_US, altgr))


def qwerty_to_azerty(text: str, altgr: str = "keep") -> str:
    """Return output produced by QWERTY strokes interpreted as French AZERTY."""
    return _compose_fr(_apply(list(text), US_TO_FR, altgr))


def display_table() -> None:
    print(f"{'scan':>5}  {'AZERTY':<20} {'QWERTY':<10}")
    print("-" * 42)
    for scan_code, fr_base, fr_shift, fr_altgr, us_base, us_shift in KEYS:
        azerty = f"{fr_base} {fr_shift or '-'}"
        if fr_altgr:
            azerty += f"  AltGr:{fr_altgr}"
        print(f" 0x{scan_code:02X}  {azerty:<20} {us_base} {us_shift or '-'}")


def selftest() -> int:
    tests = [
        ("example", azerty_to_qwerty("salut mon claude"), "sqlut ;on clqude"),
        ("reverse", qwerty_to_azerty("sqlut ;on clqude"), "salut mon claude"),
        ("uppercase", azerty_to_qwerty("AZERTY"), "QWERTY"),
        ("punctuation", azerty_to_qwerty("a;b:c!d,e"), "q,b.c/dme"),
        ("digits", azerty_to_qwerty("&é\"'(-è_çà"), "1234567890"),
        ("shift digits", azerty_to_qwerty("1234567890"), "!@#$%^&*()"),
        ("accents", azerty_to_qwerty("où ça"), "o' 9q"),
        ("dead key", azerty_to_qwerty("hôtel"), "h[otel"),
        ("dead reverse", qwerty_to_azerty("h[otel"), "hôtel"),
        ("diaeresis", azerty_to_qwerty("naïf"), "nq{if"),
        ("dead non-composable", qwerty_to_azerty("[s"), "^s"),
        ("isolated dead", azerty_to_qwerty("^"), "[ "),
        ("dead composable", azerty_to_qwerty("^a"), "[ q"),
        ("dead non-composable", azerty_to_qwerty("^s"), "[s"),
        ("two dead keys", azerty_to_qwerty("^^a"), "[[ q"),
        ("two dead reverse", qwerty_to_azerty("[[ q"), "^^a"),
        ("double diaeresis", qwerty_to_azerty("{{ "), "¨¨"),
        ("isolated reverse", qwerty_to_azerty("[ "), "^"),
        ("AltGr keep", azerty_to_qwerty("a@b"), "q@b"),
        ("AltGr drop", azerty_to_qwerty("a@b", altgr="drop"), "qb"),
        ("lowercase y diaeresis", azerty_to_qwerty("ÿ"), "{y"),
        ("unsupported uppercase", azerty_to_qwerty("Ÿ"), "Ÿ"),
        ("AltGr tilde", azerty_to_qwerty("mañana", altgr="drop"), ";qnqnq"),
        ("AltGr grave", azerty_to_qwerty("ì", altgr="drop"), "i"),
        ("direct grave", azerty_to_qwerty("à"), "0"),
        ("unmapped", azerty_to_qwerty("hé 🙂"), "h2 🙂"),
    ]
    passed = 0
    for name, actual, expected in tests:
        ok = actual == expected
        passed += int(ok)
        status = "OK" if ok else "FAIL"
        suffix = "" if ok else f" expected {expected!r}"
        print(f"[{status}] {name:<22} {actual!r}{suffix}")

    source = "abcdefghijklmnopqrstuvwxyz,;:!éèçàù"
    round_trip = qwerty_to_azerty(azerty_to_qwerty(source))
    ok = round_trip == source
    passed += int(ok)
    status = "OK" if ok else "FAIL"
    print(f"[{status}] {'round trip':<22} {round_trip!r}")

    total = len(tests) + 1
    print(f"\n{passed}/{total} tests passed")
    return 0 if passed == total else 1


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Translate text between physical AZERTY and QWERTY key positions."
    )
    parser.add_argument("text", nargs="*", help="Text to convert")
    parser.add_argument(
        "-r",
        "--reverse",
        action="store_true",
        help="Convert physical QWERTY strokes to AZERTY output",
    )
    parser.add_argument(
        "--altgr",
        choices=("keep", "drop", "mark"),
        default="keep",
        help="How to handle characters unavailable on the target layout",
    )
    parser.add_argument("--table", action="store_true", help="Display the mapping table")
    parser.add_argument("--selftest", action="store_true", help="Run built-in tests")
    arguments = parser.parse_args()

    if arguments.table:
        display_table()
        return
    if arguments.selftest:
        raise SystemExit(selftest())

    converter = qwerty_to_azerty if arguments.reverse else azerty_to_qwerty
    if arguments.text:
        print(converter(" ".join(arguments.text), arguments.altgr))
    elif not sys.stdin.isatty():
        for line in sys.stdin:
            print(converter(line.rstrip("\n"), arguments.altgr))
    else:
        direction = "QWERTY -> AZERTY" if arguments.reverse else "AZERTY -> QWERTY"
        print(f"Interactive mode ({direction}); press Ctrl+D to exit.")
        try:
            while True:
                print(converter(input("> "), arguments.altgr))
        except (EOFError, KeyboardInterrupt):
            print()


if __name__ == "__main__":
    main()
