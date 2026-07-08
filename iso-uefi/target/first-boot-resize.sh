#!/bin/bash
set -e

LOG="/tmp/first-boot-resize.log"
echo "First boot resize - $(date)" > "$LOG"

ROOT_DEV="$(findmnt -n -o SOURCE /)"
resize2fs "$ROOT_DEV" >> "$LOG" 2>&1

systemctl disable first-boot-resize.service
rm -f /etc/systemd/system/first-boot-resize.service /usr/local/bin/first-boot-resize.sh
