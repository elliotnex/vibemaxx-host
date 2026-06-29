#!/usr/bin/env bash
#
# VibeMaxx host — one-line VPS installer (vendored release, no npm on your server).
#
# Installs the always-on `vibemaxx-host` daemon (agent/terminal sessions over WebSocket) on a
# Debian/Ubuntu box, as a hardened non-root systemd service. Your VibeMaxx desktop app then
# connects to it so sessions survive your local machine sleeping/shutting off.
#
# It downloads a self-contained release tarball (the daemon + its native modules, and a bundled
# Node runtime) from this repo's GitHub Releases — so the server never compiles anything and
# never talks to the npm registry.
#
# Private, encrypted access via Tailscale (RECOMMENDED — no public exposure, works from anywhere):
#   curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh | sudo bash -s -- --tailscale
#   (add --tailscale-authkey tskey-... for fully non-interactive setup)
#
# Loopback only — reach it over an SSH tunnel:
#   curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh | sudo bash
#
# Or download first, read it, then run:
#   curl -fsSLO https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh
#   sudo bash install.sh
#
# Public, with automatic-TLS wss:// (point the domain's DNS at this box FIRST):
#   curl -fsSL https://raw.githubusercontent.com/elliotskise/vibemaxx-host/main/install.sh \
#     | sudo bash -s -- --domain host.example.com
#
# Idempotent: re-run to update to the latest release (token + data are preserved).
# Uninstall:  sudo bash install.sh --uninstall
#
# Options (pass after `bash -s --`):
#   --tailscale              Install Tailscale + bind the daemon to your private tailnet (no public exposure).
#   --tailscale-authkey <k>  Tailscale auth key (tskey-...) for non-interactive setup.
#   --tailscale-hostname <n> Tailnet hostname for this VPS (default: the machine's hostname).
#   --domain <host>          Domain pointed at this VPS; installs Caddy for automatic-TLS wss://.
#   --github-token <tok>     GitHub token for authenticated git push/pull from the host (optional).
#   --token <tok>            Use this bearer token instead of generating one.
#   --port <n>               Port the daemon listens on (default 8765).
#   --user <name>            Service user (default vibemaxx).
#   --version <tag>          Release tag to install (default: latest).
#   --uninstall              Stop + remove the service (user-data kept).
#   --purge                  With --uninstall, also delete the data dir and env file.
#   -h, --help               Show this help.

set -euo pipefail

# --- constants ------------------------------------------------------------------------------
REPO_SLUG="elliotskise/vibemaxx-host"
INSTALL_DIR="/opt/vibemaxx-host"
SERVICE="vibemaxx-host"
ENV_DIR="/etc/vibemaxx"
ENV_FILE="${ENV_DIR}/host.env"

# --- defaults / flags -----------------------------------------------------------------------
DOMAIN=""
PORT="8765"
BIND="127.0.0.1"
TOKEN=""
GITHUB_TOKEN=""
APP_USER="vibemaxx"
VERSION="latest"
DO_UNINSTALL=0
DO_PURGE=0
USE_TAILSCALE=0
TS_AUTHKEY=""
TS_HOSTNAME=""

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mx  %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tailscale)           USE_TAILSCALE=1; shift ;;
    --tailscale-authkey)   TS_AUTHKEY="${2:-}"; shift 2 ;;
    --tailscale-hostname)  TS_HOSTNAME="${2:-}"; shift 2 ;;
    --domain)              DOMAIN="${2:-}"; shift 2 ;;
    --github-token)        GITHUB_TOKEN="${2:-}"; shift 2 ;;
    --token)               TOKEN="${2:-}"; shift 2 ;;
    --port)                PORT="${2:-}"; shift 2 ;;
    --user)                APP_USER="${2:-}"; shift 2 ;;
    --version)             VERSION="${2:-}"; shift 2 ;;
    --uninstall)           DO_UNINSTALL=1; shift ;;
    --purge)               DO_PURGE=1; shift ;;
    -h|--help)             grep -E '^#( |$)' "$0" 2>/dev/null | sed 's/^#\s\{0,1\}//'; exit 0 ;;
    *)                     die "Unknown option: $1 (try --help)" ;;
  esac
done

APP_HOME="/home/${APP_USER}"
DATA_DIR="${APP_HOME}/.vibemaxx-host"
PROJECTS_DIR="${APP_HOME}/projects"

[ "$(id -u)" -eq 0 ] || die "Run as root:  curl -fsSL <url> | sudo bash"
command -v apt-get >/dev/null || die "This installer targets Debian/Ubuntu (apt-get not found)."

# --- uninstall path -------------------------------------------------------------------------
if [ "${DO_UNINSTALL}" -eq 1 ]; then
  say "Removing the ${SERVICE} service"
  systemctl disable --now "${SERVICE}" 2>/dev/null || true
  rm -f "/etc/systemd/system/${SERVICE}.service"
  systemctl daemon-reload 2>/dev/null || true
  rm -rf "${INSTALL_DIR}" "${INSTALL_DIR}.old"
  if [ "${DO_PURGE}" -eq 1 ]; then
    warn "Purging data dir ${DATA_DIR} and ${ENV_FILE}"
    rm -rf "${DATA_DIR}" "${ENV_FILE}"
  else
    printf '   Kept user-data: %s  (and %s). Re-run with --purge to delete.\n' "${DATA_DIR}" "${ENV_FILE}"
  fi
  ok "Uninstalled."
  exit 0
fi

# --- 1. minimal system packages (no compiler — the release is vendored) ---------------------
say "Installing prerequisites (curl, tar, git, ca-certificates)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ca-certificates curl tar git openssl

# --- 2. resolve the release asset for this architecture -------------------------------------
case "$(uname -m)" in
  x86_64|amd64)   PLATFORM="linux-x64" ;;
  aarch64|arm64)  PLATFORM="linux-arm64" ;;
  *)              die "Unsupported CPU architecture: $(uname -m). Open an issue for a build." ;;
esac
ASSET="vibemaxx-host-${PLATFORM}.tar.gz"
# VIBEMAXX_RELEASE_BASE_URL overrides where the tarball is fetched from (a mirror, an internal
# artifact store, a file:// path for air-gapped/offline installs, or local testing).
if [ -n "${VIBEMAXX_RELEASE_BASE_URL:-}" ]; then
  BASE_URL="${VIBEMAXX_RELEASE_BASE_URL%/}"
elif [ "${VERSION}" = "latest" ]; then
  BASE_URL="https://github.com/${REPO_SLUG}/releases/latest/download"
else
  BASE_URL="https://github.com/${REPO_SLUG}/releases/download/${VERSION}"
fi

# --- 3. download + verify + extract to a staging dir ----------------------------------------
mkdir -p /opt
TMP="$(mktemp -d)"
STAGING="$(mktemp -d "/opt/.vibemaxx-host.XXXXXX")"
cleanup() { rm -rf "${TMP}" "${STAGING}" 2>/dev/null || true; }
trap cleanup EXIT

say "Downloading ${ASSET} (${VERSION})"
curl -fSL --retry 3 --retry-delay 2 -o "${TMP}/${ASSET}" "${BASE_URL}/${ASSET}" \
  || die "Could not download ${BASE_URL}/${ASSET} — is the release published for ${PLATFORM}?"

# Best-effort integrity check if a checksum asset is published alongside.
if curl -fSL --retry 2 -o "${TMP}/${ASSET}.sha256" "${BASE_URL}/${ASSET}.sha256" 2>/dev/null; then
  say "Verifying checksum"
  EXPECTED="$(awk '{print $1}' "${TMP}/${ASSET}.sha256")"
  ACTUAL="$(sha256sum "${TMP}/${ASSET}" | awk '{print $1}')"
  [ "${EXPECTED}" = "${ACTUAL}" ] || die "Checksum mismatch — refusing to install. expected ${EXPECTED}, got ${ACTUAL}"
  ok "Checksum verified"
else
  warn "No checksum published for this release — skipping integrity check."
fi

say "Extracting"
tar -xzf "${TMP}/${ASSET}" -C "${STAGING}"
[ -f "${STAGING}/host-dist/host/index.js" ] \
  || die "Release tarball is missing host-dist/host/index.js (unexpected layout)."

# --- 4. resolve the Node runtime: bundled (preferred) or pinned system Node 20 ---------------
if [ -x "${STAGING}/node/bin/node" ]; then
  NODE_BIN="${INSTALL_DIR}/node/bin/node"   # path AFTER the swap below
  say "Using the Node runtime bundled in the release"
else
  # Fallback: the release didn't bundle Node. The vendored native modules are ABI-locked to
  # Node 20, so ensure the system Node is v20 (installing it if absent or a different major).
  NODE_MAJOR="$(command -v node >/dev/null && node -p 'process.versions.node.split(".")[0]' || echo 0)"
  if [ "${NODE_MAJOR}" != "20" ]; then
    say "Installing Node.js 20 LTS (required to match the release's native modules)"
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
  else
    say "Node.js $(node -v) already present"
  fi
  NODE_BIN="$(command -v node)"
fi

# --- 5. swap the new release into place (keep one backup for rollback) -----------------------
say "Installing to ${INSTALL_DIR}"
systemctl stop "${SERVICE}" 2>/dev/null || true
rm -rf "${INSTALL_DIR}.old"
[ -d "${INSTALL_DIR}" ] && mv "${INSTALL_DIR}" "${INSTALL_DIR}.old"
mv "${STAGING}" "${INSTALL_DIR}"
trap 'rm -rf "${TMP}" 2>/dev/null || true' EXIT   # STAGING is now INSTALL_DIR; don't delete it
chown -R root:root "${INSTALL_DIR}"
# mktemp -d makes the staging dir 0700; the non-root service user must be able to read +
# traverse the install tree and execute the bundled node. a+rX = read for files, traverse
# for dirs, and execute for anything already executable (the node binary, spawn-helper).
chmod -R a+rX "${INSTALL_DIR}"
# node-pty's spawn-helper / the bundled node must stay executable.
find "${INSTALL_DIR}" -name spawn-helper -exec chmod +x {} \; 2>/dev/null || true
[ -x "${INSTALL_DIR}/node/bin/node" ] || chmod +x "${INSTALL_DIR}/node/bin/node" 2>/dev/null || true

DAEMON_MAIN="${INSTALL_DIR}/host-dist/host/index.js"

# --- 6. service user + dirs -----------------------------------------------------------------
if id -u "${APP_USER}" >/dev/null 2>&1; then
  say "User ${APP_USER} already exists"
else
  say "Creating non-root user ${APP_USER}"
  useradd --system --create-home --home-dir "${APP_HOME}" --shell /usr/sbin/nologin "${APP_USER}"
fi
install -d -o "${APP_USER}" -g "${APP_USER}" "${DATA_DIR}" "${PROJECTS_DIR}"

# --- 6b. Tailscale: private, encrypted access with no public exposure (recommended) ---------
TS_UNIT_AFTER=""
TS_UNIT_WANTS=""
TS_HOST=""
TS_IP=""
if [ "${USE_TAILSCALE}" -eq 1 ]; then
  if [ -n "${DOMAIN}" ]; then
    warn "--tailscale and --domain are mutually exclusive (Tailscale keeps the daemon private; Caddy makes it public). Using Tailscale; ignoring --domain."
    DOMAIN=""
  fi
  say "Setting up Tailscale"
  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://tailscale.com/install.sh | sh
  fi
  if ! tailscale ip -4 >/dev/null 2>&1; then
    UP_ARGS=""
    [ -n "${TS_HOSTNAME}" ] && UP_ARGS="--hostname=${TS_HOSTNAME}"
    if [ -n "${TS_AUTHKEY}" ]; then
      tailscale up --authkey "${TS_AUTHKEY}" ${UP_ARGS} || die "tailscale up failed (check the auth key)."
    else
      warn "Tailscale must authenticate this VPS. Open the login URL printed below in a browser to authorize it; setup continues automatically once you do."
      tailscale up ${UP_ARGS} || die "tailscale up failed / was not authorized."
    fi
  else
    say "Tailscale is already up"
  fi
  TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"
  [ -n "${TS_IP}" ] || die "Could not determine this VPS's Tailscale IP (is 'tailscale up' authorized?)."
  # MagicDNS name for a friendlier connect URL (falls back to the tailnet IP).
  TS_HOST="$(tailscale status --json 2>/dev/null \
    | grep -oE '"DNSName"[[:space:]]*:[[:space:]]*"[^"]+"' | head -n1 \
    | sed -E 's/.*:[[:space:]]*"([^"]+)".*/\1/' | sed 's/\.$//')"
  [ -n "${TS_HOST}" ] || TS_HOST="${TS_IP}"
  # Bind the daemon ONLY to the tailnet interface — never the public internet. Tailscale
  # WireGuard-encrypts the traffic, and only devices on your tailnet can even reach it.
  BIND="${TS_IP}"
  TS_UNIT_AFTER=" tailscaled.service"
  TS_UNIT_WANTS="Wants=tailscaled.service"
  ok "Tailscale up — this VPS is ${TS_HOST} (${TS_IP}) on your tailnet"
fi

# --- 7. token + env file --------------------------------------------------------------------
install -d -m 750 "${ENV_DIR}"
if [ -z "${TOKEN}" ] && [ -f "${ENV_FILE}" ]; then
  TOKEN="$(grep -E '^VIBEMAXX_HOST_TOKEN=' "${ENV_FILE}" | head -n1 | cut -d= -f2- || true)"
  [ -n "${TOKEN}" ] && say "Reusing existing token from ${ENV_FILE}"
fi
[ -n "${TOKEN}" ] || { say "Generating a bearer token"; TOKEN="$(openssl rand -hex 32)"; }

say "Writing ${ENV_FILE}"
{
  echo "VIBEMAXX_HOST_TOKEN=${TOKEN}"
  echo "VIBEMAXX_HOST_BIND=${BIND}"
  echo "VIBEMAXX_HOST_PORT=${PORT}"
  echo "VIBEMAXX_HOST_DATA_DIR=${DATA_DIR}"
  [ -n "${GITHUB_TOKEN}" ] && echo "VIBEMAXX_HOST_GITHUB_TOKEN=${GITHUB_TOKEN}"
} > "${ENV_FILE}"
chmod 600 "${ENV_FILE}"

# --- 8. systemd unit ------------------------------------------------------------------------
say "Installing systemd service ${SERVICE}"
cat > "/etc/systemd/system/${SERVICE}.service" <<UNIT
[Unit]
Description=VibeMaxx host daemon (agent sessions over WebSocket)
After=network.target${TS_UNIT_AFTER}
${TS_UNIT_WANTS}

[Service]
Type=simple
User=${APP_USER}
WorkingDirectory=${PROJECTS_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=${NODE_BIN} ${DAEMON_MAIN}
Restart=always
RestartSec=2

# Hardening — the daemon can spawn arbitrary processes, so contain it.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${DATA_DIR} ${PROJECTS_DIR}

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "${SERVICE}" >/dev/null
systemctl restart "${SERVICE}"

# --- 9. connect URL + optional Caddy (public TLS) -------------------------------------------
if [ "${USE_TAILSCALE}" -eq 1 ]; then
  PUBLIC_URL="ws://${TS_HOST}:${PORT}"
else
  PUBLIC_URL="ws://${BIND}:${PORT}"
fi
if [ -n "${DOMAIN}" ]; then
  if ! command -v caddy >/dev/null; then
    say "Installing Caddy"
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
      | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
      > /etc/apt/sources.list.d/caddy-stable.list
    apt-get update -y
    apt-get install -y caddy
  fi
  say "Configuring Caddy for ${DOMAIN}"
  cat > /etc/caddy/Caddyfile <<CADDY
${DOMAIN} {
	reverse_proxy ${BIND}:${PORT}
}
CADDY
  systemctl reload caddy || systemctl restart caddy
  if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
    ufw allow 80,443/tcp >/dev/null || true
  fi
  PUBLIC_URL="wss://${DOMAIN}"
fi

# --- summary --------------------------------------------------------------------------------
sleep 1
STATUS="$(systemctl is-active "${SERVICE}" || true)"
HEALTH="$(curl -fsS "http://${BIND}:${PORT}/healthz" 2>/dev/null || echo 'unreachable')"

cat <<SUMMARY

$(ok "VibeMaxx host is set up.")

  Service     : ${SERVICE} (${STATUS})
  Health      : http://${BIND}:${PORT}/healthz -> ${HEALTH}
  Installed   : ${INSTALL_DIR}   (release ${VERSION}, ${PLATFORM})
  Projects    : ${PROJECTS_DIR}   (clone repos here; agents can read/write here)

  Connect from the desktop app  (Settings → Connections → Host connection):
    URL   : ${PUBLIC_URL}
    Token : ${TOKEN}

SUMMARY

if [ "${USE_TAILSCALE}" -eq 1 ]; then
  cat <<NOTE
$(ok "Private access via Tailscale — the daemon listens only on your tailnet (${TS_IP}), never the public internet.")
   On the machine you'll connect FROM (laptop, later your phone):
     1. Install Tailscale:  https://tailscale.com/download
     2. Sign in to the SAME Tailscale account / tailnet as this VPS.
     3. App → Settings → Connections → use the URL + token above.
   Traffic is WireGuard-encrypted end-to-end; no ports are exposed to the internet.

NOTE
elif [ -z "${DOMAIN}" ]; then
  cat <<NOTE
$(warn "Loopback-only (no TLS, not reachable from the internet). For the easiest secure setup, re-run with --tailscale.")
   Otherwise reach it by either:
     - an SSH tunnel from your laptop:
         ssh -N -L ${PORT}:127.0.0.1:${PORT} <user>@<this-vps>
       then connect the app to  ws://127.0.0.1:${PORT}
     - or re-run with --domain your.domain  for automatic-TLS wss://.

NOTE
fi

cat <<TIPS
  Logs    : journalctl -u ${SERVICE} -f
  Status  : systemctl status ${SERVICE}
  Update  : re-run this installer (token + data preserved; previous release kept at ${INSTALL_DIR}.old)
  Remove  : sudo bash install.sh --uninstall

TIPS
