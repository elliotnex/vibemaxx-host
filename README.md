# vibemaxx-host

One-line installer for the **VibeMaxx host daemon** — run your agent/terminal sessions on an
always-on box (a Linux VPS, or a Windows machine) so they survive your local machine sleeping
or shutting off. Your VibeMaxx desktop app connects to the host over WebSocket ("Connected
mode").

This repo contains **only the installers**. The daemon ships as a self-contained **release
artifact** (the built daemon + its native modules + a bundled Node runtime) attached to this
repo's [Releases](https://github.com/elliotnex/vibemaxx-host/releases) — a tarball for Linux,
a zip for Windows. The installer downloads it and wires up a service (systemd on Linux, a
WinSW Windows service on Windows) — your server **runs no compiler and no npm**, unless you
opt to install agent CLIs (see [Installing agents](#installing-agents-on-the-host)).

Already installed and hitting permission errors inside sessions? See
[Agent access on the box](#agent-access-on-the-box) — one script unlocks an existing install.

## Install

On a fresh **Debian/Ubuntu** VPS, as root:

```bash
# RECOMMENDED — private + encrypted via Tailscale (no public exposure, works from anywhere):
curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh | sudo bash -s -- --tailscale

# Loopback only — reach it over an SSH tunnel:
curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh | sudo bash

# Public, with automatic TLS — point your domain's DNS at this box FIRST:
curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh \
  | sudo bash -s -- --domain host.example.com
```

Prefer to read it before running? Download, then run:

```bash
curl -fsSLO https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh
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

## Install on Windows

The daemon also runs on a Windows box — **64-bit Windows 10 1809 / Windows Server 2019 or
newer** (any edition, Home included). From an **elevated** PowerShell:

```powershell
# RECOMMENDED — private + encrypted via Tailscale (install Tailscale + sign in on the box first):
iex "& { $(irm https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.ps1) } -Tailscale"

# Loopback only — reach it from this machine or an SSH tunnel:
irm https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.ps1 | iex
```

Prefer to read it before running? Download, then run:

```powershell
irm https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.ps1 -OutFile install.ps1
powershell -ExecutionPolicy Bypass -File .\install.ps1 -Tailscale
```

It downloads `vibemaxx-host-win-x64.zip` from Releases (checksum-verified), extracts it to
`C:\VibeMaxx\Host`, and installs a `vibemaxx-host` Windows service (WinSW, hash-pinned) with
restart-on-crash and rolling logs. Like the Linux install, the zip bundles its own Node
runtime — no system Node, npm, or compiler is needed.

Windows-specific behavior worth knowing:

- **The service runs as your user account** (default). You're asked for your Windows password
  once at first install — Windows' service manager stores it; the installer never writes it to
  disk. This is what lets agent CLIs and their sign-ins under your profile work unchanged.
  `-ServiceAccount LocalSystem` avoids the prompt, but agents then run as SYSTEM with an empty
  profile and every agent needs re-authenticating.
- **Agents install the normal Windows way** — `npm install -g @anthropic-ai/claude-code` in any
  terminal, or the desktop app's in-app **Install** button (in Connected mode the app resolves
  the Windows install command for the host and runs it there).
- **Keep the box awake.** Windows sleeps by default, which suspends every hosted session:
  `powercfg /change standby-timeout-ac 0`.
- The bearer token lives in the service config under `C:\VibeMaxx\Host\svc`, ACL-restricted to
  Administrators/SYSTEM/the service account (the chmod-600 analog).
- Manage with `Start-Service` / `Stop-Service` / `Restart-Service vibemaxx-host`; logs land in
  `C:\VibeMaxx\Host\logs`; device tokens via `C:\VibeMaxx\Host\vibemaxx-host.cmd tokens add
  "Elliot's iPhone"`.
- Update by re-running the installer (token, service registration, and data are kept).
  Uninstall with `-Uninstall` (add `-Purge` to also delete the install dir and data).
- Options mirror the Linux flags where they apply: `-Tailscale`, `-Bind`, `-Port`, `-Token`,
  `-GitHubToken`, `-Version <tag>`, `-NoService`, `-NoFirewall`. With `-Tailscale`, the
  firewall rule is scoped to the tailnet (100.64.0.0/10) and the service waits for Tailscale
  at boot.

## Installing agents on the host

Agent sessions run on the **VPS**, so the agent CLIs must be installed there — and with the
right Linux installer, regardless of whether your laptop runs Windows, macOS, or Linux. The
desktop app's "Agents" tab is keyed to *your* machine's OS, so a Windows client would otherwise
hand you a PowerShell `irm …` one-liner that can't run on the Linux box. Two ways to install:

```bash
# 1. With a fresh install (or alongside --tailscale):
curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh \
  | sudo bash -s -- --tailscale --install-agent claude-code --install-agent codex

# 2. Against an existing install — just adds the agents, no re-download, no restart:
sudo bash install.sh --install-agent grok --agent-npm @some/cli
```

The installer gives the `vibemaxx` user its own writable npm prefix (`~/.npm-global`) and puts it
on the daemon's `PATH`, so agents install without root and resolve in new sessions automatically.
npm itself (Node 20) is pulled in **on demand** only when you ask for an agent — the base install
stays compiler/npm-free. Once an agent is installed, the desktop app's in-app **Install** button
also works (in Connected mode it runs the Linux installer on the host).

## What it does

1. Installs prerequisites (`curl`, `tar`, `git`, `ca-certificates`) — **no compiler, no npm**.
2. Downloads `vibemaxx-host-<arch>.tar.gz` for your CPU from this repo's Releases and verifies
   its checksum.
3. Extracts it to `/opt/vibemaxx-host` (the previous release is kept at `/opt/vibemaxx-host.old`
   for rollback).
4. Creates a dedicated **non-root** `vibemaxx` user and a `~/projects` working dir.
5. Generates a bearer token into `/etc/vibemaxx/host.env` (mode 0600), reused on re-runs.
6. Prepares a writable npm prefix (`~/.npm-global`) + agent dirs for the `vibemaxx` user so
   agent CLIs can be installed without root.
7. Installs the systemd unit and starts it.
8. Gives agent sessions **full access on the box** (see below): no systemd sandboxing on the
   daemon, passwordless `sudo` for the `vibemaxx` user, and Codex's own sandbox turned off.
9. With `--install-agent` (etc.), installs the requested agent CLIs; with `--domain`, installs
   Caddy for automatic-TLS `wss://`.

It is **idempotent** — re-run it to update to the latest release; the token and data are preserved.

> **Supported platforms:** `linux-x64` (almost every VPS), `linux-arm64`, and `win-x64`
> (Windows 10 1809 / Server 2019+, via [install.ps1](#install-on-windows)). The release
> bundles its own Node runtime, so there is no system-Node version to match.

## Options

| Flag | Description |
| --- | --- |
| `--tailscale` | Install Tailscale + bind the daemon to your private tailnet (no public exposure). |
| `--tailscale-authkey <k>` | Tailscale auth key (`tskey-...`) for non-interactive setup. |
| `--tailscale-hostname <n>` | Tailnet hostname for this VPS (default: the machine's hostname). |
| `--domain <host>` | Domain pointed at this VPS; installs Caddy for automatic-TLS `wss://`. |
| `--install-agent <name>` | Install an agent CLI: `codex`, `claude-code`, `grok`, `antigravity`, `opencode`, `cursor`. Repeatable. |
| `--agent-npm <package>` | Install an arbitrary npm global package as an agent. Repeatable. |
| `--agent-sh <command>` | Install via an arbitrary shell one-liner (run as the `vibemaxx` user). Repeatable. |
| `--github-token <tok>` | GitHub token for authenticated git push/pull from the host. |
| `--token <tok>` | Use this bearer token instead of generating one. |
| `--port <n>` | Loopback port (default `8765`). |
| `--user <name>` | Service user (default `vibemaxx`). |
| `--no-agent-sudo` | Don't grant the service user passwordless `sudo`. Agents keep full rights as that user but can't `apt install` or write outside `$HOME`. |
| `--harden` | Contain the daemon with systemd sandboxing (`NoNewPrivileges`, `ProtectSystem=strict`, `ProtectHome`, `PrivateTmp`) and skip the sudo grant. Agents inherit it — expect permission errors in sessions. |
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

## Agent access on the box

**Agent sessions are children of the daemon**, so anything that confines the *service* confines
every *agent* — that is where "permission denied" inside a session comes from. Two layers:

- **systemd.** `NoNewPrivileges=true` makes `sudo` fail with *"the 'no new privileges' flag is
  set, which prevents sudo from running as root"* (no sudoers entry can override it);
  `ProtectSystem=strict` makes everything outside `ReadWritePaths` read-only (`EROFS` on `/etc`,
  `/usr/local`, `/srv`, and repos checked out off `$HOME`); `PrivateTmp` hides the agent's `/tmp`
  from your own SSH session.
- **The agent CLI itself.** Codex on Linux defaults to `sandbox_mode = "workspace-write"` — a
  Landlock + seccomp jail that confines writes to the session cwd and blocks network egress,
  independent of systemd.

Running agents is the point of this daemon, so the installer's default is **unconfined**: a unit
with no sandbox directives, `/etc/sudoers.d/vibemaxx-agents` (`NOPASSWD: ALL`), a real login shell
plus `docker` group membership for the service user, and `~/.codex/config.toml` set to
`sandbox_mode = "danger-full-access"`. Containment lives at the account and network level instead:
a dedicated non-root user, a private bind, and a bearer token.

Use `--no-agent-sudo` to keep agents at that user's own rights, or `--harden` to trade capability
for systemd containment.

**Already installed?** Installs from before this was the default leave agents confined. Unlock one
in place — no re-download, and the systemd drop-in it writes survives future `install.sh` runs:

```bash
curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/full-access.sh | sudo bash

# or, after downloading it:
sudo bash full-access.sh              # unlock (restarts the daemon — live sessions end)
sudo bash full-access.sh --no-restart # stage it; applies on the next restart
sudo bash full-access.sh --revert     # put the containment back
```

## Security — read before exposing publicly

The daemon can **spawn arbitrary processes and read/write files** as the `vibemaxx` user, and by
default that user can `sudo` — so a leaked token is **root on your VPS**. Treat the token like an
SSH key. Never expose plaintext `ws://` to the internet: use `--tailscale`, an SSH tunnel, or the
`--domain` TLS path. Run it on a box dedicated to this and treat the whole box as the sandbox; if
the box is shared with anything else, install with `--no-agent-sudo` or `--harden`.

## License

MIT — see [LICENSE](LICENSE).
