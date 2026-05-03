#!/usr/bin/env bash
# scripts/authorize-ssh-keys.sh
#
# One-time bootstrap: authorize $SSH_PUBLIC_KEY_PATH on the Proxmox host and
# every worker, so all subsequent scripts (deploy-prep.sh, check-prereqs.sh,
# tofu apply provisioners) can SSH in non-interactively via key auth.
#
# You'll be prompted for each host's user password the first time only —
# already-authorized hosts are skipped silently. Re-running is safe.
#
# After this runs successfully, the only remaining password prompts are for
# `sudo` on each worker (one per worker per `deploy-prep.sh` run).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/cluster.conf"
if [ ! -f "$CONF_FILE" ]; then
  printf "ERROR: %s not found.\n" "$CONF_FILE" >&2
  exit 2
fi
# shellcheck source=cluster.conf
. "$CONF_FILE"

# ============================================================================
# Output helpers
# ============================================================================
if [ -t 1 ]; then
  GREEN=$'\e[0;32m'; RED=$'\e[0;31m'; YELLOW=$'\e[0;33m'; CYAN=$'\e[0;36m'; NC=$'\e[0m'
else
  GREEN=''; RED=''; YELLOW=''; CYAN=''; NC=''
fi

banner() { printf "\n${CYAN}========== %s ==========${NC}\n" "$*"; }
ok()     { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
err()    { printf "${RED}[ERR]${NC} %s\n" "$*" >&2; }
note()   { printf "${YELLOW}[NOTE]${NC} %s\n" "$*"; }

# ============================================================================
# Pre-flight
# ============================================================================
[ -f "$SSH_PUBLIC_KEY_PATH" ] || {
  err "Public key not found at $SSH_PUBLIC_KEY_PATH"
  err "Generate one first:  ssh-keygen -t ed25519 -f ${SSH_KEY_PATH}"
  exit 1
}
PUBKEY=$(< "$SSH_PUBLIC_KEY_PATH")

# ============================================================================
# Per-host worker
# ============================================================================

# Already authorized? (silent probe via BatchMode=yes — no password attempted)
key_already_works() {
  local user="$1" host="$2"
  ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new \
      -i "$SSH_KEY_PATH" "$user@$host" 'true' 2>/dev/null
}

# Push the key (interactive — will prompt for password).
authorize_one() {
  local user="$1" host="$2"
  banner "$user@$host"

  if key_already_works "$user" "$host"; then
    ok "key already authorized — no action"
    return 0
  fi

  note "key not yet authorized — pushing it now (you'll be prompted for the password)"
  if command -v ssh-copy-id >/dev/null 2>&1; then
    ssh-copy-id -i "$SSH_PUBLIC_KEY_PATH" \
                -o StrictHostKeyChecking=accept-new \
                "$user@$host"
  else
    # Manual fallback: idempotent append (skip if already present).
    ssh -o StrictHostKeyChecking=accept-new "$user@$host" "
      mkdir -p ~/.ssh && chmod 700 ~/.ssh
      touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys
      grep -qxF '$PUBKEY' ~/.ssh/authorized_keys || echo '$PUBKEY' >> ~/.ssh/authorized_keys
    "
  fi

  if key_already_works "$user" "$host"; then
    ok "key authorized successfully"
  else
    err "key auth still failing on $user@$host — investigate manually"
    return 1
  fi
}

# ============================================================================
# Main
# ============================================================================
echo "Authorizing $(basename "$SSH_PUBLIC_KEY_PATH") on Proxmox + $(printf '%s\n' "$WORKERS" | grep -c '=') worker(s)."

# Proxmox host
authorize_one "$PROXMOX_USER" "$PROXMOX_HOST" || exit 1

# Workers
mapfile -t WORKER_LINES <<< "$WORKERS"
for entry in "${WORKER_LINES[@]}"; do
  [ -n "$entry" ] || continue
  IFS='=' read -r wname waddr <<< "$entry"
  authorize_one "$WORKER_USER" "$waddr" || exit 1
done

banner "All keys authorized"
echo "Next: bash scripts/deploy-prep.sh"
