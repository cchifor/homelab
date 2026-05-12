# claude-jobs

Helm chart that installs one headless Claude Code job (a `CronJob` + its
ConfigMaps + PVC) per release. Designed for the Radxa arm64 k3s workers.

The image is built from `containers/claude-runner/` and runs each scheduled
invocation as UID 1000 with a tight allowed-tools list and a baseline-settings
deny-list for Docker.

Full design and operator runbook: `docs/superpowers/plans/2026-05-12-claude-radxa-jobs.md`.

## Prerequisites (one-time, before first install)

1. **Namespace + RBAC** — `claude-agent` namespace with `claude-agent-ro` and
   `claude-agent-rw` ServiceAccounts. Bootstrapped by the platform module
   (`platform/files/k8s/claude-agent-rbac.yaml.tftpl`); verify with
   `kubectl -n claude-agent get sa`.
2. **OAuth Secret** — copy the credential from the claude-worker VM:
   ```bash
   ssh c4@<claude-worker-vm-ip> "sudo cat /home/claude-agent/.claude/.credentials.json" \
     | kubectl -n claude-agent create secret generic claude-oauth \
         --from-file=credentials.json=/dev/stdin
   ```
3. **Node labels** — label the Radxa nodes:
   ```bash
   kubectl label node <radxa-node> homelab.chifor/role=claude-worker
   ```
4. **Image** — build and push from `containers/claude-runner/`:
   ```bash
   ./containers/claude-runner/build.sh   # multi-arch, run on the VM
   ```

## OAuth credential rotation (current workaround)

The OAuth token in `secret/claude-oauth` is the workstation's `.credentials.json`.
Anthropic rotates that token roughly every 30 minutes whenever the interactive
`claude` session is in use — so the Secret goes stale and the next scheduled
run fails with `API Error: 401 Invalid authentication credentials`.

Stopgap: refresh the Secret from the current local credential.

```bash
./apps/charts/claude-jobs/refresh-secret.sh
```

A long-term fix replaces the workstation-sourced credential with one of:
- A dedicated `claude login` on the claude-worker VM (the original plan's design;
  requires installing `claude` on the VM first — currently not installed).
- An Anthropic API key set as `ANTHROPIC_API_KEY` env var in the runner image
  (no OAuth rotation, different billing model).
- A workstation `cron` / Windows scheduled task that runs `refresh-secret.sh`
  every 15-20 minutes.

## Preflight check

Before the first `helm install`, run the preflight script to verify all
prerequisites are in place (tools on PATH, cluster reachable, namespace +
ServiceAccounts present, OAuth Secret created, ≥4 nodes labeled, chart renders):

```bash
./apps/charts/claude-jobs/preflight.sh
```

Override checks with env vars if needed: `NAMESPACE=...`, `NODE_LABEL=...`,
`EXPECTED_NODES=...`, `CHART_DIR=...`, `PILOT_VALUES=...`. Exits non-zero on
the first failure with the offending check highlighted.

## Installing a job

Each job is a separate Helm release with its own values file. Pilot:

```bash
helm install longhorn-health apps/charts/claude-jobs \
  -n claude-agent \
  -f apps/charts/claude-jobs/values-longhorn-health.yaml
```

The chart hardcodes `metadata.namespace: {{ .Values.namespace }}` in every
template, so the `-n` flag is decorative for resource placement but still
required by Helm for release tracking. Override `namespace` in values if you
truly need a different namespace.

## Triggering and observing

```bash
# Manually trigger the next scheduled run:
kubectl -n claude-agent create job longhorn-health-manual \
  --from=cronjob/claude-job-longhorn-health

# Watch:
kubectl -n claude-agent get pods -l job-name=longhorn-health-manual -w

# Read transcript:
kubectl -n claude-agent logs -l job-name=longhorn-health-manual --tail=-1
```

The `/workspace` PVC retains `runs/<UTC-ts>/transcript.jsonl` for each invocation
of every job.

## Uninstalling

```bash
helm uninstall longhorn-health -n claude-agent
```

**`helm uninstall` also deletes the workspace PVC.** If you want to keep the
history, copy it out first:
```bash
kubectl -n claude-agent cp <pod>:/workspace/runs/ ./runs-backup/
```

## Required values

Every release MUST set:
- `job.name` — short slug used in resource names (`claude-job-<name>`)
- `job.schedule` — cron expression
- `job.prompt` — multi-line string
- `job.allowedTools` — comma-separated or one-per-line; the entrypoint
  normalises both into a single comma-separated value for `claude --allowed-tools`

See `values-longhorn-health.yaml` as a working example.
