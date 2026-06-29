# vibemaxx-host

One-line installer for the **VibeMaxx host daemon** — run your agent/terminal sessions on an
always-on VPS so they survive your local machine sleeping or shutting off. Your VibeMaxx desktop
app connects to the host over WebSocket ("Connected mode").

This repo contains **only the installer**. The daemon ships as a self-contained **release
tarball** (the built daemon + its native modules + a bundled Node runtime) attached to this
repo's [Releases](https://github.com/elliotskise/vibemaxx-host/releases). The installer downloads
it and wires up a hardened systemd service — your server **never runs npm and never compiles
anything**.

## Install

On a fresh **Debian/Ubuntu** VPS, as root:

```bash
# RECOMMENDED — private + encrypted via Tailscale (no public exposure, works from anywhere):
curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh | sudo bash -s -- --tailscale

# Loopback only — reach it over an SSH tunnel:
curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh | sudo bash

# Public, with automatic TLS — point your domain's DNS at this box FIRST:
curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh \
  | sudo bash -s -- --domain host.example.com
```

Prefer to read it before running? Download, then run:

```bash
curl -fsSLO https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh
sudo bash install.sh
```

The script prints the **connect URL + token** at the end. Paste them into the desktop app under
**Settings → Connections → Host connection**.

### Connecting over Tailscale (recommended)

[Tailscale](https://tailscale.com) is a WireGuard-based mesh VPN: it links your laptop/phone and
this VPS into one private, encrypted network **over the public internet** — they do **not** need
to be on the same physical network. With `--tailscale`, the daemon binds **only** to the VPS's
tailnet address, so it's never exposed to the internet; only your own devices can reach it.

1. The installer sets up Tailscale on the VPS. Without `--tailscale-authkey` it prints a login URL
   — open it once to authorize the box. For unattended installs, pass an
   [auth key](https://login.tailscale.com/admin/settings/keys): `--tailscale-authkey tskey-...`.
2. On the machine you'll connect **from**, install Tailscale and sign into the **same** account:
   <https://tailscale.com/download>.
3. In the app → **Settings → Connections**, use the printed URL
   (`ws://<vps>.<your-tailnet>.ts.net:8765`) + token. Traffic is WireGuard-encrypted; no ports are
   public.

### If you went loopback-only

Open an SSH tunnel from your laptop, then connect the app to the local end:

```bash
ssh -N -L 8765:127.0.0.1:8765 <user>@<your-vps>
# app → URL: ws://127.0.0.1:8765   Token: (printed by the installer)
```

## What it does

1. Installs prerequisites (`curl`, `tar`, `git`, `ca-certificates`) — **no compiler, no npm**.
2. Downloads `vibemaxx-host-<arch>.tar.gz` for your CPU from this repo's Releases and verifies
   its checksum.
3. Extracts it to `/opt/vibemaxx-host` (the previous release is kept at `/opt/vibemaxx-host.old`
   for rollback).
4. Creates a dedicated **non-root** `vibemaxx` user and a `~/projects` working dir.
5. Generates a bearer token into `/etc/vibemaxx/host.env` (mode 0600), reused on re-runs.
6. Installs a **hardened** systemd unit (loopback-bound, `ProtectSystem=strict`,
   `ProtectHome=read-only`, `NoNewPrivileges`) and starts it.
7. With `--domain`, installs Caddy for automatic-TLS `wss://`.

It is **idempotent** — re-run it to update to the latest release; the token and data are preserved.

> **Supported architectures:** `linux-x64` (almost every VPS) and `linux-arm64`. The release
> bundles its own Node runtime, so there is no system-Node version to match.

## Options

| Flag | Description |
| --- | --- |
| `--tailscale` | Install Tailscale + bind the daemon to your private tailnet (no public exposure). |
| `--tailscale-authkey <k>` | Tailscale auth key (`tskey-...`) for non-interactive setup. |
| `--tailscale-hostname <n>` | Tailnet hostname for this VPS (default: the machine's hostname). |
| `--domain <host>` | Domain pointed at this VPS; installs Caddy for automatic-TLS `wss://`. |
| `--github-token <tok>` | GitHub token for authenticated git push/pull from the host. |
| `--token <tok>` | Use this bearer token instead of generating one. |
| `--port <n>` | Loopback port (default `8765`). |
| `--user <name>` | Service user (default `vibemaxx`). |
| `--version <tag>` | Release tag to install (default `latest`). |
| `--uninstall` | Stop + remove the service (user-data kept). |
| `--purge` | With `--uninstall`, also delete the data dir + env file. |

## Operate

```bash
journalctl -u vibemaxx-host -f      # live logs
systemctl status vibemaxx-host      # is it up?
systemctl restart vibemaxx-host     # restart
curl http://127.0.0.1:8765/healthz  # -> ok
```

## Security — read before exposing publicly

The daemon can **spawn arbitrary processes and read/write files** as the `vibemaxx` user — a
leaked token is a shell on your VPS. Treat the token like an SSH key. Never expose plaintext
`ws://` to the internet: use the SSH tunnel or the `--domain` TLS path. The service runs non-root
with systemd hardening, but that is *containment*, not a sandbox; ideally run it on a box with
limited egress.

## License

MIT — see [LICENSE](LICENSE).
