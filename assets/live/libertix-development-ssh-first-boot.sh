#!/bin/bash
set -Eeuo pipefail

marker=/var/lib/libertix/development-ssh-ready
username_file=/etc/libertix/development-ssh-user

[ ! -e "$marker" ] || exit 0
[ -s "$username_file" ]
username="$(cat "$username_file")"
[[ "$username" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
id "$username" >/dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive
apt-get -o Acquire::Retries=3 update
apt-get -o Acquire::Retries=3 install -y --no-install-recommends openssh-server

install -d -m 0755 /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/90-libertix-development.conf <<EOF
# This password-enabled endpoint exists only when Libertix is launched with
# --dev-ssh-static-ip. Production installations never create this file.
PasswordAuthentication yes
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $username
EOF

# The package can finish before systemd starts ssh.service and creates its
# RuntimeDirectory. sshd refuses even a configuration check without this path.
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t
systemctl enable ssh.service
systemctl restart ssh.service
install -d -m 0755 "$(dirname "$marker")"
touch "$marker"
