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
#   curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh | sudo bash -s -- --tailscale
#   (add --tailscale-authkey tskey-... for fully non-interactive setup)
#
# Loopback only — reach it over an SSH tunnel:
#   curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh | sudo bash
#
# Or download first, read it, then run:
#   curl -fsSLO https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh
#   sudo bash install.sh
#
# Public, with automatic-TLS wss:// (point the domain's DNS at this box FIRST):
#   curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh \
#     | sudo bash -s -- --domain host.example.com
#
# Install agent CLIs on the box (Linux installers, regardless of YOUR machine's OS). Combine
# with a fresh install, or run against an existing one to just add agents (no re-download):
#   curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install.sh \
#     | sudo bash -s -- --tailscale --install-agent claude-code
#   sudo bash install.sh --install-agent codex --install-agent grok
#
# Idempotent: re-run to update to the latest release (token + data are preserved).
# Uninstall:  sudo bash install.sh --uninstall
#
# Options (pass after `bash -s --`):
#   --tailscale              Install Tailscale + bind the daemon to your private tailnet (no public exposure).
#   --tailscale-authkey <k>  Tailscale auth key (tskey-...) for non-interactive setup.
#   --tailscale-hostname <n> Tailnet hostname for this VPS (default: the machine's hostname).
#   --domain <host>          Domain pointed at this VPS; installs Caddy for automatic-TLS wss://.
#   --install-agent <name>   Install an agent CLI (codex, claude-code, grok, antigravity, opencode, cursor). Repeatable.
#   --agent-npm <package>    Install an arbitrary npm global package as an agent. Repeatable.
#   --agent-sh <command>     Install via an arbitrary shell one-liner (run as the service user). Repeatable.
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
REPO_SLUG="elliotnex/vibemaxx-host"
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
AGENTS=()
AGENT_NPM=()
AGENT_SH=()

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
    --install-agent)       AGENTS+=("${2:-}"); shift 2 ;;
    --agent-npm)           AGENT_NPM+=("${2:-}"); shift 2 ;;
    --agent-sh)            AGENT_SH+=("${2:-}"); shift 2 ;;
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
NPM_PREFIX="${APP_HOME}/.npm-global"
AGENT_BIN="${NPM_PREFIX}/bin"

[ "$(id -u)" -eq 0 ] || die "Run as root:  curl -fsSL <url> | sudo bash"
command -v apt-get >/dev/null || die "This installer targets Debian/Ubuntu (apt-get not found)."

# --- agent install helpers ------------------------------------------------------------------
# Agent CLIs (Linux installers) the desktop app offers, by key -> "binary|command". Mirrors
# the app's runtimePresets so --install-agent matches what the Agents tab shows. Shell installers
# are DOWNLOADED then run as a file (not `curl | bash`) so they aren't fed their own script on
# stdin; run_as_user runs them in a writable temp dir with /dev/null stdin.
agent_spec() {
  case "$1" in
    codex)                 echo "codex|npm install -g @openai/codex" ;;
    claude-code | claude)  echo "claude|npm install -g @anthropic-ai/claude-code" ;;
    grok | grok-build)     echo "grok|curl -fsSL https://x.ai/cli/install.sh -o vm-install.sh && bash vm-install.sh" ;;
    antigravity | agy)     echo "agy|curl -fsSL https://antigravity.google/cli/install.sh -o vm-install.sh && bash vm-install.sh" ;;
    opencode)              echo "opencode|curl -fsSL https://opencode.ai/install -o vm-install.sh && bash vm-install.sh" ;;
    cursor | cursor-agent) echo "cursor-agent|curl -fsSL https://cursor.com/install -o vm-install.sh && bash vm-install.sh" ;;
    *) return 1 ;;
  esac
}

# The vendored release bundles only the node BINARY (no npm), so install Node 20 + npm on
# demand — ONLY when agents are requested, keeping the base install compiler/npm-free.
ensure_npm() {
  command -v npm >/dev/null 2>&1 && return 0
  say "Installing Node.js 20 + npm (needed to install agent CLIs)"
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y nodejs
}

# Give the service user a writable npm prefix + agent dirs, on PATH for its login/interactive
# shells. The daemon gets the same via the unit's Environment=PATH below. ~/.npmrc is written
# directly (no npm binary needed) so `npm install -g` lands in the user's prefix.
setup_npm_env() {
  install -d -o "${APP_USER}" -g "${APP_USER}" \
    "${NPM_PREFIX}" "${AGENT_BIN}" "${APP_HOME}/.npm" \
    "${APP_HOME}/.config" "${APP_HOME}/.cache" "${APP_HOME}/.local" "${APP_HOME}/.local/bin"
  printf 'prefix=%s\n' "${NPM_PREFIX}" > "${APP_HOME}/.npmrc"
  chown "${APP_USER}:${APP_USER}" "${APP_HOME}/.npmrc"
  for rc in "${APP_HOME}/.profile" "${APP_HOME}/.bashrc"; do
    [ -f "${rc}" ] || { : > "${rc}"; chown "${APP_USER}:${APP_USER}" "${rc}"; }
    grep -q 'VIBEMAXX npm-global' "${rc}" 2>/dev/null || cat >> "${rc}" <<RC

# VIBEMAXX npm-global — agent CLIs install here without root.
export NPM_CONFIG_PREFIX="${NPM_PREFIX}"
export PATH="${AGENT_BIN}:${APP_HOME}/.local/bin:${INSTALL_DIR}/node/bin:\$PATH"
RC
  done
}

# Run a command AS the service user, from a FRESH writable temp dir, with stdin from /dev/null
# (nologin account -> runuser). Why the temp cwd + </dev/null: many vendor installers (a) write
# into the current directory — which the service user can't if cwd is /root or the install tree
# — and (b) misbehave when their stdin is a pipe (`curl | bash` leaves the script itself on
# stdin, so a prompt reads garbage). Running installers as downloaded FILES (see agent_spec) in
# a temp cwd with /dev/null stdin makes them behave non-interactively.
run_as_user() {
  local workdir status created=1
  workdir="$(runuser -u "${APP_USER}" -- mktemp -d 2>/dev/null || true)"
  [ -n "${workdir}" ] || { workdir="${APP_HOME}"; created=0; }
  runuser -u "${APP_USER}" -- env \
    HOME="${APP_HOME}" \
    NPM_CONFIG_PREFIX="${NPM_PREFIX}" \
    PATH="${AGENT_BIN}:${APP_HOME}/.local/bin:${INSTALL_DIR}/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    bash -lc "cd '${workdir}' && { $1; }" </dev/null && status=0 || status=$?
  [ "${created}" -eq 1 ] && runuser -u "${APP_USER}" -- rm -rf "${workdir}" 2>/dev/null || true
  return "${status}"
}

install_one_agent() {
  local binary="$1" cmd="$2" label="$3"
  say "Installing agent: ${label}"
  printf '   $ %s\n' "${cmd}"
  run_as_user "${cmd}" || die "Agent install failed for ${label}."
  if [ -n "${binary}" ]; then
    local resolved
    resolved="$(run_as_user "command -v ${binary} 2>/dev/null || true")"
    if [ -n "${resolved}" ]; then
      ok "${binary} -> ${resolved}"
    else
      warn "${label} installed but '${binary}' not on PATH yet — it resolves in new sessions."
    fi
  fi
}

# Install every requested agent (known names, raw npm packages, raw shell one-liners).
install_agents() {
  ensure_npm
  local key spec pkg cmd
  if [ "${#AGENTS[@]}" -gt 0 ]; then
    for key in "${AGENTS[@]}"; do
      spec="$(agent_spec "${key}")" \
        || die "Unknown agent '${key}'. Known: codex, claude-code, grok, antigravity, opencode, cursor. Or use --agent-npm / --agent-sh."
      install_one_agent "${spec%%|*}" "${spec#*|}" "${key}"
    done
  fi
  if [ "${#AGENT_NPM[@]}" -gt 0 ]; then
    for pkg in "${AGENT_NPM[@]}"; do
      install_one_agent "$(basename "${pkg#@*/}")" "npm install -g ${pkg}" "${pkg}"
    done
  fi
  if [ "${#AGENT_SH[@]}" -gt 0 ]; then
    for cmd in "${AGENT_SH[@]}"; do
      install_one_agent "" "${cmd}" "custom installer"
    done
  fi
}

WANT_AGENTS=0
if [ "${#AGENTS[@]}" -gt 0 ] || [ "${#AGENT_NPM[@]}" -gt 0 ] || [ "${#AGENT_SH[@]}" -gt 0 ]; then
  WANT_AGENTS=1
fi

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

# --- agent-only fast path: add agents to an existing install without re-downloading ---------
# Triggered when ONLY agent flags are given and the daemon is already installed AND its unit is
# fully current: it carries the agent PATH/prefix env AND the writable-home ReadWritePaths (so
# agents can both install and run). Skips the release download + service rewrite so live sessions
# aren't disrupted. If the unit predates EITHER, we fall through to the full flow so it's rewritten.
if [ "${WANT_AGENTS}" -eq 1 ] \
  && [ -f "/etc/systemd/system/${SERVICE}.service" ] && [ -d "${INSTALL_DIR}" ] \
  && grep -q 'NPM_CONFIG_PREFIX' "/etc/systemd/system/${SERVICE}.service" \
  && grep -qE "^ReadWritePaths=.* ${APP_HOME}\$" "/etc/systemd/system/${SERVICE}.service" \
  && [ "${USE_TAILSCALE}" -eq 0 ] && [ -z "${DOMAIN}" ] && [ "${VERSION}" = "latest" ] && [ -z "${TOKEN}" ]; then
  id -u "${APP_USER}" >/dev/null 2>&1 \
    || die "Service user '${APP_USER}' not found — run the installer once without --install-agent first."
  say "Adding agents to the existing install (no re-download)"
  apt-get install -y curl ca-certificates >/dev/null 2>&1 || true
  setup_npm_env
  install_agents
  echo
  ok "Agents installed — available to sessions started from the desktop app (Connected mode)."
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

# Writable npm prefix + agent dirs so agent CLIs install/run without root under ProtectHome.
say "Preparing agent install environment (${NPM_PREFIX})"
setup_npm_env

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
# Put the service user's agent install dirs + the bundled node on PATH so PTY sessions the
# daemon spawns resolve agent CLIs (npm-global bin, ~/.local/bin for curl installers, node).
Environment=NPM_CONFIG_PREFIX=${NPM_PREFIX}
Environment=PATH=${AGENT_BIN}:${APP_HOME}/.local/bin:${INSTALL_DIR}/node/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=${NODE_BIN} ${DAEMON_MAIN}
Restart=always
RestartSec=2

# Hardening — the daemon can spawn arbitrary processes, so contain it.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
# The whole service-user home is writable: agent CLIs install to, and read/write config, auth,
# and caches all over \$HOME (~/.local, ~/.config, ~/.npm-global, ~/.<tool>, ~/.claude.json, …),
# and whitelisting each agent's dirs is a losing game. ProtectHome still shields /root and any
# OTHER users' homes; ProtectSystem=strict still shields the OS. A leaked token already grants
# code execution as this user, so a writable own-home does not widen the blast radius.
ReadWritePaths=${DATA_DIR} ${PROJECTS_DIR} ${APP_HOME}

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable "${SERVICE}" >/dev/null
systemctl restart "${SERVICE}"

# --- 8b. agent CLIs (only when requested) ---------------------------------------------------
if [ "${WANT_AGENTS}" -eq 1 ]; then
  install_agents
fi

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
  Add agents : re-run with --install-agent claude-code
               (also: codex, grok, cursor, opencode, antigravity — or --agent-npm <pkg> / --agent-sh '<cmd>')
  Logs       : journalctl -u ${SERVICE} -f
  Status     : systemctl status ${SERVICE}
  Update     : re-run this installer (token + data preserved; previous release kept at ${INSTALL_DIR}.old)
  Remove     : sudo bash install.sh --uninstall

TIPS
