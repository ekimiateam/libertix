#!/usr/bin/env bash
set -uo pipefail
umask 077
trap 'exit 130' INT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$(cd -- "$ROOT/../.." && pwd)/run-test-auto_logs_temps"
START_SCENARIO=""
AUTO_RESUME=0
CLEAN2_ONLY=0
while (( $# )); do
case "$1" in
    --step)
        if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
            echo "Usage: $0 [--step SCENARIO_NAME] [--clean2-only] [--auto-resume]" >&2
            exit 2
        fi
        START_SCENARIO="$2"
        shift 2
        ;;
    --auto-resume)
        AUTO_RESUME=1
        shift
        ;;
    --clean2-only)
        CLEAN2_ONLY=1
        shift
        ;;
    -h|--help)
        echo "Usage: $0 [--step SCENARIO_NAME] [--clean2-only] [--auto-resume]"
        echo "Example: $0 --step zorin-linux-first-ntfs"
        echo "Starts the selected scenario from its snapshot, then runs every remaining scenario."
        echo "--clean2-only runs four nominal scenarios plus two local-filepool cases on one UEFI VM; requires RESET_SNAPSHOT=clean2."
        echo "A failed scenario is retried once from its snapshot."
        echo "Both attempts are preserved; a second failure remains a failure."
        echo "A prolonged network outage does not consume the technical retry."
        echo "By default, includes Mint/Zorin, storage, BIOS refusal, uninstall and reboot checks."
        echo "The default campaign also tests BootOrder and EFI replacement on UEFI VMs."
        echo "Both campaign modes test the local filepool with Mint and Zorin on one UEFI VM, using its local_filepool_snapshot when configured."
        echo "--auto-resume is retained for compatibility and does not allow extra retries."
        exit 0
        ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
esac
done
mkdir -p -- "$LOG_DIR"
exec 9>"$LOG_DIR/.run.lock"
if ! flock -n 9; then
    echo "A campaign started by this script is already running." >&2
    exit 1
fi
LOG="$(mktemp "$LOG_DIR/$(date +%Y%m%dT%H%M%S%z)-XXXXXX.log")"

{
    trap ':' INT
    run_quality_check() {
        local label="$1"
        local check_log
        local check_status
        local -a check_codes
        shift
        check_log=$(mktemp "${LOG%.log}.check-XXXXXX.log") || return 1
        echo "CHECK $label | log: $check_log"
        if "$@" 2>&1 | tee "$check_log"; then
            echo "CHECK $label OK | details: $check_log"
            return 0
        else
            check_codes=("${PIPESTATUS[@]}")
            check_status=${check_codes[0]}
            if (( check_codes[1] != 0 )); then
                echo "ERROR: check log could not be saved: $check_log"
                if (( check_status == 0 )); then check_status=${check_codes[1]}; fi
            fi
        fi
        echo "CHECK $label FAILED (exit=$check_status) | full log: $check_log"
        return "$check_status"
    }

    echo "Started: $(date --iso-8601=seconds)"
    echo "Log: $LOG"
    echo "Running pre-campaign code checks."
    (
        set -e
        cd "$ROOT"
        run_quality_check "dependencies" uv sync --frozen --extra dev
        run_quality_check "Ruff lint" uv run --frozen python -m ruff check app tests tools ../assets/live/*.py ../iso-tools/*.py ../grub/*.py
        run_quality_check "Ruff format" uv run --frozen python -m ruff format --check app tests tools ../assets/live/*.py ../iso-tools/*.py ../grub/*.py
        run_quality_check "Python tests and coverage" uv run --frozen python -u -m pytest tests --cov=app --cov-report=term --cov-fail-under=70
    )
    quality_status=$?
    if (( quality_status != 0 )); then
        echo "STOP: code checks failed (exit=$quality_status). No campaign request was sent."
        exit "$quality_status"
    fi
    echo "Code checks passed."
    echo "Starting campaign. Each VM advances independently."
    "$ROOT/.venv/bin/python" -u - "$ROOT" "$START_SCENARIO" "$LOG" "$AUTO_RESUME" "$CLEAN2_ONLY" <<'PY'
import json
import secrets
import shutil
import string
import sys
import urllib.error
import urllib.request
from pathlib import Path

root = Path(sys.argv[1])
sys.path.insert(0, str(root))
from app.config import Settings
from app.stream_events import StreamEventProjector
from app.services.automation_campaign import SCENARIOS, STORAGE_SCENARIOS, BOOT_GUARDIAN_SCENARIOS, LOCAL_FILEPOOL_SCENARIOS

start_scenario = sys.argv[2]
clean2_only = sys.argv[5] == "1"
scenario_names = [f"{distribution}-{first_boot}-first" for distribution, first_boot in SCENARIOS]
boot_guardian_scenario_names = []
local_filepool_scenario_names = []
if not clean2_only:
    scenario_names.extend(
        f"{distribution}-{first_boot}-first-{layout}"
        for distribution, first_boot, layout in STORAGE_SCENARIOS
    )
    boot_guardian_scenario_names = [
        f"{distribution}-{first_boot}-first-{fault}"
        for distribution, first_boot, fault in BOOT_GUARDIAN_SCENARIOS
    ]
    scenario_names.extend(boot_guardian_scenario_names)
local_filepool_scenario_names = [f"{d}-{b}-first-local-filepool" for d, b in LOCAL_FILEPOOL_SCENARIOS]
scenario_names = scenario_names + local_filepool_scenario_names
if start_scenario and start_scenario not in scenario_names:
    print("Unknown scenario. Available choices: " + ", ".join(scenario_names), flush=True)
    sys.exit(2)
if start_scenario:
    print(f"Starting at {start_scenario}. Progress covers only this scenario and the remaining scenarios.", flush=True)

settings = Settings(_env_file=root / ".env")
if clean2_only and settings.reset_snapshot != "clean2":
    print(f"--clean2-only requires RESET_SNAPSHOT=clean2; configured: {settings.reset_snapshot}", flush=True)
    sys.exit(2)
labels = {vm.name: f"VM{vm.vmid}" for vm in settings.vms}
firmwares = {vm.name: vm.firmware for vm in settings.vms}
milestones = {}
scenarios = []
completed = set()
current = {}
active = {}
verdict = None
failed = False
summaries = {}
first_scenario_index = 1
total_scenarios = 0

def progress():
    if not scenarios:
        return
    def vm_milestones(item, vm):
        return item.get("vm_milestones", {}).get(vm, milestones)
    total = sum(len(vm_milestones(item, vm)) for item in scenarios for vm in item["vms"])
    def bar(count, maximum):
        percent = 100 * count / maximum if maximum else 0
        filled = int(18 * percent / 100)
        return "[" + "#" * filled + "-" * (18 - filled) + f"] {percent:5.1f}%"
    lines = [f"Campaign {bar(len(completed), total)} | {len(completed)}/{total} milestones completed"]
    for vm in payload["vms"]:
        maximum = sum(len(vm_milestones(item, vm)) for item in scenarios if vm in item["vms"])
        count = sum(key[1] == vm for key in completed)
        stage = current.get(vm, "waiting")
        selected = active.get(vm)
        if selected:
            snapshot = settings.secondary_disk_reset_snapshot if selected["snapshot_mode"] == "secondary-disk" else settings.reset_snapshot
            if selected.get("layout") == "local-filepool":
                snapshot = next(item for item in settings.vms if item.name == vm).local_filepool_snapshot or snapshot
            expectation = {
                "compatibility-refusal": "BIOS compatibility refusal",
                "install-uninstall": "installation and uninstall",
                "boot-order": "BootOrder repair",
                "preferred-path": "EFI replacement consent and repair",
                "preferred-path-rollback": "EFI replacement refusal and rollback",
            }.get(selected.get("expectations", {}).get(vm), "installation and uninstall")
            lines.append(f"{labels.get(vm, vm)} · {scenarios.index(selected) + first_scenario_index}/{total_scenarios} · {selected['name']} · {snapshot} · {expectation}")
        lines.append(f"{labels.get(vm, vm)} {bar(count, maximum)} | {stage}")
    if verdict:
        lines.append("Verdict: " + verdict + " — milestone completion, not elapsed time")
    print("PROGRESS " + json.dumps(lines, ensure_ascii=False), flush=True)

base = "http://127.0.0.1:8000"

def validate_success(data):
    if data.get("status") != "ok":
        return
    expected = scenario_names[scenario_names.index(payload["start_scenario"]):] if payload.get("start_scenario") else scenario_names
    items = data.get("campaign_summary")
    if (not isinstance(items, list) or not all(isinstance(item, dict) for item in items)
            or [item.get("scenario") for item in items] != scenario_names):
        raise RuntimeError("Invalid campaign verdict: missing, duplicate, or unexpected scenarios.")
    for item in items:
        required = "ok" if item["scenario"] in expected else "not-run"
        required_vms = [vm for vm in payload["vms"]
                        if item["scenario"] not in boot_guardian_scenario_names or firmwares.get(vm) == "uefi"]
        if item["scenario"] in local_filepool_scenario_names:
            required_vms = [vm for vm in payload["vms"] if firmwares.get(vm) == "uefi"][:1]
        cells = item.get("cells", {})
        if (not required_vms or item.get("status") != required
                or item.get("vms") != dict.fromkeys(required_vms, required)
                or not isinstance(cells, dict) or set(cells) != set(required_vms)
                or any(not isinstance(cell, dict) or cell.get("status") != required for cell in cells.values())):
            raise RuntimeError("Invalid campaign verdict: inconsistent VM results for " + item["scenario"])

try:
    with urllib.request.urlopen(base + "/health", timeout=10) as response:
        if response.status != 200:
            raise RuntimeError("The automated-test server is not ready.")
    payload = {
        "vms": ["vm1", "vm2", "vm3"], "source": "local", "apply": True,
        "linux_username": "test",
        "linux_password": "".join(secrets.choice(string.ascii_lowercase) for _ in range(24)),
        "linux_size_gib": 20, "migrate_windows_preferences": False,
        "continue_after_failure": True,
        "include_storage_scenarios": not clean2_only,
        "include_boot_guardian_scenarios": not clean2_only,
        "include_local_filepool_scenarios": True,
        "retry_failed_scenarios": True,
    }
    if start_scenario:
        payload["start_scenario"] = start_scenario
    while True:
        terminal = None
        request = urllib.request.Request(
            base + "/api/v1/automation/full/stream?format=ndjson",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST",
        )
        with urllib.request.urlopen(request, timeout=None) as response:
            for raw in response:
                event = json.loads(raw)
                if event.get("event") == "result":
                    validate_success(event["data"])
                print(StreamEventProjector.render(event, stream_format="compact"), end="", flush=True)
                data = event["data"]
                if event["event"] == "result":
                    terminal = data
                    network_restart = any(item["step"] == "automation.network.restart_required"
                                          for item in data.get("steps", []))
                    for error in data.get("steps", []):
                        if error["step"] == "automation.inactivity_timeout":
                            print("ERROR " + json.dumps(error, ensure_ascii=False), flush=True)
                    for item in data.get("campaign_summary", []):
                        if item["status"] != "not-run":
                            item["service_log"] = data.get("detailed_log", "")
                            previous = summaries.get(item["scenario"])
                            if previous is not None:
                                item["previous_attempts"] = [
                                    *previous.get("previous_attempts", []),
                                    {key: value for key, value in previous.items() if key != "previous_attempts"},
                                    *item.get("previous_attempts", []),
                                ]
                            summaries[item["scenario"]] = item
                else:
                    step = data["step"]
                    context = data.get("context", {})
                    if step == "automation.campaign_retry":
                        completed = {key for key in completed if not (key[0] == context["scenario"] and (not context.get("vm") or key[1] == context["vm"]))}
                    if step == "automation.campaign_plan" and not scenarios:
                        milestones = context["milestones"]
                        scenarios = context["scenarios"]
                        first_scenario_index = context.get("first_scenario_index", 1)
                        total_scenarios = context.get("total_scenarios", len(scenarios))
                    elif step == "automation.campaign_scenario":
                        selected = next(item for item in scenarios if item["name"] == context["scenario"])
                        for vm in ([context["vm"]] if context.get("vm") else selected["vms"]):
                            active[vm] = selected
                            current[vm] = "preparing"
                    vm = context.get("vm")
                    if vm in payload["vms"]:
                        vm_failed = data["status"] == "error" or context.get("vm_status") == "error"
                        current[vm] = ("ERROR: " if vm_failed else "") + str(context.get("phase") or context.get("test") or step.removeprefix("automation."))
                        checkpoint = "automation.test." + context["test"] if step.startswith("automation.test.") and "test" in context else step
                        eligible = active.get(vm, {}).get("vm_milestones", {}).get(vm, milestones)
                        if checkpoint in eligible and data["status"] == "ok" and (step != "automation.vm_finished" or context.get("vm_status") == "ok"):
                            completed.add((context["scenario"], vm, checkpoint))
                progress()
        # Only a terminal verdict permits another POST. A network restart below
        # restores the scenario snapshot instead of reusing its changed disks.
        if terminal is None:
            raise RuntimeError("The stream closed without a final verdict; no automatic retry was attempted.")
        archive = None
        had_retries = any(item.get("previous_attempts") for item in terminal.get("campaign_summary", []))
        if (terminal["status"] != "ok" or had_retries) and terminal.get("detailed_log"):
            workspace = Path(terminal["detailed_log"]).parent
            archive = Path(sys.argv[3]).with_suffix(".diagnostics") / workspace.name
            archive.mkdir(parents=True, exist_ok=True)
            # Preserve failed-run evidence before later requests trigger retention.
            for source in workspace.rglob("manifest.json"):
                if "diagnostics" in source.relative_to(workspace).parts:
                    shutil.copytree(source.parent, archive / source.parent.relative_to(workspace))
            for source in workspace.rglob("*.txt"):
                if "diagnostics" not in source.relative_to(workspace).parts:
                    destination = archive / source.relative_to(workspace)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
            for source in [workspace / "campaign-summary.json", workspace / "worker-fatal.log", workspace / "runtime-provenance.json",
                           workspace / "release-provenance.json",
                           *workspace.rglob("runtime-provenance.json"),
                           *workspace.rglob("worker-fatal.log"),
                           *workspace.glob("logs/api-runtime.txt.*"),
                           *workspace.glob("captures/timeout-*.png")]:
                if source.is_file():
                    destination = archive / source.relative_to(workspace)
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy2(source, destination)
            print(f"Diagnostics preserved: {archive}", flush=True)
            for item in terminal.get("campaign_summary", []):
                if item["status"] != "not-run":
                    item["diagnostics_archive"] = str(archive)
        timed_out = any(item["step"] == "automation.inactivity_timeout" for item in terminal.get("steps", []))
        interrupted = [item for item in terminal.get("campaign_summary", []) if item["status"] == "interrupted"]
        if (network_restart or timed_out) and not any(item.get("cells") for item in terminal.get("campaign_summary", [])):
            if len(interrupted) != 1:
                raise RuntimeError("The interrupted scenario could not be identified; no automatic retry was attempted.")
            scenario = interrupted[0]["scenario"]
            attempt = int(interrupted[0].get("attempt", payload.get("start_scenario_attempt", 1)))
            prolonged_outage = any(
                item["step"] == "automation.network.restart_required"
                and item.get("context", {}).get("restart_reason") == "prolonged_outage"
                for item in terminal.get("steps", [])
            )
            if attempt >= 2 and not prolonged_outage:
                failed = True
                interrupted[0]["status"] = "error"
                next_index = scenario_names.index(scenario) + 1
                print(f"FAILED: {scenario} failed on its second attempt; no third attempt is allowed. Diagnostics preserved: {archive}", flush=True)
                if next_index == len(scenario_names):
                    break
                payload["start_scenario"] = scenario_names[next_index]
                payload["start_scenario_attempt"] = 1
                print(f"CONTINUE: the previous controller stopped; starting {payload['start_scenario']} from its snapshot.", flush=True)
                continue
            completed = {key for key in completed if key[0] != scenario}
            payload["start_scenario"] = scenario
            payload["start_scenario_attempt"] = attempt if prolonged_outage else 2
            reasons = [item.get("context", {}).get("failed_step", item["step"]) + ": " + item["message"]
                       for item in terminal.get("steps", [])
                       if item["step"] in {"automation.network.restart_required", "automation.inactivity_timeout"}]
            retry_note = "Prolonged network outage: the interrupted attempt was not consumed." if prolonged_outage else "New technical attempt."
            print(f"RETRY {scenario} — attempt {payload['start_scenario_attempt']}/2 from its snapshot. {retry_note} Reason: {'; '.join(reasons)}. Previous diagnostics preserved: {archive}", flush=True)
            continue
        failed |= terminal["status"] != "ok"
        break
    failed |= any(item["status"] != "ok" for item in summaries.values())
    verdict = "ERROR" if failed else "OK"
    for item in summaries.values():
        print("SUMMARY " + json.dumps(item, ensure_ascii=False), flush=True)
    summary_path = Path(sys.argv[3]).with_suffix(".summary.json")
    summary_path.write_text(json.dumps({"status": verdict, "scenarios": list(summaries.values())}, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"Campaign summary and attempt lineage: {summary_path}", flush=True)
    progress()
    print("CAMPAIGN " + verdict, flush=True)
    if failed:
        print("FAILED: at least one scenario remains failed or interrupted; inspect the summary and diagnostics.", flush=True)
        sys.exit(1)
except KeyboardInterrupt:
    verdict = "INTERRUPTED"
    progress()
    print("Monitoring interrupted by Ctrl+C. The server campaign may still be running; check its state before restarting.", flush=True)
    sys.exit(130)
except (OSError, ValueError, RuntimeError) as error:
    print(f"RUNNER FAILURE: {type(error).__name__}: {error}", flush=True)
    print("The POST request was not retried automatically; check the server operation before trying again.")
    sys.exit(1)
PY
    status=$?
    echo "Finished: $(date --iso-8601=seconds); campaign exit=$status"
    if (( status == 130 )); then
        exit "$status"
    fi
    exit "$status"
} 2>&1 | python3 -u -c '
import codecs, json, os, re, select, shutil, signal, sys, termios, textwrap
from collections import deque

# The producer handles Ctrl+C; drain its final message before restoring the terminal.
signal.signal(signal.SIGINT, signal.SIG_IGN)

status = []
terminal = sys.stdout.isatty()
size = None
bottom = 0
footer = 0
pending = ""
decoder = codecs.getincrementaldecoder("utf-8")("replace")
recent_logs = deque(maxlen=500)
tty_fd = None
tty_settings = None

def display_line(line):
    prefix, separator, payload = line.partition(" ")
    if not separator or prefix not in {"NETWORK", "DIAGNOSTICS", "SCENARIO", "SUMMARY", "ERROR", "RETRY"}:
        return line
    try:
        data = json.loads(payload)
    except ValueError:
        return line + " [original diagnostic]" if prefix in {"ERROR", "RETRY"} else line
    if not isinstance(data, dict):
        return line
    if prefix in {"SCENARIO", "SUMMARY"}:
        states = {"ok": "OK", "error": "ERROR", "interrupted": "INTERRUPTED", "not-run": "NOT RUN", "not-verified": "NOT VERIFIED"}
        state = states.get(data.get("status"), data.get("status", "?"))
        scenario = data.get("scenario", "?")
        vms = ", ".join(f"{vm}: {states.get(value, value)}" for vm, value in data.get("vms", {}).items())
        attempt = " | attempt {}/2".format(data["attempt"]) if data.get("attempt", 1) > 1 else ""
        return f"{prefix} {scenario} — {state}" + attempt + (f" | {vms}" if vms else "")
    context = data.get("context", {})
    step = data.get("step", "?")
    location = "/".join(str(context[key]) for key in ("scenario", "vm") if context.get(key))
    message = data.get("message", "")
    if prefix == "ERROR":
        message = "Original diagnostic: " + message
    if step == "automation.campaign_retry":
        errors = context.get("errors", [])
        reasons = ["{}: {}".format(error["step"], error["message"]) for error in errors
                   if not error["step"].startswith("automation.diagnostics.")]
        diagnostic_errors = ["{}: {}".format(error["step"], error["message"]) for error in errors
                             if error["step"].startswith("automation.diagnostics.")]
        reason = " ; ".join(reasons) or context.get("reason", message)
        previous_log = context.get("previous_log", "?")
        diagnostic_note = (" Consecutive incomplete diagnostics: " + "; ".join(diagnostic_errors) + ".") if diagnostic_errors else ""
        attempt = context.get("next_attempt", 2)
        return f"RETRY {location} — attempt {attempt}/2 from its snapshot. Original diagnostic: {reason}.{diagnostic_note} Previous log: {previous_log}"
    if step == "automation.network.wait":
        message = "Waiting for the network; VM control is paused."
    elif step == "automation.network.resumed":
        message = "Network available; resuming VM control."
    elif step in {"automation.network.restart_required", "automation.network.vm_restart_required"}:
        message = "Scenario interrupted after a prolonged network outage." if context.get("restart_reason") == "prolonged_outage" or context.get("replay_safe") is not False else "Scenario interrupted: remote command outcome is unknown."
    details = []
    if "reachable" in context:
        details.append("; ".join(str(host) + (": reachable" if ok else ": no response") for host, ok in context["reachable"].items()))
    for key in ("host", "test", "exit_code", "exception_type", "error", "last_step", "path", "collection_status", "system_context_status"):
        if key in context and context[key] is not None and str(context[key]) != "":
            details.append(f"{key}={context[key]}")
    lines = [f"{prefix} {location or step} — {message}" + (" | " + " | ".join(details) if details else "")]
    if prefix == "ERROR":
        lines.append(f"  step: {step}")
        for key in ("stderr", "stdout", "traceback"):
            value = str(context.get(key) or "").strip()
            if value:
                excerpt = re.sub(r"[\x00-\x08\x0b-\x1f\x7f]", "", value[:6000].replace("\r\n", "\n"))
                lines.extend(f"  {key} | {part}" for part in excerpt.splitlines())
                if len(value) > 6000:
                    lines.append(f"  {key} | [truncated; full output in {sys.argv[1]}]")
    return "\n".join(lines)

def panel_rows(width, budget):
    if not status:
        return []
    rows = ["\033[36m" + "─" * width + "\033[0m",
            "\033[1;36m" + " CAMPAIGN PROGRESS · completed milestones"[:width] + "\033[0m"]
    for text in status:
        match = re.fullmatch(r"(.*?) \[[#-]+\]\s+([0-9.]+)% \| (.*)", text)
        if not match:
            rows.extend(textwrap.wrap(text, width) or [""])
            continue
        name, percentage, detail = match.groups()
        percent = min(100, max(0, float(percentage)))
        value = f"{percent:5.1f}%"
        available = max(0, width - len(value) - 1)
        label = f"{name} · {detail}"
        if len(label) > available:
            label = label[:max(0, available - 1)] + "…"
        rows.append("\033[1m" + label.ljust(available) + " \033[36m" + value + "\033[0m")
        filled = int(width * percent / 100)
        rows.append("\033[97m" + "█" * filled + "\033[90m" + "░" * (width - filled) + "\033[0m")
    if len(rows) <= budget:
        return rows
    compact = []
    for text in status:
        match = re.fullmatch(r"(.*?) \[[#-]+\]\s+([0-9.]+)% \| (.*)", text)
        if match:
            name, percentage, detail = match.groups()
            compact.append(f"{name} {percentage}% | {detail}"[:width])
        elif text.startswith("Verdict:"):
            compact.append(text[:width])
    return compact if width >= 24 and len(compact) <= budget else []

def configure():
    global size, bottom, footer
    try:
        new_size = os.get_terminal_size(sys.stdout.fileno())
    except OSError:
        new_size = shutil.get_terminal_size()
    width = max(1, new_size.columns - 1)
    new_footer = len(panel_rows(width, max(0, new_size.lines - 3)))
    if new_size == size and new_footer == footer:
        return
    had_layout = size is not None
    size = new_size
    bottom = max(1, size.lines - new_footer)
    had_footer = footer > 0
    footer = new_footer
    # Resize reflows old footer lines and can reset the terminal scroll region.
    sys.stdout.write("\033[r")
    if had_layout and (footer or had_footer):
        rows = []
        for line in recent_logs:
            rows.extend(textwrap.wrap(line, width, replace_whitespace=False,
                                      drop_whitespace=False) or [""])
        rows = rows[-max(0, bottom - 1):] if bottom > 1 else []
        sys.stdout.write("\033[2J\033[H")
        for row, line in enumerate(rows, start=bottom - len(rows)):
            sys.stdout.write(f"\033[{row};1H\033[2K{line}")
        sys.stdout.write(f"\033[1;{bottom}r\033[{bottom};1H")

def draw():
    if not footer:
        return
    width = max(1, size.columns - 1)
    rows = panel_rows(width, max(0, size.lines - 3))
    for index, row in enumerate(range(bottom + 1, size.lines + 1)):
        text = rows[index] if index < len(rows) else ""
        sys.stdout.write(f"\033[{row};1H\033[2K{text}")
    # Never restore a cursor that may be outside the resized log region.
    sys.stdout.write(f"\033[{bottom};1H")

def write_log_line(line):
    text = display_line(line)
    recent_logs.extend(text.splitlines() or [""])
    if terminal and footer:
        sys.stdout.write(f"\033[1;{bottom}r\033[{bottom};1H\033[2K")
    sys.stdout.write(text.replace("\n", "\r\n") + "\r\n" if terminal else text + "\n")

try:
    if terminal:
        try:
            tty_fd = os.open("/dev/tty", os.O_RDWR | os.O_NOCTTY)
            tty_settings = termios.tcgetattr(tty_fd)
            quiet = tty_settings.copy()
            # This display accepts no input; echoed Enter must not scroll the footer.
            quiet[3] &= ~(termios.ECHO | termios.ECHONL)
            termios.tcsetattr(tty_fd, termios.TCSANOW, quiet)
        except (OSError, termios.error):
            tty_settings = None
    with open(sys.argv[1], "a", encoding="utf-8") as log:
        while True:
            if terminal:
                configure()
                draw()
                sys.stdout.flush()
            ready, _, _ = select.select([sys.stdin.buffer], [], [], 0.25 if terminal else None)
            if not ready:
                continue
            chunk = sys.stdin.buffer.read1(65536)
            if not chunk:
                pending += decoder.decode(b"", final=True)
                if pending:
                    log.write(pending)
                    write_log_line(pending)
                break
            pending += decoder.decode(chunk)
            while "\n" in pending:
                line, pending = pending.split("\n", 1)
                if line.startswith("PROGRESS "):
                    status = json.loads(line[len("PROGRESS "):])
                    if terminal:
                        configure()
                        if not footer:
                            print("\n".join(status))
                else:
                    log.write(line + "\n")
                    write_log_line(line)
            log.flush()
            sys.stdout.flush()
        if status:
            log.write("\n".join(status) + "\n")
finally:
    if terminal and size is not None:
        for row in range(bottom + 1, size.lines + 1):
            sys.stdout.write(f"\033[{row};1H\033[2K")
        sys.stdout.write(f"\033[r\033[{bottom};1H")
    if tty_fd is not None:
        if tty_settings is not None:
            termios.tcsetattr(tty_fd, termios.TCSANOW, tty_settings)
        os.close(tty_fd)
    if status:
        print("\n".join(status))
    sys.stdout.flush()
' "$LOG"
codes=("${PIPESTATUS[@]}")
if (( codes[0] != 0 )); then exit "${codes[0]}"; fi
exit "${codes[1]}"
