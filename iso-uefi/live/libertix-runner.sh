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
GUI_PID=""
XORG_PID=""
SUCCESS_REBOOT_DELAY=5
XORG_START_TIMEOUT=30
GUI_READY_TIMEOUT=30
GUI_CLIENT_ATTEMPTS=5
TTY_SCREEN_FILE="$LOG_DIR/tty1-screen"
TTY_SCREEN_LAST="$LOG_DIR/tty1-screen.last"
# Display :0 can already be owned by the live system on some UEFI boots.
# Keep the installer on a dedicated X display while still showing it on vt7.
GUI_DISPLAY=":1"
GUI_SOCKET="/tmp/.X11-unix/X1"
GUI_LOCK="/tmp/.X1-lock"
GUI_VT=7

mkdir -p "$LOG_DIR"
touch "$LOG" "$DEBUG_LOG" "$FAIL_FILE"
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
    printf '\033[J' >> "$TTY_SCREEN_FILE.$$"
    if [ -f "$TTY_SCREEN_LAST" ] && cmp -s "$TTY_SCREEN_FILE.$$" "$TTY_SCREEN_LAST"; then
        rm -f "$TTY_SCREEN_FILE.$$"
        return 0
    fi
    cp -f "$TTY_SCREEN_FILE.$$" "$TTY_SCREEN_LAST" 2>/dev/null || true
    # Some live virtual consoles do not translate LF to CRLF after mode
    # switches. Convert explicitly so every redraw starts each line at
    # column 0 instead of drifting diagonally across the screen.
    perl -pe 's/\n/\r\n/g' "$TTY_SCREEN_FILE.$$" > /dev/tty1 2>/dev/null || true
    rm -f "$TTY_SCREEN_FILE.$$"
}

terminal_clear() {
    # Keep redraws stable: moving home and clearing after the new content avoids
    # the black frame caused by a full-screen clear before every refresh.
    printf '\033[?25l\033[H'
}

terminal_full_clear() {
    printf '\033[?25l\033[H\033[2J'
}

build_id() {
    cat /etc/libertix-build-id 2>/dev/null || echo "unknown"
}

stage_label() {
    case "$1" in
        runner-start) echo "Demarrage de l'installateur" ;;
        005-wait-prereqs) echo "Detection du live et du disque" ;;
        006-clean-windows-live-boot) echo "Nettoyage du boot temporaire Windows" ;;
        007-windows-live-boot-cleaned) echo "Boot temporaire nettoye" ;;
        010-read-config) echo "Lecture de la configuration" ;;
        020-detect-disk) echo "Detection des partitions" ;;
        030-check-mint-iso) echo "Verification de l'ISO Mint" ;;
        035-umount-windows) echo "Liberation de la partition Windows" ;;
        040-unmount-target-disk) echo "Liberation du disque cible" ;;
        050-assert-live-detached) echo "Verification du live en RAM" ;;
        060-set-mbr-type-83|060-set-linux-partition-type) echo "Preparation de la partition Linux" ;;
        070-wipefs-live-part) echo "Nettoyage de l'ancien systeme de fichiers" ;;
        080-mkfs-ext4) echo "Creation du systeme de fichiers Linux" ;;
        090-mount-target) echo "Montage de la cible Linux" ;;
        100-remount-windows-ro) echo "Remontage lecture seule de Windows" ;;
        110-loop-mount-mint-iso) echo "Montage de l'ISO Mint" ;;
        120-unsquashfs) echo "Extraction de Mint" ;;
        130-target-system-config) echo "Configuration du systeme installe" ;;
        140-install-bootloader) echo "Installation du bootloader" ;;
        150-final-verify) echo "Verification finale" ;;
        installer-success) echo "Installation terminee" ;;
        installer-failed-*) echo "Installation echouee" ;;
        *) echo "$1" ;;
    esac
}

stage_percent() {
    case "$1" in
        runner-start) echo 1 ;;
        005-wait-prereqs) echo 3 ;;
        006-clean-windows-live-boot) echo 5 ;;
        007-windows-live-boot-cleaned) echo 7 ;;
        010-read-config) echo 10 ;;
        020-detect-disk) echo 14 ;;
        030-check-mint-iso) echo 18 ;;
        035-umount-windows) echo 22 ;;
        040-unmount-target-disk) echo 26 ;;
        050-assert-live-detached) echo 30 ;;
        060-set-mbr-type-83|060-set-linux-partition-type) echo 34 ;;
        070-wipefs-live-part) echo 38 ;;
        080-mkfs-ext4) echo 42 ;;
        090-mount-target) echo 46 ;;
        100-remount-windows-ro) echo 50 ;;
        110-loop-mount-mint-iso) echo 54 ;;
        120-unsquashfs) echo 64 ;;
        130-target-system-config) echo 76 ;;
        140-install-bootloader) echo 90 ;;
        150-final-verify) echo 98 ;;
        installer-success) echo 100 ;;
        installer-failed-*) echo 100 ;;
        *) echo 1 ;;
    esac
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

tty_cols() {
    local cols
    cols="$(stty size < /dev/tty1 2>/dev/null | awk '{print $2}' || true)"
    case "$cols" in
        ''|*[!0-9]*) echo 80 ;;
        *) [ "$cols" -gt 20 ] && echo "$cols" || echo 80 ;;
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

render_boot_logo() {
    {
        terminal_full_clear
        cat <<'LOGO'
============================================================
 Libertix Installer
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

    terminal_clear
    cat <<'LOGO'
 ============================================================
 Libertix Installer
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
    {
        screen_header
        printf '\n Details live:\n'
        tail -44 "$LOG" 2>/dev/null | wrap_tty_lines | sed 's/^/  /'
        printf '\n ------------------------------------------------------------\n'
        printf ' Raccourcis: [D] Progression\n'
        printf ' Logs complets: /run/libertix/install.log\n'
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

cleanup_existing_x_servers() {
    echo "Preparing dedicated installer X session on $GUI_DISPLAY/vt$GUI_VT" >> "$LOG"
    rm -f "$GUI_LOCK" "$GUI_SOCKET"
}

stop_graphical_ui() {
    if [ -n "${GUI_PID:-}" ] && kill -0 "$GUI_PID" 2>/dev/null; then
        kill -TERM -- "-$GUI_PID" 2>/dev/null || kill "$GUI_PID" 2>/dev/null || true
    fi
    if [ -n "${XORG_PID:-}" ] && kill -0 "$XORG_PID" 2>/dev/null; then
        kill "$XORG_PID" 2>/dev/null || true
    fi

    sleep 1

    if [ -n "${GUI_PID:-}" ] && kill -0 "$GUI_PID" 2>/dev/null; then
        kill -KILL -- "-$GUI_PID" 2>/dev/null || kill -9 "$GUI_PID" 2>/dev/null || true
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
    UI_MODE="progress"

    stop_graphical_ui
    chvt 1 2>/dev/null || true
    render_progress
    return 0
}

start_gui() {
    local attempt wait_count x_server
    x_server="$(find_x_server)" || return 1
    [ -x /usr/local/sbin/libertix-gui ] || return 1

    rm -f "$GUI_READY_FILE" "$GUI_HEARTBEAT_FILE" "$DEV_FILE"
    cleanup_existing_x_servers
    echo "Starting graphical installer UI" >> "$LOG"

    if command -v xinit >/dev/null 2>&1; then
        echo "X server selected: $x_server via xinit" >> "$LOG"
        setsid xinit /usr/local/sbin/libertix-gui -- "$x_server" "$GUI_DISPLAY" "vt$GUI_VT" -nolisten tcp -s 0 -dpms -br \
            >> "$GUI_LOG" 2>&1 &
        GUI_PID="$!"

        for wait_count in $(seq 1 "$GUI_READY_TIMEOUT"); do
            if gui_running; then
                chvt "$GUI_VT" 2>/dev/null || true
                echo "Graphical installer UI ready" >> "$LOG"
                return 0
            fi
            if ! kill -0 "$GUI_PID" 2>/dev/null; then
                echo "Graphical UI exited before ready" >> "$LOG"
                echo "Graphical UI details: $GUI_LOG" >> "$LOG"
                break
            fi
            sleep 1
        done
    else
        cleanup_existing_x_servers
        echo "X server selected: $x_server direct fallback" >> "$LOG"
        "$x_server" "$GUI_DISPLAY" "vt$GUI_VT" -nolisten tcp -ac -noreset -s 0 -dpms -br >> "$GUI_LOG" 2>&1 &
        XORG_PID="$!"

        for wait_count in $(seq 1 "$XORG_START_TIMEOUT"); do
            [ -S "$GUI_SOCKET" ] && break
            if ! kill -0 "$XORG_PID" 2>/dev/null; then
                echo "Xorg exited before display socket was ready" >> "$LOG"
                break
            fi
            sleep 1
        done

        if [ -S "$GUI_SOCKET" ]; then
            sleep 1
            for attempt in $(seq 1 "$GUI_CLIENT_ATTEMPTS"); do
                echo "Starting graphical installer client, attempt $attempt/$GUI_CLIENT_ATTEMPTS" >> "$LOG"
                rm -f "$GUI_READY_FILE" "$GUI_HEARTBEAT_FILE"
                DISPLAY="$GUI_DISPLAY" XAUTHORITY=/dev/null /usr/local/sbin/libertix-gui >> "$GUI_LOG" 2>&1 &
                GUI_PID="$!"
                for wait_count in $(seq 1 "$GUI_READY_TIMEOUT"); do
                    if gui_running; then
                        chvt "$GUI_VT" 2>/dev/null || true
                        echo "Graphical installer UI ready" >> "$LOG"
                        return 0
                    fi
                    kill -0 "$GUI_PID" 2>/dev/null || break
                    sleep 1
                done

                if [ -n "${GUI_PID:-}" ] && kill -0 "$GUI_PID" 2>/dev/null; then
                    kill "$GUI_PID" 2>/dev/null || true
                    sleep 1
                    kill -9 "$GUI_PID" 2>/dev/null || true
                fi
                sleep 1
            done
        fi
    fi

    echo "Graphical UI did not report ready; falling back to terminal UI" >> "$LOG"
    echo "Graphical UI details: $GUI_LOG" >> "$LOG"
    stop_graphical_ui
    chvt 1 2>/dev/null || true
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
    local win="" p fs size_mb tmp log_root log_dir

    for p in /dev/sd*[0-9] /dev/vd*[0-9] /dev/nvme*n*p[0-9] /dev/mmcblk*p[0-9]; do
        [ -b "$p" ] || continue
        fs="$(blkid -s TYPE -o value "$p" 2>/dev/null || true)"
        [ "$fs" = "ntfs" ] || continue
        size_mb=$(( $(blockdev --getsize64 "$p" 2>/dev/null || echo 0) / 1024 / 1024 ))
        [ "$size_mb" -gt 1000 ] || continue
        win="$p"
        break
    done

    [ -n "$win" ] || return 0
    tmp="/mnt/libertix-logcopy"
    mkdir -p "$tmp"
    if ! mount -t ntfs-3g "$win" "$tmp" 2>/dev/null; then
        ntfsfix -d "$win" >/dev/null 2>&1 || true
        mount -t ntfs-3g "$win" "$tmp" 2>/dev/null || return 0
    fi
    if mountpoint -q "$tmp"; then
        log_root="$tmp/LibertixInstallLogs"
        log_dir="$log_root/$RUN_ID"
        mkdir -p "$log_dir" "$log_root/latest" 2>/dev/null || true
        cp -f "$LOG" "$log_dir/install.log" 2>/dev/null || true
        cp -f "$GUI_LOG" "$log_dir/gui.log" 2>/dev/null || true
        cp -f "$DEBUG_LOG" "$log_dir/debug.log" 2>/dev/null || true
        cp -f "$STAGE_FILE" "$log_dir/stage.txt" 2>/dev/null || true
        cp -f "$FAIL_FILE" "$log_dir/failure.txt" 2>/dev/null || true
        cp -f "$RESULT_FILE" "$log_dir/result.env" 2>/dev/null || true
        cp -f "$LOG" "$log_root/latest/install.log" 2>/dev/null || true
        cp -f "$GUI_LOG" "$log_root/latest/gui.log" 2>/dev/null || true
        cp -f "$DEBUG_LOG" "$log_root/latest/debug.log" 2>/dev/null || true
        cp -f "$STAGE_FILE" "$log_root/latest/stage.txt" 2>/dev/null || true
        cp -f "$FAIL_FILE" "$log_root/latest/failure.txt" 2>/dev/null || true
        cp -f "$RESULT_FILE" "$log_root/latest/result.env" 2>/dev/null || true
        sync
        umount "$tmp" 2>/dev/null || true
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
echo "installer-failed-rc-$rc" > "$STAGE_FILE"
if [ -s "$FAIL_FILE" ]; then
    echo "runner_rc=$rc" >> "$FAIL_FILE"
else
    echo "rc=$rc" > "$FAIL_FILE"
fi
    {
        echo "LIBERTIX_INSTALL_SUCCESS=false"
        echo "LIBERTIX_INSTALL_RUN_ID=$RUN_ID"
        echo "LIBERTIX_INSTALL_STAGE=$(current_stage)"
        echo "LIBERTIX_INSTALL_RC=$rc"
    } > "$RESULT_FILE"
    {
        echo ""
        echo "LIBERTIX_INSTALL_SUCCESS=false"
        echo "LIBERTIX_INSTALL_RUN_ID=$RUN_ID"
        echo "LIBERTIX_INSTALL_STAGE=$(current_stage)"
        echo "LIBERTIX_INSTALL_RC=$rc"
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
                printf ' Logs copies dans C:\\LibertixInstallLogs quand Windows est disponible.\n'
            } | write_tty1_screen
        fi
        render_serial_status
        sleep 1
    done
    printf '\033[?25h' > /dev/tty1 2>/dev/null || true
    stop_graphical_ui
    sync
    systemctl reboot -i --no-block 2>/dev/null || true
    sleep 3
    reboot -f
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
                    printf '\033[?25h' > /dev/tty1 2>/dev/null || true
                    stop_graphical_ui
                    sync
                    systemctl reboot -i --no-block 2>/dev/null || true
                    sleep 3
                    reboot -f
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
        chvt 1 2>/dev/null || true
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
