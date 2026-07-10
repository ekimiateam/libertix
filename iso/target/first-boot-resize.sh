#!/bin/bash
set -e

LOG="/var/log/libertix/first-boot-resize.log"
mkdir -p "$(dirname "$LOG")"
echo "First boot resize - $(date)" > "$LOG"

ROOT_DEV="$(findmnt -n -o SOURCE /)"
[ -b "$ROOT_DEV" ] || { echo "Root source is not a block device: $ROOT_DEV" >> "$LOG"; exit 1; }
[ "$(findmnt -n -o FSTYPE /)" = "ext4" ] || { echo "Root filesystem is not ext4" >> "$LOG"; exit 1; }
resize2fs "$ROOT_DEV" >> "$LOG" 2>&1
resize2fs -P "$ROOT_DEV" >> "$LOG" 2>&1
df -hT / >> "$LOG" 2>&1

systemctl disable first-boot-resize.service >> "$LOG" 2>&1
rm -f /etc/systemd/system/first-boot-resize.service /usr/local/bin/first-boot-resize.sh
