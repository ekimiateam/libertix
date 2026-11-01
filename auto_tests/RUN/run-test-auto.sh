#!/usr/bin/env bash
set -uo pipefail
umask 077
trap 'exit 130' INT

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="$(cd -- "$ROOT/../.." && pwd)/run-test-auto_logs_temps"
USAGE="Usage: $0 [--step SCENARIO_NAME] [--clean2-only | --clean3-only]"
START_SCENARIO=""
MODE="full"

print_help() {
    echo "$USAGE"
    echo "Example: $0 --step zorin-linux-first-ntfs"
    echo "Starts the selected scenario from its snapshot, then runs every remaining scenario."
    echo "--clean2-only runs four nominal scenarios plus two local-filepool cases on one UEFI VM."
    echo "--clean3-only runs the ten storage scenarios only."
    echo "Each restricted mode requires the snapshot configured for it in RUN/campaign.toml."
    echo "A failed scenario is retried once from its snapshot."
    echo "Both attempts are preserved; a second failure remains a failure."
    echo "A prolonged network outage does not consume the technical retry."
    echo "By default, includes Mint/Zorin, storage, BIOS refusal, uninstall and reboot checks."
    echo "The default campaign also tests BootOrder and EFI replacement on UEFI VMs."
    echo "Full and clean2-only campaigns test the local filepool with Mint and Zorin on one UEFI VM."
}

while (( $# )); do
    case "$1" in
        --step)
            if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
                echo "$USAGE" >&2
                exit 2
            fi
            START_SCENARIO="$2"
            shift 2
            ;;
        --clean2-only | --clean3-only)
            if [[ "$MODE" != full && "$MODE" != "${1#--}" ]]; then
                echo "--clean2-only and --clean3-only cannot be combined." >&2
                exit 2
            fi
            MODE="${1#--}"
            shift
            ;;
        -h | --help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

mkdir -p -- "$LOG_DIR"
exec 9>"$LOG_DIR/.run.lock"
if ! flock -n 9; then
    echo "A campaign started by this script is already running." >&2
    exit 1
fi
LOG="$(mktemp "$LOG_DIR/$(date +%Y%m%dT%H%M%S%z)-XXXXXX.log")"

run_quality_check() {
    local label="$1"
    local check_log
    local writer_log
    local check_status
    local -a check_codes
    shift
    check_log=$(mktemp "${LOG%.log}.check-XXXXXX.log") || return 1
    writer_log="${check_log%.log}.writer.log"
    echo "CHECK $label | log: $check_log"
    if "$@" 2>&1 | tee --output-error=warn "$check_log" 2>"$writer_log"; then
        echo "CHECK $label OK | details: $check_log"
        return 0
    fi
    check_codes=("${PIPESTATUS[@]}")
    check_status=${check_codes[0]}
    if (( check_codes[1] != 0 )); then
        echo "ERROR: check output forwarding failed" \
            "(command exit=${check_codes[0]}, logger exit=${check_codes[1]})" \
            "| log: $check_log | logger details: $writer_log"
        if [[ -s "$writer_log" ]]; then cat -- "$writer_log"; fi
        if (( check_status == 0 )); then check_status=${check_codes[1]}; fi
    fi
    echo "CHECK $label FAILED (exit=$check_status) | full log: $check_log"
    return "$check_status"
}

run_quality_checks() {
    local -a python_paths=(app tests tools ../assets/live/*.py ../iso-tools/*.py ../grub/*.py)
    set -e
    cd "$ROOT"
    run_quality_check "Deployment audit" python3 -m tools.deployment_audit
    run_quality_check "dependencies" uv sync --frozen --extra dev
    run_quality_check "Ruff lint" uv run --frozen python -m ruff check "${python_paths[@]}"
    run_quality_check "Ruff format" \
        uv run --frozen python -m ruff format --check "${python_paths[@]}"
    run_quality_check "Python tests and coverage" \
        uv run --frozen python -u -m pytest tests -vv \
            --cov=app --cov-report=term --cov-fail-under=70
}

{
    trap ':' INT
    echo "Started: $(date --iso-8601=seconds)"
    echo "Log: $LOG"
    echo "Running pre-campaign code checks."
    ( run_quality_checks )
    quality_status=$?
    if (( quality_status != 0 )); then
        echo "STOP: code checks failed (exit=$quality_status). No campaign request was sent."
        exit "$quality_status"
    fi
    echo "Code checks passed."
    echo "Starting campaign. Each VM advances independently."
    client_args=(--log "$LOG" --mode "$MODE")
    if [[ -n "$START_SCENARIO" ]]; then client_args+=(--step "$START_SCENARIO"); fi
    ( cd "$ROOT" && exec "$ROOT/.venv/bin/python" -u -m tools.campaign_client "${client_args[@]}" )
    status=$?
    echo "Finished: $(date --iso-8601=seconds); campaign exit=$status"
    exit "$status"
} 2>&1 | python3 -u "$ROOT/tools/campaign_display.py" "$LOG"
codes=("${PIPESTATUS[@]}")
if (( codes[0] != 0 )); then exit "${codes[0]}"; fi
exit "${codes[1]}"
