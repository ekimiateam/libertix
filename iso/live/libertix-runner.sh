#!/bin/bash
set -u

LOG_DIR="/run/libertix"
LOG="$LOG_DIR/install.log"
DEBUG_LOG="$LOG_DIR/debug.log"
STAGE_FILE="$LOG_DIR/stage"
FAIL_FILE="$LOG_DIR/failure"

mkdir -p "$LOG_DIR"
touch "$LOG" "$DEBUG_LOG"
echo "runner-start" > "$STAGE_FILE"

tty_write() {
    local tty="$1"
    shift
    [ -e "$tty" ] || return 0
    {
        printf '\033c'
        printf '%s\n' "============================================================"
        printf '%s\n' " Libertix / Libertix automatic installer"
        printf '%s\n' "============================================================"
        printf 'Time: %s\n' "$(date -Is 2>/dev/null || date)"
        printf 'Build: %s\n' "$(cat /etc/libertix-build-id 2>/dev/null || echo unknown)"
        printf 'Stage: %s\n' "$(cat "$STAGE_FILE" 2>/dev/null || echo unknown)"
        printf '%s\n' "------------------------------------------------------------"
        printf '%s\n' "$@"
        printf '%s\n' "------------------------------------------------------------"
        printf '%s\n' "Full log: /run/libertix/install.log"
        printf '%s\n' "Debug shell: Alt-F2 / tty2"
    } > "$tty" 2>/dev/null || true
}

progress_screen() {
    local tail_lines
    tail_lines="$(grep -E '^(STAGE|ERROR|OK:|rc=|Windows:|ISO found|Live partition|Setting MBR|Mounting|Extracting|Libertix build)' "$LOG" 2>/dev/null | tail -14 || true)"
    [ -n "$tail_lines" ] || tail_lines="$(tail -12 "$LOG" 2>/dev/null || true)"
    tty_write /dev/tty1 "$tail_lines"
    tty_write /dev/ttyS0 "$tail_lines"
}

collect_debug() {
    {
        echo "===== collect_debug $(date -Is 2>/dev/null || date) ====="
        echo "--- stage ---"
        cat "$STAGE_FILE" 2>/dev/null || true
        echo "--- failure ---"
        cat "$FAIL_FILE" 2>/dev/null || true
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
    local win="" p fs size_mb tmp

    for p in /dev/sd*[0-9] /dev/nvme*n*p[0-9]; do
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
    if mount -t ntfs-3g "$win" "$tmp" 2>/dev/null; then
        mkdir -p "$tmp/Windows/Temp/Libertix" 2>/dev/null || true
        cp -f "$LOG" "$tmp/Windows/Temp/Libertix/live-install.log" 2>/dev/null || true
        cp -f "$DEBUG_LOG" "$tmp/Windows/Temp/Libertix/live-debug.log" 2>/dev/null || true
        cp -f "$STAGE_FILE" "$tmp/Windows/Temp/Libertix/live-stage.txt" 2>/dev/null || true
        cp -f "$FAIL_FILE" "$tmp/Windows/Temp/Libertix/live-failure.txt" 2>/dev/null || true
        sync
        umount "$tmp" 2>/dev/null || true
    fi
}

tty_write /dev/tty1 "Starting Libertix installer..."
tty_write /dev/ttyS0 "Starting Libertix installer..."

(
    echo "===== libertix installer started $(date -Is 2>/dev/null || date) ====="
    echo "build=$(cat /etc/libertix-build-id 2>/dev/null || echo unknown)"
    /install-mint.sh
) >> "$LOG" 2>&1 &
pid="$!"

while kill -0 "$pid" 2>/dev/null; do
    progress_screen
    sleep 5
done

wait "$pid"
rc="$?"

if [ "$rc" -eq 0 ]; then
    echo "installer-success" > "$STAGE_FILE"
    progress_screen
    tty_write /dev/tty1 "INSTALLATION COMPLETED. Rebooting in 5 seconds."
    sleep 5
    systemctl reboot -i
    exit 0
fi

echo "installer-failed-rc-$rc" > "$STAGE_FILE"
echo "rc=$rc" > "$FAIL_FILE"
collect_debug
copy_logs_to_windows_best_effort

while true; do
    tail_lines="$(tail -18 "$LOG" 2>/dev/null || true)"
    tty_write /dev/tty1 "ERROR: Libertix installer failed with rc=$rc

Stage: $(cat "$STAGE_FILE" 2>/dev/null || echo unknown)

Last install log lines:
$tail_lines

The VM is intentionally paused here for screenshot/debug."
    tty_write /dev/ttyS0 "ERROR: Libertix installer failed with rc=$rc

Stage: $(cat "$STAGE_FILE" 2>/dev/null || echo unknown)

Last install log lines:
$tail_lines"
    sleep 10
done