#!/usr/bin/env bash
# Preflight check for the claude-jobs Helm chart.
#
# Run from the homelab repo root, with kubectl + helm on PATH and a kubeconfig
# pointed at the k3s cluster. Exits 0 iff every check passes; non-zero on the
# first failure with the offending check highlighted.
#
# Useful before `helm install` to catch missing prerequisites (Tasks 7–10 in
# docs/superpowers/plans/2026-05-12-claude-radxa-jobs.md).
set -euo pipefail

NAMESPACE=${NAMESPACE:-claude-agent}
CHART_DIR=${CHART_DIR:-apps/charts/claude-jobs}
PILOT_VALUES=${PILOT_VALUES:-$CHART_DIR/values-longhorn-health.yaml}
NODE_LABEL=${NODE_LABEL:-homelab.chifor/role=claude-worker}
EXPECTED_NODES=${EXPECTED_NODES:-4}

green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }

check() {
  local name=$1; shift
  printf '  %-55s' "$name"
  if "$@" >/dev/null 2>&1; then green "PASS"; else red "FAIL"; exit 1; fi
}

echo "claude-jobs preflight"
echo
echo "Tools on PATH:"
check "helm"    command -v helm
check "kubectl" command -v kubectl

echo "Cluster reachable:"
check "kubectl can reach cluster" kubectl cluster-info

echo "Namespace + RBAC (created by platform module):"
check "ns/$NAMESPACE"      kubectl get ns "$NAMESPACE"
check "sa/claude-agent-ro" kubectl -n "$NAMESPACE" get sa claude-agent-ro
check "sa/claude-agent-rw" kubectl -n "$NAMESPACE" get sa claude-agent-rw

echo "OAuth Secret (Task 9):"
check "secret/claude-oauth" kubectl -n "$NAMESPACE" get secret claude-oauth

echo "Node labels (Task 7):"
count=$(kubectl get nodes -l "$NODE_LABEL" --no-headers 2>/dev/null | wc -l || echo 0)
printf '  %-55s' "≥$EXPECTED_NODES nodes labeled $NODE_LABEL"
if [[ "$count" -ge "$EXPECTED_NODES" ]]; then
  green "PASS ($count)"
else
  red "FAIL ($count)"
  exit 1
fi

echo "Chart renders:"
check "helm template longhorn-health (pilot)" \
  helm template longhorn-health "$CHART_DIR" -f "$PILOT_VALUES"

echo
green "all checks passed — ready for:"
echo "    helm install longhorn-health $CHART_DIR -n $NAMESPACE -f $PILOT_VALUES"
