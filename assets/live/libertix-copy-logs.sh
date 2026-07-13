#!/bin/bash
set -u

LOG_DIR="/run/libertix"
RUN_ID="${1:?missing run id}"
STATUS_FILE="$LOG_DIR/log-copy-status.txt"
DEBUG_LOG="$LOG_DIR/debug.log"
win="$(cat "$LOG_DIR/windows-partition" 2>/dev/null || true)"
mounted_target=""
restore_ro=false
mounted_here=false
target=""

cleanup_mount() {
    if $restore_ro && [ -n "$target" ]; then
        mount -o remount,ro "$target" >> "$DEBUG_LOG" 2>&1 || true
    fi
    if $mounted_here && [ -n "$target" ]; then
        umount "$target" >> "$DEBUG_LOG" 2>&1 || true
    fi
}

trap cleanup_mount EXIT

fail() {
    printf 'failed: %s\n' "$1" > "$STATUS_FILE"
    printf 'LOG COPY ERROR: %s\n' "$1" >> "$DEBUG_LOG"
    exit 1
}

# Preserve complete boot diagnostics, not just the installer stdout.
journalctl -b --no-pager > "$LOG_DIR/journal-boot.log" 2>&1 || true
dmesg > "$LOG_DIR/dmesg.log" 2>&1 || true
systemctl status libertix-install.service --no-pager -l > "$LOG_DIR/systemctl-libertix.log" 2>&1 || true
cp -f /var/log/Xorg.*.log "$LOG_DIR/" 2>/dev/null || true

[ -n "$win" ] && [ -b "$win" ] || fail "Windows partition is unavailable"
fs="$(blkid -s TYPE -o value "$win" 2>/dev/null || true)"
case "$fs" in
    ntfs|ntfs3) ;;
    *) fail "unsupported Windows filesystem '$fs'" ;;
esac

mounted_target="$(findmnt -rn -S "$win" -o TARGET 2>/dev/null | head -1 || true)"
if [ -n "$mounted_target" ]; then
    target="$mounted_target"
    if findmnt -rn -T "$target" -o OPTIONS 2>/dev/null | tr ',' '\n' | grep -qx ro; then
        mount -o remount,rw "$target" >> "$DEBUG_LOG" 2>&1 || fail "cannot remount $target read-write"
        restore_ro=true
    fi
else
    target="/mnt/libertix-logcopy"
    mkdir -p "$target"
    mount -t ntfs-3g "$win" "$target" >> "$DEBUG_LOG" 2>&1 || fail "cannot mount $win"
    mounted_here=true
fi

log_root="$target/LibertixInstallLogs"
log_dir="$log_root/$RUN_ID"
mkdir -p "$log_dir" "$log_root/latest" || fail "cannot create $log_dir"
printf 'copying: %s\n' "$log_dir" > "$STATUS_FILE"
cp -a "$LOG_DIR/." "$log_dir/" || fail "cannot copy complete log directory"
cp -a "$LOG_DIR/." "$log_root/latest/" || fail "cannot update latest log directory"

printf 'success: %s\n' "$log_dir" > "$STATUS_FILE"
cp -f "$STATUS_FILE" "$log_dir/log-copy-status.txt"
cp -f "$STATUS_FILE" "$log_root/latest/log-copy-status.txt"
cp -f "$LOG_DIR/install.log" "$log_dir/install.log"
cp -f "$LOG_DIR/install.log" "$log_root/latest/install.log"
(cd "$log_dir" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum > SHA256SUMS)
cp -f "$log_dir/SHA256SUMS" "$log_root/latest/SHA256SUMS"
sync
