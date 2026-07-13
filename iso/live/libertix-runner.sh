#!/bin/bash
set -u
trap '' HUP

LOG_DIR="/run/libertix"
LOG="$LOG_DIR/install.log"
DEBUG_LOG="$LOG_DIR/debug.log"
STAGE_FILE="$LOG_DIR/stage"
FAIL_FILE="$LOG_DIR/failure"
RESULT_FILE="$LOG_DIR/result.env"
DEV_FILE="$LOG_DIR/dev-terminal"
GUI_LOG="$LOG_DIR/gui.log"
GUI_READY_FILE="$LOG_DIR/gui-ready"
GUI_HEARTBEAT_FILE="$LOG_DIR/gui-heartbeat"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ 2>/dev/null || date +%s)"
UI_MODE="progress"
LAST_RENDER_KEY=""
DEV_TERMINAL_ACTIVE=false
GUI_PID=""
XORG_PID=""
SUCCESS_REBOOT_DELAY=5
XORG_START_TIMEOUT=30
GUI_READY_TIMEOUT=30
GUI_CLIENT_ATTEMPTS=5
TTY_SCREEN_FILE="$LOG_DIR/tty1-screen"
TTY_SCREEN_LAST="$LOG_DIR/tty1-screen.last"
GUI_DISPLAY=":0"
GUI_SOCKET="/tmp/.X11-unix/X0"
GUI_LOCK="/tmp/.X0-lock"
GUI_VT=7
LOG_COPY_STATUS="not-attempted"

. /usr/local/lib/libertix/libertix-runner-stage-common.sh

mkdir -p "$LOG_DIR"
touch "$LOG" "$DEBUG_LOG" "$FAIL_FILE"
# Keep every kernel message available through dmesg/journal without allowing
# console printk to overwrite the dedicated tty1 UI.
dmesg -n 1 2>/dev/null || true
rm -f "$DEV_FILE" "$GUI_READY_FILE" "$GUI_HEARTBEAT_FILE"
echo "runner-start" > "$STAGE_FILE"
cat > "$RESULT_FILE" <<EOF
LIBERTIX_INSTALL_SUCCESS=false
LIBERTIX_INSTALL_RUN_ID=$RUN_ID
LIBERTIX_INSTALL_STAGE=runner-start
EOF

current_stage() {
    cat "$STAGE_FILE" 2>/dev/null || echo "unknown"
}

write_tty1_screen() {
    [ -e /dev/tty1 ] || return 0
    cat > "$TTY_SCREEN_FILE.$$"
    if [ -f "$TTY_SCREEN_LAST" ] && cmp -s "$TTY_SCREEN_FILE.$$" "$TTY_SCREEN_LAST"; then
        rm -f "$TTY_SCREEN_FILE.$$"
        return 0
    fi
    cp -f "$TTY_SCREEN_FILE.$$" "$TTY_SCREEN_LAST" 2>/dev/null || true
    {
        printf '\033[?25l\033[H'
        perl -pe 's/\n/\r\n/g' "$TTY_SCREEN_FILE.$$"
        printf '\033[J'
    } > /dev/tty1 2>/dev/null || true
    rm -f "$TTY_SCREEN_FILE.$$"
}

terminal_full_clear() {
    printf '\033[?25l\033[H\033[2J'
}

prepare_terminal_ui() {
    chvt 1 2>/dev/null || true
    sleep 0.25
    printf '\033[?25l\033[H\033[2J' > /dev/tty1 2>/dev/null || true
    rm -f "$TTY_SCREEN_LAST"
}

tty_cols() {
    local cols
    cols="$(stty size < /dev/tty1 2>/dev/null | awk '{print $2}' || true)"
    case "$cols" in
        ''|*[!0-9]*) echo 80 ;;
        *) [ "$cols" -gt 20 ] && echo "$cols" || echo 80 ;;
    esac
}

tty_rows() {
    local rows
    rows="$(stty size < /dev/tty1 2>/dev/null | awk '{print $1}' || true)"
    case "$rows" in
        ''|*[!0-9]*) echo 48 ;;
        *) [ "$rows" -gt 16 ] && echo "$rows" || echo 48 ;;
    esac
}

clip_tty_lines() {
    local cols max
    cols="$(tty_cols)"
    max=$((cols - 4))
    [ "$max" -gt 20 ] || max=76
    cut -c1-"$max"
}

wrap_tty_lines() {
    local cols max
    cols="$(tty_cols)"
    max=$((cols - 4))
    [ "$max" -gt 20 ] || max=76
    fold -sw "$max"
}

build_id() {
    cat /etc/libertix-build-id 2>/dev/null || echo "unknown"
}

stage_label() {
    libertix_stage_label "$1"
}

stage_percent() {
    libertix_stage_percent "$1"
}

unsquashfs_subpercent() {
    awk '
        /STAGE: 120-unsquashfs/ { found=1; next }
        /STAGE: 130-target-system-config/ { found=0 }
        found {
            line=$0
            while (match(line, /[0-9]+\/[0-9]+/)) {
                split(substr(line, RSTART, RLENGTH), parts, "/")
                if (parts[2] > 0) {
                    value=int(parts[1] * 100 / parts[2])
                    if (value > best && value <= 100) best=value
                }
                line=substr(line, RSTART + RLENGTH)
            }
            line=$0
            while (match(line, /[0-9]{1,3}%/)) {
                value=substr(line, RSTART, RLENGTH - 1) + 0
                if (value > best && value <= 100) best=value
                line=substr(line, RSTART + RLENGTH)
            }
        }
        END { if (best != "") print best }
    ' "$LOG" 2>/dev/null || true
}

stage_percent_dynamic() {
    local stage="$1"
    local sub
    if [ "$stage" = "120-unsquashfs" ]; then
        sub="$(unsquashfs_subpercent)"
        if [ -n "$sub" ]; then
            echo $((54 + sub * 22 / 100))
            return 0
        fi
        echo 54
        return 0
    fi
    stage_percent "$stage"
}

stage_label_dynamic() {
    local stage="$1"
    local sub
    if [ "$stage" = "120-unsquashfs" ]; then
        sub="$(unsquashfs_subpercent)"
        if [ -n "$sub" ]; then
            printf 'Extraction de Mint (%s%%)\n' "$sub"
            return 0
        fi
    fi
    stage_label "$stage"
}

progress_bar() {
    local percent="$1"
    local width="${2:-42}"
    local filled empty
    filled=$((percent * width / 100))
    empty=$((width - filled))
    printf '['
    printf '%*s' "$filled" '' | tr ' ' '#'
    printf '%*s' "$empty" '' | tr ' ' '-'
    printf '] %3s%%' "$percent"
}

render_boot_logo() {
    {
        terminal_full_clear
        cat <<'LOGO'
============================================================
 _     _ _               _   _
| |   (_) |__   ___ _ __| |_(_)_  __
| |   | |  _ \ / _ \  __| __| \ \/ /
| |___| | |_) |  __/ |  | |_| |>  <
|_____|_|_.__/ \___|_|   \__|_/_/\_\
============================================================
LOGO
        printf "\nDemarrage de l'installation...\n"
        printf 'Build: %s\n' "$(build_id)"
    } | write_tty1_screen
}

screen_header() {
    local stage percent
    stage="$(current_stage)"
    percent="$(stage_percent_dynamic "$stage")"

    printf '\033[?25l'
    cat <<'LOGO'
 ============================================================
  _     _ _               _   _
 | |   (_) |__   ___ _ __| |_(_)_  __
 | |   | |  _ \ / _ \  __| __| \ \/ /
 | |___| | |_) |  __/ |  | |_| |>  <
 |_____|_|_.__/ \___|_|   \__|_/_/\_\
 ============================================================
LOGO
    printf ' Build: %s\n' "$(build_id)"
    printf ' Etape: %s\n' "$(stage_label_dynamic "$stage")"
    printf ' Code : %s\n\n' "$stage"
    printf ' '
    progress_bar "$percent" 48
    printf '\n'
}

important_tail() {
    grep -E '^(STAGE|ERROR|OK:|rc=|Windows:|ISO found|Live partition|Setting MBR|Mounting|Extracting|Libertix build|ROLLBACK|LIBERTIX_INSTALL|FINAL VERIFY)' "$LOG" 2>/dev/null | tail -14 || true
}

render_progress() {
    local lines
    lines="$(important_tail)"
    [ -n "$lines" ] || lines="$(tail -8 "$LOG" 2>/dev/null || true)"
    {
        screen_header
        printf '\n Action en cours:\n'
        printf ' %s\n\n' "$(stage_label_dynamic "$(current_stage)")"
        printf ' Derniers evenements:\n'
        printf '%s\n' "$lines" | clip_tty_lines | sed 's/^/  /'
        printf '\n ------------------------------------------------------------\n'
        printf ' Raccourcis: [D] Plus de details\n'
        printf ' Logs: /run/libertix/install.log\n'
    } | write_tty1_screen
}

render_details() {
    local rows log_lines
    rows="$(tty_rows)"
    log_lines=$((rows - 10))
    [ "$log_lines" -ge 8 ] || log_lines=8
    {
        printf '\033[?25l'
        printf ' ============================================================\n'
        printf ' Libertix DEV | Build: %s\n' "$(build_id)"
        printf ' Etape: %s | Code: %s\n' \
            "$(stage_label_dynamic "$(current_stage)")" "$(current_stage)"
        printf ' ============================================================\n'
        printf ' install.log (les %s dernieres lignes):\n' "$log_lines"
        tail -n "$log_lines" "$LOG" 2>/dev/null | clip_tty_lines | sed 's/^/  /'
        printf ' ------------------------------------------------------------\n'
        printf ' [D] Progression | Journal complet: /run/libertix/install.log\n'
    } | write_tty1_screen
}

render_serial_status() {
    local lines
    [ -e /dev/ttyS0 ] || return 0
    lines="$(important_tail)"
    [ -n "$lines" ] || lines="$(tail -8 "$LOG" 2>/dev/null || true)"
    {
        printf 'LIBERTIX stage=%s build=%s\n' "$(current_stage)" "$(build_id)"
        printf '%s\n' "$lines"
    } > /dev/ttyS0 2>/dev/null || true
}

find_x_server() {
    for candidate in /usr/lib/xorg/Xorg /usr/bin/Xorg /usr/bin/X; do
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

gui_heartbeat_fresh() {
    local now mtime
    [ -f "$GUI_HEARTBEAT_FILE" ] || return 1
    now="$(date +%s)"
    mtime="$(stat -c %Y "$GUI_HEARTBEAT_FILE" 2>/dev/null || echo 0)"
    [ $((now - mtime)) -le 3 ]
}

gui_running() {
    [ -n "${GUI_PID:-}" ] \
        && kill -0 "$GUI_PID" 2>/dev/null \
        && [ -f "$GUI_READY_FILE" ] \
        && gui_heartbeat_fresh \
        && [ ! -f "$DEV_FILE" ]
}

graphical_ui_started() {
    { [ -n "${GUI_PID:-}" ] && kill -0 "$GUI_PID" 2>/dev/null; } \
        || { [ -n "${XORG_PID:-}" ] && kill -0 "$XORG_PID" 2>/dev/null; }
}

cleanup_existing_x_server() {
    echo "Preparing installer X session on $GUI_DISPLAY/vt$GUI_VT" >> "$LOG"
    rm -f "$GUI_LOCK" "$GUI_SOCKET"
}

stop_graphical_ui() {
    if [ -n "${GUI_PID:-}" ] && kill -0 "$GUI_PID" 2>/dev/null; then
        kill "$GUI_PID" 2>/dev/null || true
    fi
    if [ -n "${XORG_PID:-}" ] && kill -0 "$XORG_PID" 2>/dev/null; then
        kill "$XORG_PID" 2>/dev/null || true
    fi

    sleep 1

    if [ -n "${GUI_PID:-}" ] && kill -0 "$GUI_PID" 2>/dev/null; then
        kill -9 "$GUI_PID" 2>/dev/null || true
    fi
    if [ -n "${XORG_PID:-}" ] && kill -0 "$XORG_PID" 2>/dev/null; then
        kill -9 "$XORG_PID" 2>/dev/null || true
    fi

    GUI_PID=""
    XORG_PID=""
    rm -f "$GUI_READY_FILE" "$GUI_HEARTBEAT_FILE"
}

switch_to_terminal_ui_if_requested() {
    [ -f "$DEV_FILE" ] || return 1
    [ "$DEV_TERMINAL_ACTIVE" = false ] || return 1
    DEV_TERMINAL_ACTIVE=true
    UI_MODE="details"

    stop_graphical_ui
    prepare_terminal_ui
    LAST_RENDER_KEY=""
    render_current_screen
    return 0
}

start_gui() {
    local attempt wait_count x_server
    x_server="$(find_x_server)" || return 1
    [ -x /usr/local/sbin/libertix-gui ] || return 1

    rm -f "$GUI_READY_FILE" "$GUI_HEARTBEAT_FILE" "$DEV_FILE"
    cleanup_existing_x_server
    echo "Starting graphical installer UI with direct Xorg: $x_server $GUI_DISPLAY vt$GUI_VT" >> "$LOG"
    "$x_server" "$GUI_DISPLAY" "vt$GUI_VT" -nolisten tcp -ac -noreset -s 0 -dpms -br >> "$GUI_LOG" 2>&1 &
    XORG_PID="$!"

    for wait_count in $(seq 1 "$XORG_START_TIMEOUT"); do
        [ -S "$GUI_SOCKET" ] && break
        if ! kill -0 "$XORG_PID" 2>/dev/null; then
            echo "Xorg exited before display socket was ready" >> "$LOG"
            tail -40 "$GUI_LOG" >> "$LOG" 2>/dev/null || true
            stop_graphical_ui
            prepare_terminal_ui
            return 1
        fi
        sleep 1
    done

    if [ ! -S "$GUI_SOCKET" ]; then
        echo "Xorg display socket did not appear; falling back to terminal UI" >> "$LOG"
        tail -40 "$GUI_LOG" >> "$LOG" 2>/dev/null || true
        stop_graphical_ui
        prepare_terminal_ui
        return 1
    fi

    sleep 1

    for attempt in $(seq 1 "$GUI_CLIENT_ATTEMPTS"); do
        echo "Starting graphical installer client, attempt $attempt/$GUI_CLIENT_ATTEMPTS" >> "$LOG"
        rm -f "$GUI_READY_FILE" "$GUI_HEARTBEAT_FILE"
        DISPLAY="$GUI_DISPLAY" XAUTHORITY=/dev/null /usr/local/sbin/libertix-gui >> "$GUI_LOG" 2>&1 &
        GUI_PID="$!"

        for wait_count in $(seq 1 "$GUI_READY_TIMEOUT"); do
            if gui_running; then
                chvt "$GUI_VT" 2>/dev/null || true
                return 0
            fi
            if ! kill -0 "$GUI_PID" 2>/dev/null; then
                echo "Graphical UI client exited before ready, attempt $attempt" >> "$LOG"
                tail -25 "$GUI_LOG" >> "$LOG" 2>/dev/null || true
                break
            fi
            sleep 1
        done

        if [ -n "${GUI_PID:-}" ] && kill -0 "$GUI_PID" 2>/dev/null; then
            kill "$GUI_PID" 2>/dev/null || true
            sleep 1
            kill -9 "$GUI_PID" 2>/dev/null || true
        fi
        sleep 1
    done

    echo "Graphical UI did not report ready; falling back to terminal UI" >> "$LOG"
    tail -60 "$GUI_LOG" >> "$LOG" 2>/dev/null || true
    stop_graphical_ui
    prepare_terminal_ui
    return 1
}

handle_live_keys() {
    local key=""
    [ -e /dev/tty1 ] || return 0
    if read -r -s -n 1 -t 0.1 key < /dev/tty1 2>/dev/null; then
        case "$key" in
            d|D)
                if [ "$UI_MODE" = "details" ]; then
                    UI_MODE="progress"
                else
                    UI_MODE="details"
                fi
                ;;
        esac
    fi
}

render_current_screen() {
    local log_size render_key
    log_size="$(stat -c %s "$LOG" 2>/dev/null || echo 0)"
    render_key="$(current_stage):$UI_MODE:$log_size"
    [ "$render_key" != "$LAST_RENDER_KEY" ] || {
        render_serial_status
        return 0
    }
    LAST_RENDER_KEY="$render_key"
    case "$UI_MODE" in
        details) render_details ;;
        *) render_progress ;;
    esac
    render_serial_status
}

collect_debug() {
    {
        echo "===== collect_debug $(date -Is 2>/dev/null || date) ====="
        echo "--- stage ---"
        cat "$STAGE_FILE" 2>/dev/null || true
        echo "--- failure ---"
        cat "$FAIL_FILE" 2>/dev/null || true
        echo "--- result ---"
        cat "$RESULT_FILE" 2>/dev/null || true
        echo "--- cmdline ---"
        cat /proc/cmdline 2>/dev/null || true
        echo "--- lsblk ---"
        lsblk -e7 -o NAME,MAJ:MIN,PKNAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS 2>/dev/null || true
        echo "--- findmnt ---"
        findmnt -rn -o SOURCE,TARGET,FSTYPE,OPTIONS 2>/dev/null || true
        echo "--- /proc/partitions ---"
        cat /proc/partitions 2>/dev/null || true
        echo "--- /proc/swaps ---"
        cat /proc/swaps 2>/dev/null || true
        echo "--- losetup ---"
        losetup -a 2>/dev/null || true
        echo "--- dmesg tail ---"
        dmesg | tail -200 2>/dev/null || true
        echo "--- journal libertix ---"
        journalctl -b -u libertix-install.service --no-pager 2>/dev/null || true
    } >> "$DEBUG_LOG" 2>&1
}

copy_logs_to_windows_best_effort() {
    if /usr/local/sbin/libertix-copy-logs "$RUN_ID"; then
        LOG_COPY_STATUS="success"
    else
        LOG_COPY_STATUS="failed"
    fi
}

write_success_result() {
    echo "installer-success" > "$STAGE_FILE"
    {
        echo "LIBERTIX_INSTALL_SUCCESS=true"
        echo "LIBERTIX_INSTALL_RUN_ID=$RUN_ID"
        echo "LIBERTIX_INSTALL_STAGE=installer-success"
        echo "LIBERTIX_INSTALL_RC=0"
    } > "$RESULT_FILE"
    {
        echo ""
        echo "LIBERTIX_INSTALL_SUCCESS=true"
        echo "LIBERTIX_INSTALL_RUN_ID=$RUN_ID"
        echo "LIBERTIX_INSTALL_STAGE=installer-success"
    } >> "$LOG"
}

write_failure_result() {
    local rc="$1"
    local rollback
    rollback="$(grep '^LIBERTIX_INSTALL_ROLLBACK=' "$LOG" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    [ -n "$rollback" ] || rollback="unknown"
    echo "installer-failed-rc-$rc" > "$STAGE_FILE"
    echo "rc=$rc" > "$FAIL_FILE"
    {
        echo "LIBERTIX_INSTALL_SUCCESS=false"
        echo "LIBERTIX_INSTALL_RUN_ID=$RUN_ID"
        echo "LIBERTIX_INSTALL_STAGE=$(current_stage)"
        echo "LIBERTIX_INSTALL_RC=$rc"
        echo "LIBERTIX_INSTALL_ROLLBACK=$rollback"
    } > "$RESULT_FILE"
    {
        echo ""
        echo "LIBERTIX_INSTALL_SUCCESS=false"
        echo "LIBERTIX_INSTALL_RUN_ID=$RUN_ID"
        echo "LIBERTIX_INSTALL_STAGE=$(current_stage)"
        echo "LIBERTIX_INSTALL_RC=$rc"
        echo "LIBERTIX_INSTALL_ROLLBACK=$rollback"
    } >> "$LOG"
}

success_screen_and_reboot() {
    local remaining
    for remaining in $(seq "$SUCCESS_REBOOT_DELAY" -1 1); do
        if gui_running; then
            render_serial_status
        else
            {
                screen_header
                printf '\n Installation terminee et verifiee.\n'
                printf ' Redemarrage automatique dans %s seconde(s).\n\n' "$remaining"
                if [ "$LOG_COPY_STATUS" = "success" ]; then
                    printf ' Logs verifies dans C:\\LibertixInstallLogs.\n'
                else
                    printf ' ATTENTION: copie des logs Windows en echec.\n'
                fi
            } | write_tty1_screen
        fi
        render_serial_status
        sleep 1
    done
    printf '\033[?25h' > /dev/tty1 2>/dev/null || true
    systemctl reboot -i
}

failure_screen_loop() {
    local rc="$1"
    local key=""
    UI_MODE="progress"
    while true; do
        if switch_to_terminal_ui_if_requested; then
            sleep 1
            continue
        fi

        if gui_running; then
            render_serial_status
            sleep 1
            continue
        fi

        if [ -e /dev/tty1 ] && read -r -s -n 1 -t 0.1 key < /dev/tty1 2>/dev/null; then
            case "$key" in
                d|D)
                    if [ "$UI_MODE" = "details" ]; then UI_MODE="progress"; else UI_MODE="details"; fi
                    ;;
                r|R)
                    grep -q '^LIBERTIX_INSTALL_ROLLBACK=completed$' "$RESULT_FILE" 2>/dev/null || continue
                    printf '\033[?25h' > /dev/tty1 2>/dev/null || true
                    systemctl reboot -i
                    ;;
            esac
        fi

        if [ "$UI_MODE" = "details" ]; then
            render_details
        else
            {
                screen_header
                printf '\n ERREUR: installation arretee avec rc=%s\n\n' "$rc"
                printf ' Etape: %s\n\n' "$(current_stage)"
                if [ -s "$FAIL_FILE" ]; then
                    printf ' Message:\n'
                    sed 's/^/  /' "$FAIL_FILE"
                    printf '\n'
                fi
                printf ' Dernieres lignes:\n'
                tail -10 "$LOG" 2>/dev/null | clip_tty_lines | sed 's/^/  /'
                printf '\n ------------------------------------------------------------\n'
                printf ' Raccourcis: [R] Reboot   [D] Plus de details\n'
                printf ' Logs: /run/libertix/install.log\n'
            } | write_tty1_screen
            render_serial_status
        fi
        sleep 1
    done
}

render_boot_logo
sleep 1

if ! start_gui; then
    render_progress
fi

(
    echo "===== libertix installer started $(date -Is 2>/dev/null || date) ====="
    echo "build=$(build_id)"
    /install-mint.sh
) >> "$LOG" 2>&1 &
pid="$!"

while kill -0 "$pid" 2>/dev/null; do
    if switch_to_terminal_ui_if_requested; then
        sleep 1
    elif gui_running; then
        render_serial_status
    elif graphical_ui_started; then
        echo "Graphical UI stopped or became unhealthy; falling back to terminal UI" >> "$LOG"
        stop_graphical_ui
        prepare_terminal_ui
        render_current_screen
    else
        handle_live_keys
        render_current_screen
    fi
    sleep 1
done

wait "$pid"
rc="$?"

if [ "$rc" -eq 0 ]; then
    write_success_result
    collect_debug
    copy_logs_to_windows_best_effort
    success_screen_and_reboot
    exit 0
fi

write_failure_result "$rc"
collect_debug
copy_logs_to_windows_best_effort
failure_screen_loop "$rc"
