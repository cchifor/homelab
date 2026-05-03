#!/usr/bin/env bash
# scripts/merge-kubeconfig.sh
#
# Idempotent: takes the project's freshly-generated ./kubeconfig (from
# check-prereqs.sh), renames its default context to a friendlier name, and
# merges it into ~/.kube/config — preserving any other clusters you already
# have configured (GKE, EKS, other on-prem clusters, etc.).
#
# Re-run this any time check-prereqs.sh regenerates the project kubeconfig
# (e.g. after the k3s server is rebuilt and gets fresh certs/tokens).
#
# Usage:
#   bash scripts/merge-kubeconfig.sh             # uses ./kubeconfig, context=home-lab
#   bash scripts/merge-kubeconfig.sh ./kubeconfig my-cluster
#
# After this, plain `kubectl ...` works from any directory; switch contexts
# with `kubectl config use-context <name>`.

set -euo pipefail

SRC="${1:-./kubeconfig}"
NAME="${2:-home-lab}"

[ -f "$SRC" ] || {
  echo "ERROR: $SRC not found. Run scripts/check-prereqs.sh first to generate it." >&2
  exit 1
}

# Rename default → $NAME in a temp copy (don't mutate the source).
TMP=$(mktemp)
cp "$SRC" "$TMP"
sed -i \
  -e "s/name: default/name: $NAME/g" \
  -e "s/cluster: default/cluster: $NAME/g" \
  -e "s/user: default/user: $NAME/g" \
  -e "s/current-context: default/current-context: $NAME/g" \
  "$TMP"

# Backup existing ~/.kube/config (timestamped, preserved indefinitely).
mkdir -p "$HOME/.kube"
if [ -f "$HOME/.kube/config" ]; then
  BAK="$HOME/.kube/config.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$HOME/.kube/config" "$BAK"
  echo "Backed up existing kubeconfig to $BAK"
fi

# Merge. KUBECONFIG=path1:path2 + `config view --merge --flatten` is the
# standard way to combine kubeconfigs without losing data.
KUBECONFIG="$HOME/.kube/config:$TMP" kubectl config view --merge --flatten \
  > "$HOME/.kube/config.new"
mv "$HOME/.kube/config.new" "$HOME/.kube/config"
chmod 600 "$HOME/.kube/config" 2>/dev/null || true
rm -f "$TMP"

# Switch to it.
kubectl config use-context "$NAME"
echo
echo "Available contexts:"
kubectl config get-contexts
