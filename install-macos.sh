#!/usr/bin/env bash
#
# VibeMaxx host — one-line macOS installer (vendored release, no npm/compiler on your Mac).
#
# Installs the always-on `vibemaxx-host` daemon (agent/terminal sessions over WebSocket) on a
# Mac as a launchd service that starts at boot, runs AS YOU, and restarts on crash. Your
# VibeMaxx desktop app then connects so sessions survive the app quitting / other machines
# sleeping.
#
# It downloads a self-contained release tarball (the daemon + its native modules + a bundled
# Node runtime) from this repo's GitHub Releases — the Mac never compiles anything or touches
# the npm registry.
#
# Run with sudo (installs a LaunchDaemon; the daemon itself runs as your user):
#
#   Private + encrypted via Tailscale (RECOMMENDED — install Tailscale + sign in first):
#     curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install-macos.sh | sudo bash -s -- --tailscale
#
#   Loopback only (reach it from this Mac / an SSH tunnel):
#     curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install-macos.sh | sudo bash
#
#   Read it first:
#     curl -fsSLO https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/install-macos.sh
#     sudo bash install-macos.sh --tailscale
#
# Idempotent: re-run to update to the latest release (token + data are preserved).
# Uninstall:  sudo bash install-macos.sh --uninstall   (add --purge to delete data too)
#
# Options:
#   --tailscale / --bind <ip>   Interface to bind ("tailscale" auto-detects the tailnet IP).
#   --port <n>                  Port (default 8765).
#   --token <tok>               Bearer token (default: reuse existing, else generate).
#   --github-token <tok>        GitHub token for authenticated git push/pull/clone (optional).
#   --version <tag>             Release tag to install (default: latest).
#   --user <name>               Account the daemon runs as (default: the sudo-invoking user).
#   --uninstall                 Stop + remove the LaunchDaemon (files + data kept).
#   --purge                     With --uninstall, also delete the install dir + data dir.
#
# VIBEMAXX_RELEASE_BASE_URL overrides where the tarball is fetched from (mirror / file dir).

set -euo pipefail

REPO_SLUG="elliotnex/vibemaxx-host"
LABEL="com.vibemaxx.host"
PLIST="/Library/LaunchDaemons/${LABEL}.plist"
INSTALL_DIR="/usr/local/vibemaxx-host"

PORT="8765"
BIND="127.0.0.1"
TOKEN=""
GITHUB_TOKEN=""
VERSION="latest"
TARGET_USER=""
DO_UNINSTALL=0
DO_PURGE=0
USE_TAILSCALE=0

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!  %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mx  %s\033[0m\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --tailscale)     USE_TAILSCALE=1; shift ;;
    --bind)          BIND="${2:-}"; shift 2 ;;
    --port)          PORT="${2:-}"; shift 2 ;;
    --token)         TOKEN="${2:-}"; shift 2 ;;
    --github-token)  GITHUB_TOKEN="${2:-}"; shift 2 ;;
    --version)       VERSION="${2:-}"; shift 2 ;;
    --user)          TARGET_USER="${2:-}"; shift 2 ;;
    --uninstall)     DO_UNINSTALL=1; shift ;;
    --purge)         DO_PURGE=1; shift ;;
    -h|--help)       grep -E '^#( |$)' "$0" | sed 's/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    *)               die "Unknown option: $1 (try --help)" ;;
  esac
done

[ "$(uname -s)" = "Darwin" ] || die "This installer targets macOS. Use install.sh (Linux) or install.ps1 (Windows)."
[ "$(id -u)" -eq 0 ] || die "Run with sudo (installs a LaunchDaemon):  curl -fsSL <url> | sudo bash"

TARGET_USER="${TARGET_USER:-${SUDO_USER:-}}"
[ -n "${TARGET_USER}" ] && [ "${TARGET_USER}" != "root" ] \
  || die "Could not determine your user. Run via 'sudo bash ...' (not as root directly), or pass --user <name>."
id -u "${TARGET_USER}" >/dev/null 2>&1 || die "User '${TARGET_USER}' does not exist."
USER_HOME="$(dscl . -read "/Users/${TARGET_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
[ -n "${USER_HOME}" ] || USER_HOME="/Users/${TARGET_USER}"
[ -d "${USER_HOME}" ] || die "Home directory for ${TARGET_USER} not found (${USER_HOME})."

DATA_DIR="${USER_HOME}/.vibemaxx-host"
SPACES_DIR="${USER_HOME}/vibemaxx/spaces"
REPOS_DIR="${USER_HOME}/vibemaxx/repos"
ENV_FILE="${DATA_DIR}/host.env"
LOG_DIR="${DATA_DIR}/logs"
LAUNCHER="${INSTALL_DIR}/launch.sh"
TOKENS_CLI="${INSTALL_DIR}/vibemaxx-host"

as_user() { sudo -u "${TARGET_USER}" -H bash -lc "export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH; $1"; }

# --- Uninstall ------------------------------------------------------------------------------
if [ "${DO_UNINSTALL}" -eq 1 ]; then
  say "Stopping and removing the LaunchDaemon"
  launchctl bootout system "${PLIST}" 2>/dev/null || launchctl unload "${PLIST}" 2>/dev/null || true
  rm -f "${PLIST}"
  if [ "${DO_PURGE}" -eq 1 ]; then
    say "Purging ${INSTALL_DIR} and ${DATA_DIR}"
    rm -rf "${INSTALL_DIR}" "${DATA_DIR}"
    ok "Uninstalled and purged."
  else
    ok "Uninstalled. Files (${INSTALL_DIR}) and data (${DATA_DIR}) kept — re-run to restore."
  fi
  exit 0
fi

# --- Bind resolution (Tailscale) ------------------------------------------------------------
case "${BIND}" in tailscale|tailnet) USE_TAILSCALE=1 ;; esac
if [ "${USE_TAILSCALE}" -eq 1 ]; then
  TS_BIN=""
  for c in tailscale /Applications/Tailscale.app/Contents/MacOS/Tailscale; do
    command -v "$c" >/dev/null 2>&1 && { TS_BIN="$c"; break; }
    [ -x "$c" ] && { TS_BIN="$c"; break; }
  done
  [ -n "${TS_BIN}" ] || die "Tailscale requested but the CLI wasn't found. Install Tailscale, sign in, then re-run."
  TS_IP="$("${TS_BIN}" ip -4 2>/dev/null | head -n1 | tr -d '[:space:]')"
  [ -n "${TS_IP}" ] || die "Could not read this Mac's Tailscale IPv4. Is it signed in and running?"
  BIND="${TS_IP}"
  say "Binding to Tailscale address ${BIND}"
fi

# --- 1. Resolve + download + verify the release ---------------------------------------------
case "$(uname -m)" in
  arm64)          PLATFORM="darwin-arm64" ;;
  x86_64|amd64)   PLATFORM="darwin-x64" ;;
  *)              die "Unsupported CPU architecture: $(uname -m)." ;;
esac
ASSET="vibemaxx-host-${PLATFORM}.tar.gz"
if [ -n "${VIBEMAXX_RELEASE_BASE_URL:-}" ]; then
  BASE_URL="${VIBEMAXX_RELEASE_BASE_URL%/}"
elif [ "${VERSION}" = "latest" ]; then
  BASE_URL="https://github.com/${REPO_SLUG}/releases/latest/download"
else
  BASE_URL="https://github.com/${REPO_SLUG}/releases/download/${VERSION}"
fi

TMP="$(mktemp -d)"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/.vibemaxx-host.XXXXXX")"
cleanup() { rm -rf "${TMP}" "${STAGING}" 2>/dev/null || true; }
trap cleanup EXIT

fetch() {  # fetch <name> <dest>
  case "${BASE_URL}" in
    http*://*) curl -fSL --retry 3 --retry-delay 2 -o "$2" "${BASE_URL}/$1" ;;
    file://*)  cp "${BASE_URL#file://}/$1" "$2" ;;
    *)         cp "${BASE_URL}/$1" "$2" ;;
  esac
}

say "Downloading ${ASSET} (${VERSION})"
fetch "${ASSET}" "${TMP}/${ASSET}" \
  || die "Could not fetch ${BASE_URL}/${ASSET} — is the release published for ${PLATFORM}?"

if fetch "${ASSET}.sha256" "${TMP}/${ASSET}.sha256" 2>/dev/null; then
  say "Verifying checksum"
  EXPECTED="$(awk '{print $1}' "${TMP}/${ASSET}.sha256")"
  ACTUAL="$(shasum -a 256 "${TMP}/${ASSET}" | awk '{print $1}')"
  [ "${EXPECTED}" = "${ACTUAL}" ] || die "Checksum mismatch — refusing to install. expected ${EXPECTED}, got ${ACTUAL}"
  ok "Checksum verified"
else
  warn "No checksum published for this release — skipping integrity check."
fi

say "Extracting"
tar -xzf "${TMP}/${ASSET}" -C "${STAGING}"
[ -f "${STAGING}/host-dist/host/index.js" ] || die "Release tarball is missing host-dist/host/index.js."
[ -x "${STAGING}/node/bin/node" ] || die "Release tarball is missing its bundled node."

# --- 2. Token (reused across re-runs) -------------------------------------------------------
if [ -z "${TOKEN}" ] && [ -f "${ENV_FILE}" ]; then
  TOKEN="$(grep -E '^VIBEMAXX_HOST_TOKEN=' "${ENV_FILE}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
  [ -n "${TOKEN}" ] && say "Reusing the existing token"
fi
if [ -z "${GITHUB_TOKEN}" ] && [ -f "${ENV_FILE}" ]; then
  GITHUB_TOKEN="$(grep -E '^VIBEMAXX_HOST_GITHUB_TOKEN=' "${ENV_FILE}" 2>/dev/null | head -n1 | cut -d= -f2- || true)"
fi

# --- 3. Swap the new release into place (keep one backup for rollback) -----------------------
say "Installing to ${INSTALL_DIR}"
launchctl bootout system "${PLIST}" 2>/dev/null || true
rm -rf "${INSTALL_DIR}.old"
[ -d "${INSTALL_DIR}" ] && mv "${INSTALL_DIR}" "${INSTALL_DIR}.old"
mv "${STAGING}" "${INSTALL_DIR}"
trap 'rm -rf "${TMP}" 2>/dev/null || true' EXIT
chown -R root:wheel "${INSTALL_DIR}"
# The daemon runs as the user: it must read + traverse the tree and execute node/spawn-helper.
chmod -R a+rX "${INSTALL_DIR}"
find "${INSTALL_DIR}" -name spawn-helper -exec chmod +x {} \; 2>/dev/null || true
chmod +x "${INSTALL_DIR}/node/bin/node" 2>/dev/null || true
NODE_BIN="${INSTALL_DIR}/node/bin/node"
DAEMON_MAIN="${INSTALL_DIR}/host-dist/host/index.js"

# --- 4. User dirs + token ------------------------------------------------------------------
as_user "mkdir -p '${DATA_DIR}' '${SPACES_DIR}' '${REPOS_DIR}' '${LOG_DIR}'"
if [ -z "${TOKEN}" ]; then
  say "Generating a new bearer token"
  TOKEN="$("${NODE_BIN}" -e 'console.log(require("crypto").randomBytes(32).toString("hex"))')"
fi

# PATH for the daemon + its agent PTYs (launchd hands a stripped PATH). Include the user's
# npm-global bin, Homebrew (arm64 + Intel), git's dir, ~/.local/bin, then the standard dirs.
NPM_PREFIX="$(as_user 'npm config get prefix' 2>/dev/null | tail -n1 || true)"
[ -n "${NPM_PREFIX}" ] || NPM_PREFIX="${USER_HOME}/.npm-global"
GIT_DIR="$(as_user 'command -v git' 2>/dev/null | sed 's#/git$##' || true)"
SVC_PATH="${NPM_PREFIX}/bin:${USER_HOME}/.local/bin"
[ -n "${GIT_DIR}" ] && SVC_PATH="${SVC_PATH}:${GIT_DIR}"
SVC_PATH="${SVC_PATH}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
[ -n "${GIT_DIR}" ] || warn "git not found for ${TARGET_USER} — repo MaxxSpaces need it (brew install git or Xcode CLT)."

say "Writing ${ENV_FILE}"
UMASK_OLD="$(umask)"; umask 077
{
  echo "VIBEMAXX_HOST_TOKEN=${TOKEN}"
  echo "VIBEMAXX_HOST_BIND=${BIND}"
  echo "VIBEMAXX_HOST_PORT=${PORT}"
  echo "VIBEMAXX_HOST_DATA_DIR=${DATA_DIR}"
  echo "VIBEMAXX_HOST_SPACES_DIR=${SPACES_DIR}"
  echo "VIBEMAXX_HOST_REPOS_DIR=${REPOS_DIR}"
  echo "HOME=${USER_HOME}"
  echo "PATH=${SVC_PATH}"
  [ -n "${GITHUB_TOKEN}" ] && echo "VIBEMAXX_HOST_GITHUB_TOKEN=${GITHUB_TOKEN}"
} > "${ENV_FILE}"
umask "${UMASK_OLD}"
chown "${TARGET_USER}" "${ENV_FILE}"; chmod 600 "${ENV_FILE}"

cat > "${LAUNCHER}" <<LAUNCH
#!/bin/bash
set -a
. "${ENV_FILE}"
set +a
exec "${NODE_BIN}" "${DAEMON_MAIN}" "\$@"
LAUNCH
chmod 755 "${LAUNCHER}"

cat > "${TOKENS_CLI}" <<CLI
#!/bin/bash
# e.g.  ${TOKENS_CLI} tokens add "Elliot's iPhone"
export VIBEMAXX_HOST_DATA_DIR="${DATA_DIR}"
exec "${LAUNCHER}" "\$@"
CLI
chmod 755 "${TOKENS_CLI}"

# Codex sandbox posture (create-if-missing): the box is the sandbox.
CODEX_CONFIG="${USER_HOME}/.codex/config.toml"
if [ ! -f "${CODEX_CONFIG}" ]; then
  as_user "mkdir -p '${USER_HOME}/.codex'"
  cat > "${CODEX_CONFIG}" <<'CODEX'
# Written by the VibeMaxx host installer. This box is the sandbox: agents run under the
# vibemaxx-host daemon, so Codex's own sandbox only blocks legitimate work.
approval_policy = "never"
sandbox_mode = "danger-full-access"
CODEX
  chown "${TARGET_USER}" "${CODEX_CONFIG}"
fi

# --- 5. LaunchDaemon ------------------------------------------------------------------------
say "Installing LaunchDaemon ${LABEL} (runs as ${TARGET_USER})"
cat > "${PLIST}" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>UserName</key>
  <string>${TARGET_USER}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${LAUNCHER}</string>
  </array>
  <key>WorkingDirectory</key>
  <string>${INSTALL_DIR}</string>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>${LOG_DIR}/host.out.log</string>
  <key>StandardErrorPath</key>
  <string>${LOG_DIR}/host.err.log</string>
</dict>
</plist>
PLISTEOF
chown root:wheel "${PLIST}"; chmod 644 "${PLIST}"

launchctl bootout system "${PLIST}" 2>/dev/null || true
launchctl bootstrap system "${PLIST}" 2>/dev/null || launchctl load -w "${PLIST}"
launchctl enable "system/${LABEL}" 2>/dev/null || true
launchctl kickstart -k "system/${LABEL}" 2>/dev/null || true

# --- 6. Health check + summary --------------------------------------------------------------
HEALTH="unreachable"
for _ in $(seq 1 20); do
  sleep 0.5
  if curl -fsS "http://${BIND}:${PORT}/healthz" >/dev/null 2>&1; then HEALTH="ok"; break; fi
done
[ "${HEALTH}" = "ok" ] || warn "Health check didn't return ok yet — see ${LOG_DIR}/host.err.log"

cat <<SUMMARY

$(ok "VibeMaxx host is set up on macOS.")

  Service     : ${LABEL} (launchd, runs as ${TARGET_USER})
  Health      : http://${BIND}:${PORT}/healthz -> ${HEALTH}
  Data dir    : ${DATA_DIR}
  Logs        : ${LOG_DIR}

  Connect from the desktop app (Settings -> Connections -> Host connection):
    URL   : ws://${BIND}:${PORT}
    Token : ${TOKEN}

  Restart     : sudo launchctl kickstart -k system/${LABEL}
  Stop        : sudo launchctl bootout system ${PLIST}
  Device keys : ${TOKENS_CLI} tokens add "Elliot's iPhone"
  Update      : re-run this installer (token + data kept)
  Uninstall   : sudo bash install-macos.sh --uninstall  (add --purge to delete data)

SUMMARY

if [ "${BIND}" = "127.0.0.1" ]; then
  warn "Loopback-only bind: other devices can't reach it. Re-run with --tailscale to bind your tailnet IP."
fi
warn "Macs sleep by default, suspending every hosted session. Keep it awake on power:"
echo  "    sudo pmset -c sleep 0 disablesleep 1"
