#!/bin/sh
failed=0
collect() {
    printf '\n=== %s ===\n' "$1"
    shift
    timeout 15 "$@" || { printf 'COLLECTION_ERROR: exit=%s\n' "$?"; failed=1; }
}
collect time date --iso-8601=seconds
collect uptime uptime
collect kernel uname -a
collect memory free -m
# Command names, not argument vectors or environments: those may contain credentials.
collect processes ps -eo pid,ppid,uid,stat,etimes,pcpu,pmem,wchan:32,comm
collect sessions loginctl list-sessions --no-pager
collect session_properties sh -eu -c 'sessions=$(loginctl list-sessions --no-legend); for sid in $(printf "%s\n" "$sessions" | awk "{print \$1}"); do loginctl show-session "$sid" -p Id -p User -p Name -p Type -p Class -p Active -p State -p LockedHint -p Leader -p Seat -p TTY; done'
collect failed_units systemctl --failed --no-pager
collect services systemctl show display-manager ssh libertix-first-boot --property=Id,ActiveState,SubState,Result,ExecMainStatus
collect storage lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,RO
collect space df -h
collect mounts findmnt -o TARGET,SOURCE,FSTYPE
collect addresses ip -brief address
collect routes ip route
collect resolver resolvectl status
exit "$failed"
