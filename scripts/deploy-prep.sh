#!/usr/bin/env bash
# scripts/deploy-prep.sh
#
# One-command wrapper that ships and runs the per-host prep scripts:
#   - Proxmox host: SSH as root, run prep-proxmox.sh via stdin redirect
#     (no temp file lands on the host; root SSH is on by default in PVE).
#   - Each worker: scp + ssh -t with sudo (so the sudo password prompt works
#     cleanly under TTY). You'll be asked for the sudo password once per worker
#     — sudo timestamp doesn't carry across SSH sessions.
#
# Aborts the worker loop on the first failure so a half-broken state isn't
# hidden by later progress.
#
# Defaults match the home-cluster topology + c4 user; override via env vars or
# CLI flags below.

set -uo pipefail

# ============================================================================
# Source shared topology (single edit point: scripts/cluster.conf).
# CLI flags below still override anything cluster.conf sets.
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/cluster.conf"
if [ ! -f "$CONF_FILE" ]; then
  printf "ERROR: %s not found.\n" "$CONF_FILE" >&2
  printf "       This file holds the cluster topology (PROXMOX_HOST, WORKERS, etc.).\n" >&2
  exit 2
fi
# shellcheck source=cluster.conf
. "$CONF_FILE"

ONLY_PROXMOX=0
ONLY_WORKERS=0

# ============================================================================
# CLI flags
# ============================================================================
while [ $# -gt 0 ]; do
  case "$1" in
    --proxmox-host)   PROXMOX_HOST="$2";  shift 2 ;;
    --proxmox-user)   PROXMOX_USER="$2";  shift 2 ;;
    --worker-user)    WORKER_USER="$2";   shift 2 ;;
    --ssh-key)        SSH_KEY_PATH="$2";  shift 2 ;;
    --only-proxmox)   ONLY_PROXMOX=1;     shift ;;
    --only-workers)   ONLY_WORKERS=1;     shift ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) printf "Unknown argument: %s\n" "$1" >&2; exit 2 ;;
  esac
done

# ============================================================================
# Resolve script paths (SCRIPT_DIR set during cluster.conf source above)
# ============================================================================
PREP_PROXMOX="$SCRIPT_DIR/prep-proxmox.sh"
PREP_WORKER="$SCRIPT_DIR/prep-worker.sh"

[ -f "$PREP_PROXMOX" ] || { printf "Missing: %s\n" "$PREP_PROXMOX" >&2; exit 1; }
[ -f "$PREP_WORKER" ]  || { printf "Missing: %s\n" "$PREP_WORKER"  >&2; exit 1; }

# ============================================================================
# Output helpers
# ============================================================================
if [ -t 1 ]; then
  GREEN=$'\e[0;32m'; RED=$'\e[0;31m'; CYAN=$'\e[0;36m'; YELLOW=$'\e[0;33m'; NC=$'\e[0m'
else
  GREEN=''; RED=''; CYAN=''; YELLOW=''; NC=''
fi

banner() { printf "\n${CYAN}========== %s ==========${NC}\n" "$*"; }
ok()     { printf "${GREEN}[OK]${NC} %s\n"  "$*"; }
err()    { printf "${RED}[ERR]${NC} %s\n"   "$*" >&2; }
note()   { printf "${YELLOW}[NOTE]${NC} %s\n" "$*"; }

# ============================================================================
# Per-host runners
# ============================================================================

# Proxmox: stdin-redirect; no file lands, no sudo (we're already root).
run_prep_proxmox() {
  banner "Proxmox host: $PROXMOX_USER@$PROXMOX_HOST"
  ssh -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=accept-new \
      "$PROXMOX_USER@$PROXMOX_HOST" \
      'bash -s' < "$PREP_PROXMOX"
}

# Worker: scp + ssh -t with sudo. The PTY is what makes sudo's password prompt
# work cleanly. Cleans up the temp file regardless of the script's exit code.
run_prep_worker() {
  local addr="$1"
  local remote="/tmp/prep-worker.$$.$RANDOM.sh"
  banner "Worker: $WORKER_USER@$addr  (will prompt for sudo password)"
  if ! scp -q -i "$SSH_KEY_PATH" \
         -o StrictHostKeyChecking=accept-new \
         "$PREP_WORKER" "$WORKER_USER@$addr:$remote"; then
    err "scp to $addr failed"
    return 1
  fi
  # Run via sudo with TTY; capture sudo's exit code, clean up temp file, propagate.
  ssh -t -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=accept-new \
      "$WORKER_USER@$addr" \
      "sudo bash $remote; rc=\$?; rm -f $remote; exit \$rc"
}

# ============================================================================
# Main
# ============================================================================

if [ "$ONLY_PROXMOX" = "1" ] && [ "$ONLY_WORKERS" = "1" ]; then
  err "Cannot pass both --only-proxmox and --only-workers."
  exit 2
fi

if [ "$ONLY_WORKERS" = "0" ]; then
  if ! run_prep_proxmox; then
    err "prep-proxmox.sh failed on $PROXMOX_HOST — aborting"
    exit 1
  fi
  ok "Proxmox prep complete"
fi

if [ "$ONLY_PROXMOX" = "0" ]; then
  # Read into an array FIRST so the iteration loop body keeps stdin = terminal.
  # (A `while ... done <<< "$WORKERS"` would redirect the loop's stdin to the
  # heredoc string, breaking ssh -t / sudo password prompts inside the body.)
  mapfile -t WORKER_LINES <<< "$WORKERS"
  note "About to prep ${#WORKER_LINES[@]} worker(s); you'll type sudo password once per worker."
  for entry in "${WORKER_LINES[@]}"; do
    [ -n "$entry" ] || continue
    IFS='=' read -r wname waddr <<< "$entry"
    if ! run_prep_worker "$waddr"; then
      err "prep-worker.sh failed on $wname ($waddr) — aborting (already-prepped workers are unaffected)"
      exit 1
    fi
    ok "$wname prep complete"
  done
fi

banner "All prep done"
echo "Next:"
echo "  cd $(dirname "$SCRIPT_DIR")"
echo "  bash scripts/check-prereqs.sh"
