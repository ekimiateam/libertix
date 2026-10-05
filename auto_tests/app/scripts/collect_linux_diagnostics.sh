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
collect failed_unit_properties sh -eu -c '
    units=$(systemctl --failed --no-legend --plain --no-pager)
    for unit in $(printf "%s\n" "$units" | awk "{print \$1}"); do
        systemctl show "$unit" --property=Id,ActiveState,SubState,Result,ExecMainCode,ExecMainStatus,ActiveEnterTimestamp,InactiveEnterTimestamp,TimeoutStopUSec
        journalctl -b --no-pager -o short-monotonic -n 80 -u "$unit"
    done
'
collect services systemctl show display-manager ssh libertix-first-boot --property=Id,ActiveState,SubState,Result,ExecMainStatus
collect package_services systemctl show apt-daily.service apt-daily-upgrade.service unattended-upgrades.service apt-daily.timer apt-daily-upgrade.timer --property=Id,ActiveState,SubState,Result,ExecMainStatus,MainPID,ActiveEnterTimestamp
collect package_locks lslocks -o PID,COMMAND,TYPE,MODE,PATH
collect package_database dpkg --audit
collect package_journal journalctl -b --no-pager -o short-monotonic -n 80 -u apt-daily.service -u apt-daily-upgrade.service -u unattended-upgrades.service
# Manager messages preserve the cause of failed scopes without dumping process arguments.
collect unit_manager_journal journalctl -b --no-pager -o short-monotonic -n 200 _PID=1
collect login_journal journalctl -b --no-pager -o short-monotonic -n 100 -u systemd-logind -u lightdm -u display-manager
collect kernel_errors journalctl -b -k --no-pager -o short-monotonic -n 100 -p err
collect storage lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,RO
collect space df -h
collect mounts findmnt -o TARGET,SOURCE,FSTYPE
collect addresses ip -brief address
collect routes ip route
collect resolver resolvectl status
exit "$failed"
