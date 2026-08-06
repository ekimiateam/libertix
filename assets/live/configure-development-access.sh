#!/bin/bash
set -Eeuo pipefail

[ "${DEVELOPMENT_SSH_ENABLED:-false}" = "true" ] || exit 0

[ -n "$DEVELOPMENT_STATIC_IPV4_ADDRESS" ]
[ -n "$DEVELOPMENT_STATIC_IPV4_PREFIX_LENGTH" ]
[ -n "$DEVELOPMENT_STATIC_IPV4_GATEWAY" ]
[ -n "$DEVELOPMENT_DNS_SERVERS" ]
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
dns=$DEVELOPMENT_DNS_SERVERS;
dns-priority=-100
never-default=false

[ipv6]
method=ignore
EOF
chmod 0600 /etc/NetworkManager/system-connections/libertix-development-static.nmconnection

install -d -m 0755 /etc/libertix
printf '%s\n' "$USERNAME" > /etc/libertix/development-ssh-user
chmod 0600 /etc/libertix/development-ssh-user

# Install the restrictive development policy before the first boot. Some base
# images already contain a running SSH server, so deferring this file until the
# first-boot service would briefly expose the account without AllowUsers and
# PermitRootLogin restrictions.
install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/90-libertix-development.conf <<EOF
# This password-enabled endpoint exists only when Libertix is launched with
# --dev-ssh-static-ip. Production installations never create this file.
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $USERNAME
EOF
chmod 0644 /etc/ssh/sshd_config.d/90-libertix-development.conf

install -m 0755 /tmp/libertix-development-ssh-first-boot.sh \
    /usr/local/sbin/libertix-development-ssh-first-boot
install -m 0644 /tmp/libertix-development-ssh.service \
    /etc/systemd/system/libertix-development-ssh.service
systemctl enable libertix-development-ssh.service
