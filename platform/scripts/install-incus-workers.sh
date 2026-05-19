#!/usr/bin/env bash
# scripts/install-incus-workers.sh
#
# Orchestrator that ships and runs prep-worker-incus.sh on each rdxa worker
# (rdxa1..4). All 4 hosts run both k3s-agent and Incus 7.0 in the unified
# scheme since 2026-05-19. Use this when reflashing a node from a clean
# image, or to bring a 5th worker into the fleet — it is idempotent.
#
# Prereq (USER): UEFI Hypervisor Override must be enabled on each target
# (F2 during boot → Hypervisor Settings → Hypervisor Override). Without it,
# install completes but VMs can't launch (LXC containers still work).
#
# Flags:
#   --only <name>   Run on just one node (e.g. --only rdxa3). Useful for
#                   staged rollout or retrying a single failure.
#   --ssh-key PATH  Override the SSH key (default: from cluster.conf).
#
# Aborts on the first failure so a half-broken state isn't masked by later
# progress. Safe to re-run: prep-worker-incus.sh is idempotent.

set -uo pipefail

# ============================================================================
# Source shared topology (single edit point: scripts/cluster.conf).
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONF_FILE="$SCRIPT_DIR/cluster.conf"
if [ ! -f "$CONF_FILE" ]; then
  printf "ERROR: %s not found.\n" "$CONF_FILE" >&2
  exit 2
fi
# shellcheck source=cluster.conf
. "$CONF_FILE"

# All 4 rdxa hosts run the same Incus+k3s coexistence config. Source from
# cluster.conf so adding a 5th host is one edit there, not here.
WORKERS_INCUS="$WORKERS"

ONLY_NODE=""

# ============================================================================
# CLI flags
# ============================================================================
while [ $# -gt 0 ]; do
  case "$1" in
    --only)      ONLY_NODE="$2";    shift 2 ;;
    --ssh-key)   SSH_KEY_PATH="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0 ;;
    *) printf "Unknown argument: %s\n" "$1" >&2; exit 2 ;;
  esac
done

# ============================================================================
# Resolve artifact paths (relative to SCRIPT_DIR)
# ============================================================================
PREP_SCRIPT="$SCRIPT_DIR/prep-worker-incus.sh"
PRESEED="$(cd "$SCRIPT_DIR/.." && pwd)/files/incus/preseed-worker.yaml"

[ -f "$PREP_SCRIPT" ] || { printf "Missing: %s\n" "$PREP_SCRIPT" >&2; exit 1; }
[ -f "$PRESEED" ]     || { printf "Missing: %s\n" "$PRESEED"     >&2; exit 1; }

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
# Per-host runner: scp both files, then ssh -t with sudo for TTY-friendly
# password prompt. Clean up temp files regardless of exit code.
# ============================================================================
run_install_incus() {
  local name="$1" addr="$2"
  local rscript="/tmp/prep-worker-incus.$$.sh"
  local rpreseed="/tmp/preseed-worker.$$.yaml"
  banner "Worker: $name ($WORKER_USER@$addr)  (sudo password may be prompted)"

  if ! scp -q -i "$SSH_KEY_PATH" \
         -o StrictHostKeyChecking=accept-new \
         "$PREP_SCRIPT" "$WORKER_USER@$addr:$rscript"; then
    err "scp prep-worker-incus.sh to $addr failed"
    return 1
  fi
  if ! scp -q -i "$SSH_KEY_PATH" \
         -o StrictHostKeyChecking=accept-new \
         "$PRESEED" "$WORKER_USER@$addr:$rpreseed"; then
    err "scp preseed-worker.yaml to $addr failed"
    return 1
  fi

  ssh -t -i "$SSH_KEY_PATH" \
      -o StrictHostKeyChecking=accept-new \
      "$WORKER_USER@$addr" \
      "sudo bash $rscript $rpreseed; rc=\$?; rm -f $rscript $rpreseed; exit \$rc"
}

# ============================================================================
# Main
# ============================================================================
mapfile -t LINES <<< "$WORKERS_INCUS"

if [ -n "$ONLY_NODE" ]; then
  matched=0
  for entry in "${LINES[@]}"; do
    [ -n "$entry" ] || continue
    IFS='=' read -r wname waddr <<< "$entry"
    if [ "$wname" = "$ONLY_NODE" ]; then
      matched=1
      if ! run_install_incus "$wname" "$waddr"; then
        err "$wname failed — aborting"
        exit 1
      fi
      ok "$wname install complete"
      break
    fi
  done
  if [ "$matched" = 0 ]; then
    err "Node '$ONLY_NODE' not in target list. Valid: $(echo "$WORKERS_INCUS" | cut -d= -f1 | tr '\n' ' ')"
    exit 2
  fi
else
  note "About to install Incus on ${#LINES[@]} worker(s); sudo password may be prompted once per worker."
  for entry in "${LINES[@]}"; do
    [ -n "$entry" ] || continue
    IFS='=' read -r wname waddr <<< "$entry"
    if ! run_install_incus "$wname" "$waddr"; then
      err "$wname failed — aborting (already-installed workers are unaffected)"
      exit 1
    fi
    ok "$wname install complete"
  done
fi

banner "All Incus installs done"
echo "Next:"
echo "  - Verify per node: ssh c4@<addr> 'incus version && ss -tln | grep :8443'"
echo "  - Web UI per node: https://<addr>:8443"
echo "  - Re-bootstrap k3s (if a node was reflashed) from $(dirname "$SCRIPT_DIR"):"
echo "      terraform apply \\"
echo "        -replace='null_resource.bootstrap_worker[\"rdxa1\"]' \\"
echo "        -replace='null_resource.bootstrap_worker[\"rdxa2\"]' \\"
echo "        -replace='null_resource.bootstrap_worker[\"rdxa3\"]' \\"
echo "        -replace='null_resource.bootstrap_worker[\"rdxa4\"]'"
