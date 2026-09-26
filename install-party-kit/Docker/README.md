# Linux / Docker

From the repository root:

```sh
docker compose -f install-party-kit/Docker/compose.yaml up --build -d
docker compose -f install-party-kit/Docker/compose.yaml logs
```

Open **https://127.0.0.1:18080/** on this Linux host. Accept the expected self-signed-certificate
browser warning. Progress is on that page, not in the container console.

The Compose file uses Linux host networking so UDP broadcast and IP enumeration see the real LAN.
Do not replace it with a bridge plus an HTTPS port mapping: that does not preserve UDP discovery.
Docker Desktop networking is not covered; use the native Windows package there.

The named volume retains settings, private TLS key and artifacts across container replacement.
The image runs as the built-in unprivileged .NET application account. If replacing the named volume
with a host directory, make it writable by that account (UID 1654 in the official image), not by every
LAN user. Keep managed storage under `/data` unless another persistent volume is configured.

Allow LAN inbound UDP 18081 and TCP 18080 (or the configured HTTPS port) in your host firewall.
Do not expose these ports to the Internet. The same HTTPS listener serves files to the LAN, but the
page and management APIs reject non-loopback clients. For a headless host, use an SSH local tunnel
to its loopback HTTPS port; do not expose the management page remotely.

After saving changed settings in the page, restart when clients have finished:

```sh
docker compose -f install-party-kit/Docker/compose.yaml restart
```

See [operation, trust and the separate folder-only mode](../README.md).
