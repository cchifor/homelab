#!/usr/bin/env bash
# Refresh the claude-oauth Kubernetes Secret from the workstation's local
# `.credentials.json`. Useful when scheduled runs start failing with
# `API Error: 401 Invalid authentication credentials` — the workstation's
# OAuth token rotates (~30 min cycle as the interactive `claude` session
# refreshes), and the Secret in the cluster grows stale.
#
# Long-term fix is one of:
#   (a) install `claude` properly on the claude-worker VM, run `claude login`
#       as the claude-agent user once, and source the credential from there
#       (the original plan's design);
#   (b) switch the cluster runner to an Anthropic API key (set ANTHROPIC_API_KEY
#       in the runner image / values; no OAuth rotation);
#   (c) cron this script on the workstation as a stopgap.
set -euo pipefail

NAMESPACE=${NAMESPACE:-claude-agent}
SECRET_NAME=${SECRET_NAME:-claude-oauth}

# Default credential path. Override CREDENTIAL=... to use a different file.
default_cred() {
  if [[ -n "${USERPROFILE:-}" && -f "${USERPROFILE}/.claude/.credentials.json" ]]; then
    # Windows / Git Bash
    echo "${USERPROFILE}/.claude/.credentials.json"
  elif [[ -f "${HOME}/.claude/.credentials.json" ]]; then
    # POSIX
    echo "${HOME}/.claude/.credentials.json"
  else
    return 1
  fi
}
CREDENTIAL=${CREDENTIAL:-$(default_cred)} || {
  echo "no .credentials.json found; set CREDENTIAL=/path/to/file" >&2
  exit 1
}

[[ -r "$CREDENTIAL" ]] || { echo "cannot read $CREDENTIAL" >&2; exit 1; }
size=$(wc -c < "$CREDENTIAL")
(( size > 100 )) || { echo "$CREDENTIAL is suspiciously small ($size bytes) — looks empty; aborting" >&2; exit 1; }

echo "Source: $CREDENTIAL ($size bytes, mtime $(date -r "$CREDENTIAL" '+%F %T'))"
echo "Target: secret/$SECRET_NAME in namespace/$NAMESPACE"
kubectl -n "$NAMESPACE" create secret generic "$SECRET_NAME" \
  --from-file=credentials.json="$CREDENTIAL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo
echo "Done. The next scheduled CronJob fire (or manual trigger) will use the refreshed token."
echo "If you have a Failed job lingering, delete it:"
echo "  kubectl -n $NAMESPACE delete job -l homelab.chifor/job-name=longhorn-health,batch.kubernetes.io/job-name!=longhorn-health-manual --field-selector status.successful=0"
