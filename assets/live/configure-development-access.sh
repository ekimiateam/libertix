#!/bin/bash
set -Eeuo pipefail

[ "${DEVELOPMENT_SSH_ENABLED:-false}" = "true" ] || exit 0

[[ "$DEVELOPMENT_STATIC_IPV4_ADDRESS" =~ ^192\.168\.1\.([0-9]{1,3})$ ]]
last_octet="${BASH_REMATCH[1]}"
[ "$last_octet" -gt 1 ] && [ "$last_octet" -lt 255 ]
[ "$DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH" = "24" ]
[ "$DEVELOPMENT_STATIC_IPV4_GATEWAY" = "192.168.1.1" ]
[ "$DEVELOPMENT_DNS_PRIMARY" = "8.8.8.8" ]
[ "$DEVELOPMENT_DNS_SECONDARY" = "1.1.1.1" ]
id "$USERNAME" >/dev/null 2>&1

# A high-priority generic Ethernet profile lets the installed system retain
# the Windows VM address without depending on a firmware-specific interface
# name. Windows is no longer running when this profile becomes active.
install -d -m 0755 /etc/NetworkManager/system-connections
cat > /etc/NetworkManager/system-connections/libertix-development-static.nmconnection <<EOF
[connection]
id=Libertix development static IPv4
uuid=71f62316-a026-4bf5-9006-54fa872d42a0
type=ethernet
autoconnect=true
autoconnect-priority=1000

[ethernet]

[ipv4]
method=manual
address1=$DEVELOPMENT_STATIC_IPV4_ADDRESS/$DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH,$DEVELOPMENT_STATIC_IPV4_GATEWAY
dns=$DEVELOPMENT_DNS_PRIMARY;$DEVELOPMENT_DNS_SECONDARY;
dns-priority=-100
never-default=false

[ipv6]
method=ignore
EOF
chmod 0600 /etc/NetworkManager/system-connections/libertix-development-static.nmconnection

install -d -m 0755 /etc/libertix
printf '%s\n' "$USERNAME" > /etc/libertix/development-ssh-user
chmod 0600 /etc/libertix/development-ssh-user
install -m 0755 /tmp/libertix-development-ssh-first-boot.sh \
    /usr/local/sbin/libertix-development-ssh-first-boot
install -m 0644 /tmp/libertix-development-ssh.service \
    /etc/systemd/system/libertix-development-ssh.service
systemctl enable libertix-development-ssh.service
