"""Render the campaign launcher output with a fixed progress footer.

Reads the producer output on stdin, appends every log line to the file given as the
first argument and keeps PROGRESS lines in a footer below a scrolling log region.
"""

from __future__ import annotations

import codecs
import json
import os
import re
import select
import shutil
import signal
import sys
import termios
import textwrap
from collections import deque

PROGRESS_PATTERN = re.compile(r"(.*?) \[[#-]+\]\s+([0-9.]+)% \| (.*)")
STRUCTURED_PREFIXES = {"NETWORK", "DIAGNOSTICS", "SCENARIO", "SUMMARY", "ERROR", "RETRY"}
STATUS_LABELS = {
    "ok": "OK",
    "error": "ERROR",
    "interrupted": "INTERRUPTED",
    "not-run": "NOT RUN",
    "not-verified": "NOT VERIFIED",
}
DETAIL_KEYS = (
    "host",
    "test",
    "exit_code",
    "exception_type",
    "error",
    "last_step",
    "path",
    "collection_status",
    "system_context_status",
)
MAX_EXCERPT = 6000


def _scenario_line(prefix: str, data: dict[str, object]) -> str:
    state = STATUS_LABELS.get(data.get("status"), data.get("status", "?"))
    vms = ", ".join(
        f"{vm}: {STATUS_LABELS.get(value, value)}" for vm, value in data.get("vms", {}).items()
    )
    attempt = " | attempt {}/2".format(data["attempt"]) if data.get("attempt", 1) > 1 else ""
    return (
        f"{prefix} {data.get('scenario', '?')} — {state}" + attempt + (f" | {vms}" if vms else "")
    )


def _retry_line(location: str, context: dict[str, object], message: str) -> str:
    errors = context.get("errors", [])
    reasons = [
        "{}: {}".format(error["step"], error["message"])
        for error in errors
        if not error["step"].startswith("automation.diagnostics.")
    ]
    diagnostic_errors = [
        "{}: {}".format(error["step"], error["message"])
        for error in errors
        if error["step"].startswith("automation.diagnostics.")
    ]
    reason = " ; ".join(reasons) or context.get("reason", message)
    diagnostic_note = (
        " Consecutive incomplete diagnostics: " + "; ".join(diagnostic_errors) + "."
        if diagnostic_errors
        else ""
    )
    return (
        f"RETRY {location} — attempt {context.get('next_attempt', 2)}/2 from its snapshot. "
        f"Original diagnostic: {reason}.{diagnostic_note} "
        f"Previous log: {context.get('previous_log', '?')}"
    )


def _network_message(step: str, context: dict[str, object], message: str) -> str:
    if step == "automation.network.wait":
        return "Waiting for the network; VM control is paused."
    if step == "automation.network.resumed":
        return "Network available; resuming VM control."
    if step in {"automation.network.restart_required", "automation.network.vm_restart_required"}:
        if (
            context.get("restart_reason") == "prolonged_outage"
            or context.get("replay_safe") is not False
        ):
            return "Scenario interrupted after a prolonged network outage."
        return "Scenario interrupted: remote command outcome is unknown."
    return message


def _error_output_lines(context: dict[str, object], log_path: str) -> list[str]:
    lines = []
    for key in ("stderr", "stdout", "traceback"):
        value = str(context.get(key) or "").strip()
        if not value:
            continue
        excerpt = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", value[:MAX_EXCERPT].replace("\r\n", "\n"))
        lines.extend(f"  {key} | {part}" for part in excerpt.splitlines())
        if len(value) > MAX_EXCERPT:
            lines.append(f"  {key} | [truncated; full output in {log_path}]")
    return lines


def display_line(line: str, log_path: str) -> str:
    """Turn one structured producer line into readable text; keep other lines unchanged."""

    prefix, separator, payload = line.partition(" ")
    if not separator or prefix not in STRUCTURED_PREFIXES:
        return line
    try:
        data = json.loads(payload)
    except ValueError:
        return line + " [original diagnostic]" if prefix in {"ERROR", "RETRY"} else line
    if not isinstance(data, dict):
        return line
    if prefix in {"SCENARIO", "SUMMARY"}:
        return _scenario_line(prefix, data)

    context = data.get("context", {})
    step = data.get("step", "?")
    location = "/".join(str(context[key]) for key in ("scenario", "vm") if context.get(key))
    message = data.get("message", "")
    if prefix == "ERROR":
        message = "Original diagnostic: " + message
    if step == "automation.campaign_retry":
        return _retry_line(location, context, message)
    message = _network_message(step, context, message)

    details = []
    if "reachable" in context:
        details.append(
            "; ".join(
                str(host) + (": reachable" if ok else ": no response")
                for host, ok in context["reachable"].items()
            )
        )
    for key in DETAIL_KEYS:
        if key in context and context[key] is not None and str(context[key]) != "":
            details.append(f"{key}={context[key]}")
    lines = [
        f"{prefix} {location or step} — {message}"
        + (" | " + " | ".join(details) if details else "")
    ]
    if prefix == "ERROR":
        lines.append(f"  step: {step}")
        lines.extend(_error_output_lines(context, log_path))
    return "\n".join(lines)


class TerminalDisplay:
    """Keep a scrolling log region above a progress footer that survives terminal resizes."""

    def __init__(self, log_path: str, interactive: bool) -> None:
        self.log_path = log_path
        self.interactive = interactive
        self.status: list[str] = []
        self.size: os.terminal_size | None = None
        self.bottom = 0
        self.footer = 0
        self.recent_logs: deque[str] = deque(maxlen=500)

    def panel_rows(self, width: int, budget: int) -> list[str]:
        if not self.status:
            return []
        rows = [
            "\033[36m" + "─" * width + "\033[0m",
            "\033[1;36m" + " CAMPAIGN PROGRESS · completed milestones"[:width] + "\033[0m",
        ]
        for text in self.status:
            match = PROGRESS_PATTERN.fullmatch(text)
            if not match:
                rows.extend(textwrap.wrap(text, width) or [""])
                continue
            name, percentage, detail = match.groups()
            percent = min(100, max(0, float(percentage)))
            value = f"{percent:5.1f}%"
            available = max(0, width - len(value) - 1)
            label = f"{name} · {detail}"
            if len(label) > available:
                label = label[: max(0, available - 1)] + "…"
            rows.append("\033[1m" + label.ljust(available) + " \033[36m" + value + "\033[0m")
            filled = int(width * percent / 100)
            rows.append("\033[97m" + "█" * filled + "\033[90m" + "░" * (width - filled) + "\033[0m")
        if len(rows) <= budget:
            return rows
        compact = []
        for text in self.status:
            match = PROGRESS_PATTERN.fullmatch(text)
            if match:
                name, percentage, detail = match.groups()
                compact.append(f"{name} {percentage}% | {detail}"[:width])
            elif text.startswith("Verdict:"):
                compact.append(text[:width])
        return compact if width >= 24 and len(compact) <= budget else []

    def configure(self) -> None:
        try:
            new_size = os.get_terminal_size(sys.stdout.fileno())
        except OSError:
            new_size = shutil.get_terminal_size()
        width = max(1, new_size.columns - 1)
        new_footer = len(self.panel_rows(width, max(0, new_size.lines - 3)))
        if new_size == self.size and new_footer == self.footer:
            return
        had_layout = self.size is not None
        had_footer = self.footer > 0
        self.size = new_size
        self.bottom = max(1, new_size.lines - new_footer)
        self.footer = new_footer
        # Resize reflows old footer lines and can reset the terminal scroll region.
        sys.stdout.write("\033[r")
        if had_layout and (self.footer or had_footer):
            self._redraw_logs(width)

    def _redraw_logs(self, width: int) -> None:
        rows = []
        for line in self.recent_logs:
            rows.extend(
                textwrap.wrap(line, width, replace_whitespace=False, drop_whitespace=False) or [""]
            )
        rows = rows[-max(0, self.bottom - 1) :] if self.bottom > 1 else []
        sys.stdout.write("\033[2J\033[H")
        for row, line in enumerate(rows, start=self.bottom - len(rows)):
            sys.stdout.write(f"\033[{row};1H\033[2K{line}")
        sys.stdout.write(f"\033[1;{self.bottom}r\033[{self.bottom};1H")

    def draw(self) -> None:
        if not self.footer:
            return
        width = max(1, self.size.columns - 1)
        rows = self.panel_rows(width, max(0, self.size.lines - 3))
        for index, row in enumerate(range(self.bottom + 1, self.size.lines + 1)):
            text = rows[index] if index < len(rows) else ""
            sys.stdout.write(f"\033[{row};1H\033[2K{text}")
        # Never restore a cursor that may be outside the resized log region.
        sys.stdout.write(f"\033[{self.bottom};1H")

    def write_log_line(self, line: str) -> None:
        text = display_line(line, self.log_path)
        self.recent_logs.extend(text.splitlines() or [""])
        if self.interactive and self.footer:
            sys.stdout.write(f"\033[1;{self.bottom}r\033[{self.bottom};1H\033[2K")
        if self.interactive:
            sys.stdout.write(text.replace("\n", "\r\n") + "\r\n")
        else:
            sys.stdout.write(text + "\n")

    def set_status(self, status: list[str]) -> None:
        self.status = status
        if self.interactive:
            self.configure()
            if not self.footer:
                print("\n".join(status))

    def clear_footer(self) -> None:
        if not self.interactive or self.size is None:
            return
        for row in range(self.bottom + 1, self.size.lines + 1):
            sys.stdout.write(f"\033[{row};1H\033[2K")
        sys.stdout.write(f"\033[r\033[{self.bottom};1H")


def _silence_terminal_echo() -> tuple[int | None, list | None]:
    try:
        tty_fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
    except OSError:
        return None, None
    try:
        settings = termios.tcgetattr(tty_fd)
        quiet = settings.copy()
        # This display accepts no input; echoed Enter must not scroll the footer.
        quiet[3] &= ~(termios.ECHO | termios.ECHONL)
        termios.tcsetattr(tty_fd, termios.TCSANOW, quiet)
        return tty_fd, settings
    except termios.error:
        return tty_fd, None


def _pump(display: TerminalDisplay, log) -> None:
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    pending = ""
    while True:
        if display.interactive:
            display.configure()
            display.draw()
            sys.stdout.flush()
        ready, _, _ = select.select(
            [sys.stdin.buffer], [], [], 0.25 if display.interactive else None
        )
        if not ready:
            continue
        chunk = sys.stdin.buffer.read1(65536)
        if not chunk:
            pending += decoder.decode(b"", final=True)
            if pending:
                log.write(pending)
                display.write_log_line(pending)
            return
        pending += decoder.decode(chunk)
        while "\n" in pending:
            line, pending = pending.split("\n", 1)
            if line.startswith("PROGRESS "):
                display.set_status(json.loads(line[len("PROGRESS ") :]))
            else:
                log.write(line + "\n")
                display.write_log_line(line)
        log.flush()
        sys.stdout.flush()


def main(log_path: str) -> None:
    # The producer handles Ctrl+C; drain its final message before restoring the terminal.
    signal.signal(signal.SIGINT, signal.SIG_IGN)
    display = TerminalDisplay(log_path, sys.stdout.isatty())
    tty_fd, tty_settings = _silence_terminal_echo() if display.interactive else (None, None)
    try:
        with open(log_path, "a", encoding="utf-8") as log:
            _pump(display, log)
            if display.status:
                log.write("\n".join(display.status) + "\n")
    finally:
        display.clear_footer()
        if tty_fd is not None:
            if tty_settings is not None:
                termios.tcsetattr(tty_fd, termios.TCSANOW, tty_settings)
            os.close(tty_fd)
        if display.status:
            print("\n".join(display.status))
        sys.stdout.flush()


if __name__ == "__main__":
    main(sys.argv[1])
