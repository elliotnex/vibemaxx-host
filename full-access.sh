#!/usr/bin/env bash
#
# Give VibeMaxx agent sessions full access on a VPS that is ALREADY running the host daemon.
# Installs from before this was the default leave agents confined; this fixes them in place,
# without re-downloading the release.
#
#     curl -fsSL https://raw.githubusercontent.com/elliotnex/vibemaxx-host/main/full-access.sh | sudo bash
#
#     sudo bash full-access.sh              # unlock (restarts the daemon)
#     sudo bash full-access.sh --no-restart # stage it; applies on the next restart
#     sudo bash full-access.sh --revert     # put the containment back
#
# Self-contained on purpose: no repo checkout needed. Idempotent, and the systemd drop-in it
# writes survives re-running install.sh.
#
# WHY THIS EXISTS
#
# Agent PTYs are children of the daemon, so everything systemd applies to the service is
# inherited by the agent — each directive becomes a permission error inside a session:
#
#   NoNewPrivileges=true   sudo dies with "the 'no new privileges' flag is set, which prevents
#                          sudo from running as root"; Codex reports it as a no-new-privileges
#                          restriction. No sudoers entry can undo it.
#   ProtectSystem=strict   every path outside ReadWritePaths is read-only — EROFS on /etc,
#                          /usr/local, /srv, /var, and any repo checked out off $HOME.
#   ProtectHome=read-only  other users' homes are read-only.
#   PrivateTmp=true        the agent's /tmp is invisible to your own SSH session.
#
# And systemd is only half of it: Codex on Linux sandboxes itself by default
# (sandbox_mode="workspace-write" — Landlock + seccomp, writes confined to the session cwd,
# network egress blocked). On a VPS the box is the sandbox, so this turns that off too.
#
# WHAT IT CHANGES
#   1. /etc/systemd/system/<service>.service.d/10-vibemaxx-full-access.conf — clears the
#      sandbox directives above.
#   2. /etc/sudoers.d/vibemaxx-agents — passwordless sudo for the service user (skip with
#      VIBEMAXX_AGENT_SUDO=0). A leaked host token becomes root on this box; that is the trade.
#   3. The service user's login shell (nologin -> /bin/bash) and docker group membership.
#   4. ~/.codex/config.toml — approval_policy = "never", sandbox_mode = "danger-full-access".
#
# Env: VIBEMAXX_SERVICE (default vibemaxx-host), VIBEMAXX_USER (default: the unit's User=),
#      VIBEMAXX_AGENT_SUDO (default 1).

set -euo pipefail

SERVICE="${VIBEMAXX_SERVICE:-vibemaxx-host}"
AGENT_SUDO="${VIBEMAXX_AGENT_SUDO:-1}"
RESTART=1
REVERT=0
DROPIN_DIR="/etc/systemd/system/${SERVICE}.service.d"
DROPIN="${DROPIN_DIR}/10-vibemaxx-full-access.conf"
SUDOERS_FILE="/etc/sudoers.d/vibemaxx-agents"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!  %s\033[0m\n' "$*" >&2; }
ok()   { printf '\033[1;32m   ✓ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mx  %s\033[0m\n' "$*" >&2; exit 1; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-restart) RESTART=0 ;;
    --revert) REVERT=1 ;;
    -h | --help) sed -n '2,40p' "$0"; exit 0 ;;
    *) die "Unknown option '$1' (see --help)." ;;
  esac
  shift
done

[ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash full-access.sh"
command -v systemctl >/dev/null || die "systemd not found — this targets a systemd VPS."
systemctl cat "${SERVICE}" >/dev/null 2>&1 \
  || die "Service '${SERVICE}' not found. Install the host daemon first, or set VIBEMAXX_SERVICE."

# The unit is the source of truth for who agents run as.
APP_USER="${VIBEMAXX_USER:-$(systemctl show -p User --value "${SERVICE}" 2>/dev/null || true)}"
APP_USER="${APP_USER:-vibemaxx}"
id -u "${APP_USER}" >/dev/null 2>&1 || die "Service user '${APP_USER}' does not exist."
APP_HOME="$(getent passwd "${APP_USER}" | cut -d: -f6)"
APP_HOME="${APP_HOME:-/home/${APP_USER}}"

# --- revert ---------------------------------------------------------------------------------
if [ "${REVERT}" -eq 1 ]; then
  say "Reverting agent full access for ${SERVICE} (user ${APP_USER})"
  rm -f "${DROPIN}" "${SUDOERS_FILE}"
  rmdir "${DROPIN_DIR}" 2>/dev/null || true
  systemctl daemon-reload
  ok "Removed the drop-in and the sudoers entry"
  warn "The unit's own directives now apply again. Restart to take effect: systemctl restart ${SERVICE}"
  warn "Codex's config (${APP_HOME}/.codex/config.toml) is left as-is — edit sandbox_mode by hand."
  exit 0
fi

# --- 1. systemd drop-in ---------------------------------------------------------------------
# A drop-in (not an edit of the unit) so re-running the public installer, which rewrites the
# unit file wholesale, does not undo this. Empty ReadWritePaths= resets the inherited list.
say "Clearing systemd sandboxing for ${SERVICE}"
install -d -m 755 "${DROPIN_DIR}"
cat > "${DROPIN}" <<CONF
# Written by VibeMaxx full-access.sh.
#
# Agent PTYs are children of this daemon, so the unit's sandbox directives are inherited by
# every agent and surface as permission errors inside sessions: NoNewPrivileges breaks sudo,
# ProtectSystem=strict makes everything outside ReadWritePaths read-only, PrivateTmp hides the
# agent's /tmp from your SSH session. Running agents is the point of this daemon, so it runs
# with the service user's full rights; containment is the dedicated user + token + private bind.
#
# Undo with: sudo bash full-access.sh --revert
[Service]
NoNewPrivileges=false
PrivateTmp=false
ProtectSystem=no
ProtectHome=no
ReadWritePaths=
CONF
ok "${DROPIN}"

# --- 2. sudo --------------------------------------------------------------------------------
# Agents routinely need root on their own box (apt-get install, /usr/local, systemctl). Without
# this they hit "user is not in the sudoers file"; with NoNewPrivileges still set they'd hit the
# no-new-privileges error even with it. visudo -c validates before install so sudo can't break.
if [ "${AGENT_SUDO}" = "1" ]; then
  say "Granting passwordless sudo to ${APP_USER}"
  TMP_SUDOERS="$(mktemp)"
  cat > "${TMP_SUDOERS}" <<SUDOERS
# Written by VibeMaxx full-access.sh — agent sessions run as ${APP_USER} and need root for
# package installs, service management, and writes outside \$HOME.
# Remove this file to keep agents at that user's own rights.
${APP_USER} ALL=(ALL) NOPASSWD: ALL
SUDOERS
  if visudo -cqf "${TMP_SUDOERS}"; then
    install -m 440 -o root -g root "${TMP_SUDOERS}" "${SUDOERS_FILE}"
    ok "${SUDOERS_FILE}"
  else
    warn "Generated sudoers file failed validation — skipped (agents stay at user-level rights)."
  fi
  rm -f "${TMP_SUDOERS}"
else
  say "VIBEMAXX_AGENT_SUDO=0 — leaving agents at ${APP_USER}'s own rights"
fi

# --- 3. login shell + docker ----------------------------------------------------------------
# The installers create the account with nologin. Interactive agent sessions, `sudo -i`, `su -`,
# and login-shell tooling all want a real shell; the account still has no password.
CURRENT_SHELL="$(getent passwd "${APP_USER}" | cut -d: -f7 || true)"
case "${CURRENT_SHELL}" in
  */nologin | */false | "")
    say "Giving ${APP_USER} a login shell (was ${CURRENT_SHELL:-none})"
    usermod -s /bin/bash "${APP_USER}"
    ok "/bin/bash"
    ;;
esac
if getent group docker >/dev/null 2>&1 && ! id -nG "${APP_USER}" | tr ' ' '\n' | grep -qx docker; then
  usermod -aG docker "${APP_USER}" && ok "added ${APP_USER} to the docker group"
fi

# --- 4. Codex's own sandbox -----------------------------------------------------------------
# Codex on Linux defaults to a Landlock/seccomp jail (sandbox_mode="workspace-write"): writes
# confined to the session cwd, network egress blocked, PR_SET_NO_NEW_PRIVS set on itself. The
# app's "Dangerous mode" toggle passes --yolo per launch; this makes it the host default too.
CODEX_DIR="${APP_HOME}/.codex"
CODEX_CONFIG="${CODEX_DIR}/config.toml"
say "Disabling the Codex CLI sandbox in ${CODEX_CONFIG}"
install -d -o "${APP_USER}" -g "${APP_USER}" "${CODEX_DIR}"
if [ ! -f "${CODEX_CONFIG}" ]; then
  cat > "${CODEX_CONFIG}" <<'CODEX'
# Written by VibeMaxx full-access.sh. This box is the sandbox: the agent runs as a dedicated
# non-root user on a machine dedicated to it, so Codex's own Landlock/seccomp jail only blocks
# legitimate work (writes outside the cwd, network access, sudo).
approval_policy = "never"
sandbox_mode = "danger-full-access"
CODEX
  chown "${APP_USER}:${APP_USER}" "${CODEX_CONFIG}"
  ok "wrote ${CODEX_CONFIG}"
elif grep -qE '^[[:space:]]*sandbox_mode[[:space:]]*=[[:space:]]*"danger-full-access"' "${CODEX_CONFIG}"; then
  ok "already set — leaving ${CODEX_CONFIG} alone"
else
  cp -a "${CODEX_CONFIG}" "${CODEX_CONFIG}.vibemaxx.bak"
  # TOML top-level keys must precede any [table], so drop the old lines and prepend ours.
  TMP_CODEX="$(mktemp)"
  {
    echo '# Rewritten by VibeMaxx full-access.sh (previous file: config.toml.vibemaxx.bak).'
    echo 'approval_policy = "never"'
    echo 'sandbox_mode = "danger-full-access"'
    grep -vE '^[[:space:]]*(approval_policy|sandbox_mode)[[:space:]]*=' "${CODEX_CONFIG}"
  } > "${TMP_CODEX}"
  install -m 600 -o "${APP_USER}" -g "${APP_USER}" "${TMP_CODEX}" "${CODEX_CONFIG}"
  rm -f "${TMP_CODEX}"
  ok "updated (previous config kept at ${CODEX_CONFIG}.vibemaxx.bak)"
fi

# --- 5. apply -------------------------------------------------------------------------------
systemctl daemon-reload
if [ "${RESTART}" -eq 1 ]; then
  say "Restarting ${SERVICE}"
  warn "This kills the PTYs of any live agent sessions on this host."
  systemctl restart "${SERVICE}"
  sleep 1
else
  warn "--no-restart: the new limits apply to sessions started after the next restart."
fi

# --- 6. verify ------------------------------------------------------------------------------
say "Verifying"
for prop in NoNewPrivileges ProtectSystem ProtectHome PrivateTmp ReadWritePaths; do
  printf '   %-16s %s\n' "${prop}" "$(systemctl show -p "${prop}" --value "${SERVICE}" 2>/dev/null)"
done
printf '   %-16s %s\n' "Active" "$(systemctl is-active "${SERVICE}" || true)"
if [ "${AGENT_SUDO}" = "1" ] && [ -f "${SUDOERS_FILE}" ]; then
  if runuser -u "${APP_USER}" -- sudo -n true >/dev/null 2>&1; then
    ok "${APP_USER} can sudo without a password"
  else
    warn "sudo check failed for ${APP_USER} — inspect ${SUDOERS_FILE} and 'sudo -l -U ${APP_USER}'."
  fi
fi

cat <<DONE

$(printf '\033[1;32m✓ Agents on this host now run with full access.\033[0m')

  Sessions started from here can write anywhere, install packages (sudo), and reach the
  network. Codex no longer applies its own sandbox.

$(printf '\033[1;33m!  A leaked host token is now root on this box.\033[0m')
  Keep it secret, keep the daemon off the public internet (Tailscale, or Caddy + TLS), and
  prefer a VPS dedicated to this. Undo any time:  sudo bash full-access.sh --revert

DONE
