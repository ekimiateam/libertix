#!/bin/bash
set -Eeuo pipefail

marker=/var/lib/libertix/development-ssh-ready
username_file=/etc/libertix/development-ssh-user
sshd_policy=/etc/ssh/sshd_config.d/90-libertix-development.conf

[ ! -e "$marker" ] || exit 0
[ -s "$username_file" ]
username="$(cat "$username_file")"
[[ "$username" =~ ^[a-z][a-z0-9-]{0,31}$ ]]
id "$username" >/dev/null 2>&1

export DEBIAN_FRONTEND=noninteractive

install_openssh_server() {
    local attempt max_attempts=6 retry_delay_seconds

    command -v sshd >/dev/null 2>&1 && return 0

    # Acquire::Retries covers transport failures inside one apt invocation, but
    # it does not restart an update rejected because repository metadata and a
    # package index came from different mirror generations. Repeating the full
    # update with HTTP caches disabled lets a synchronizing mirror converge.
    for attempt in $(seq 1 "$max_attempts"); do
        if apt-get \
            -o Acquire::Retries=3 \
            -o Acquire::http::No-Cache=true \
            -o Acquire::https::No-Cache=true \
            update \
            && apt-get \
                -o Acquire::Retries=3 \
                -o Acquire::http::No-Cache=true \
                -o Acquire::https::No-Cache=true \
                install -y --no-install-recommends openssh-server; then
            return 0
        fi

        [ "$attempt" -lt "$max_attempts" ] || break
        retry_delay_seconds=$((attempt * 10))
        echo "OpenSSH installation attempt $attempt failed; retrying in ${retry_delay_seconds}s." >&2
        sleep "$retry_delay_seconds"
    done

    echo "OpenSSH installation failed after $max_attempts attempts." >&2
    return 1
}

install_openssh_server

[ -s "$sshd_policy" ]
grep -Fx "AllowUsers $username" "$sshd_policy" >/dev/null

# The package can finish before systemd starts ssh.service and creates its
# RuntimeDirectory. sshd refuses even a configuration check without this path.
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t
systemctl enable ssh.service
systemctl restart ssh.service
install -d -m 0755 "$(dirname "$marker")"
touch "$marker"
