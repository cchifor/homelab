# Claude Code Headless Jobs on Radxa k3s Workers — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Offload pure-Claude (no-Docker) headless agent jobs from the `claude-worker` VM onto the 4× arm64 Radxa k3s nodes, freeing the VM for interactive use. Pilot end-to-end with one job (`longhorn-health`) and a reusable Helm chart so subsequent jobs are a per-job values file.

**Architecture:**
- The Radxa nodes already run k3s as workers. Each headless job becomes a `CronJob` in the existing `claude-agent` namespace, scheduled to arm64 nodes via `nodeSelector`. The pod runs a `claude-runner` container — a multi-arch image (`linux/amd64,linux/arm64`) bundling the `claude` CLI plus dev tooling minus Docker. OAuth credential is mounted from a Secret copied one-time from the VM. Each job gets its own Longhorn PVC for `/workspace`. K8s API access reuses the existing `claude-agent-ro`/`claude-agent-rw` ServiceAccounts — no kubeconfigs on disk.
- Sysbox-in-pod is explicitly **not** used (broken upstream on k3s+containerd as of 2026-05; see issues nestybox/sysbox#1006 and k3s-io/k3s#13709). Docker-needing jobs stay on the VM as systemd timers, untouched.
- Defense-in-depth against Docker drift: (a) Docker CLI is not installed in the runner image, (b) baseline `settings.json` ConfigMap denies `Bash(docker:*)` and friends cluster-wide.

**Tech Stack:** k3s v1.30+ (existing), Helm 3, Docker buildx with QEMU (multi-arch), Longhorn (existing), Gitea container registry at `gitea.chifor.dev`, the existing `claude-agent-ro`/`-rw` RBAC.

**Out of scope (separate plan or follow-up):**
- Docker-needing jobs (stay on VM via existing `claude-job@<name>.timer` systemd units, unchanged).
- Migration of all existing VM timers — this plan migrates ONLY the `longhorn-health` pilot. A follow-up plan handles the rest after the pilot is green for ≥2 weeks.
- Backup of per-job PVCs (`longhorn-health` is read-only and stateless; defer Velero/restic until a job with persistent state lands).
- Remote-Docker daemon pattern (explicitly declined by user).
- Per-credential OAuth concurrency hardening (single shared token for v1; revisit if Anthropic enforces a cap).

---

## File Structure

**New files:**
- `containers/claude-runner/Dockerfile` — multi-arch runner image
- `containers/claude-runner/claude-run-pod` — entrypoint wrapper around `claude -p`
- `containers/claude-runner/build.sh` — multi-arch buildx helper (runs on the VM)
- `containers/claude-runner/README.md` — short build/push instructions
- `apps/charts/claude-jobs/Chart.yaml`
- `apps/charts/claude-jobs/values.yaml` — defaults shared by all jobs
- `apps/charts/claude-jobs/templates/_helpers.tpl`
- `apps/charts/claude-jobs/templates/configmap-job.yaml` — per-job prompt/allowed-tools/env
- `apps/charts/claude-jobs/templates/configmap-baseline-settings.yaml` — Docker deny-list
- `apps/charts/claude-jobs/templates/pvc.yaml`
- `apps/charts/claude-jobs/templates/cronjob.yaml`
- `apps/charts/claude-jobs/values-longhorn-health.yaml` — pilot job values
- `docs/superpowers/plans/2026-05-12-claude-radxa-jobs.md` — this file

**Manual/imperative artifacts (not committed):**
- `claude-oauth` Secret in `claude-agent` namespace (contains the OAuth bearer; copied from the VM)
- Node labels `homelab.chifor/role=claude-worker` on the 4 Radxa nodes

---

## Phase 1: Multi-arch runner image

### Task 1: Write the Dockerfile

**Files:**
- Create: `containers/claude-runner/Dockerfile`

- [ ] **Step 1: Write the Dockerfile**

```dockerfile
# syntax=docker/dockerfile:1.7
FROM debian:12-slim

ARG TARGETARCH
ENV DEBIAN_FRONTEND=noninteractive \
    PATH=/usr/local/bin:/usr/local/sbin:/usr/bin:/usr/sbin:/bin:/sbin \
    NODE_VERSION=20.18.0 \
    KUBECTL_VERSION=v1.30.5 \
    HELM_VERSION=v3.16.2 \
    HOME=/home/claude-agent

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git gnupg jq tini procps \
      python3 python3-pip python3-venv \
      tmux less vim-tiny \
      restic \
    && rm -rf /var/lib/apt/lists/*

# Node.js (needed for `claude` CLI which is npm-distributed)
RUN curl -fsSL https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${TARGETARCH/amd64/x64}.tar.xz \
        -o /tmp/node.tar.xz \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 \
    && rm /tmp/node.tar.xz \
    && node --version && npm --version

# kubectl
RUN curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
        -o /usr/local/bin/kubectl \
    && chmod 0755 /usr/local/bin/kubectl \
    && kubectl version --client=true

# Helm
RUN curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" \
        -o /tmp/helm.tgz \
    && tar -xzf /tmp/helm.tgz -C /tmp \
    && mv /tmp/linux-${TARGETARCH}/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tgz /tmp/linux-${TARGETARCH} \
    && helm version

# gh CLI
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# yq (binary)
RUN curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${TARGETARCH}" \
        -o /usr/local/bin/yq \
    && chmod 0755 /usr/local/bin/yq

# Claude Code CLI
RUN npm install -g @anthropic-ai/claude-code \
    && claude --version

# Non-root user (uid 1000) matches the VM's claude-agent
RUN groupadd -g 1000 claude-agent \
    && useradd -m -u 1000 -g 1000 -s /bin/bash claude-agent \
    && mkdir -p /workspace /jobs \
    && chown -R claude-agent:claude-agent /workspace /home/claude-agent

COPY claude-run-pod /usr/local/bin/claude-run-pod
RUN chmod 0755 /usr/local/bin/claude-run-pod

USER claude-agent
WORKDIR /workspace
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/claude-run-pod"]
```

- [ ] **Step 2: Commit**

```bash
git add containers/claude-runner/Dockerfile
git commit -m "containers/claude-runner: initial Dockerfile (debian:12 + claude + dev tools, no Docker)"
```

### Task 2: Write the claude-run-pod entrypoint

**Files:**
- Create: `containers/claude-runner/claude-run-pod`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# claude-run-pod — invoked by the CronJob's container entrypoint.
# Reads /jobs/{prompt.md,allowed-tools.txt,job.env}, runs claude -p,
# tees output into /workspace/runs/<ts>/transcript.log.
set -euo pipefail

JOBS_DIR=${JOBS_DIR:-/jobs}
WORKSPACE=${WORKSPACE:-/workspace}

[[ -f "$JOBS_DIR/prompt.md" ]]        || { echo "missing $JOBS_DIR/prompt.md" >&2; exit 2; }
[[ -f "$JOBS_DIR/allowed-tools.txt" ]] || { echo "missing $JOBS_DIR/allowed-tools.txt" >&2; exit 2; }

if [[ -f "$JOBS_DIR/job.env" ]]; then
  set -a; . "$JOBS_DIR/job.env"; set +a
fi

ALLOWED_TOOLS=$(tr -d '\n' < "$JOBS_DIR/allowed-tools.txt")
PROMPT=$(cat "$JOBS_DIR/prompt.md")

TS=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="$WORKSPACE/runs/$TS"
mkdir -p "$RUN_DIR"

# Symlink credential into HOME if mounted at the canonical path.
# (Kubernetes secret-as-file mounts can't write to ~/.claude directly.)
mkdir -p "$HOME/.claude"
if [[ -f /var/run/claude/credentials.json && ! -e "$HOME/.claude/.credentials.json" ]]; then
  ln -sf /var/run/claude/credentials.json "$HOME/.claude/.credentials.json"
fi

echo "[claude-run-pod] starting job, output -> $RUN_DIR" | tee "$RUN_DIR/meta.log"
{
  echo "started: $TS"
  echo "allowed-tools: $ALLOWED_TOOLS"
  echo "node: ${NODE_NAME:-unknown}"
} >> "$RUN_DIR/meta.log"

exec claude -p "$PROMPT" \
  --allowed-tools "$ALLOWED_TOOLS" \
  --output-format stream-json \
  2> >(tee -a "$RUN_DIR/stderr.log" >&2) \
  | tee "$RUN_DIR/transcript.jsonl"
```

- [ ] **Step 2: Commit**

```bash
git add containers/claude-runner/claude-run-pod
git commit -m "containers/claude-runner: claude-run-pod entrypoint"
```

### Task 3: Write the build helper script

**Files:**
- Create: `containers/claude-runner/build.sh`

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Run this on the claude-worker VM. Requires: docker, qemu-user-static, buildx.
# Pushes a multi-arch image to gitea.chifor.dev/c4/claude-runner.
set -euo pipefail

REGISTRY=${REGISTRY:-gitea.chifor.dev}
NAMESPACE=${NAMESPACE:-c4}
IMAGE=${IMAGE:-claude-runner}
TAG=${TAG:-$(date -u +%Y%m%d)-$(git rev-parse --short HEAD)}

cd "$(dirname "$0")"

docker buildx create --use --name claude-runner-builder 2>/dev/null || \
  docker buildx use claude-runner-builder

docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --tag "${REGISTRY}/${NAMESPACE}/${IMAGE}:${TAG}" \
  --tag "${REGISTRY}/${NAMESPACE}/${IMAGE}:latest" \
  --push \
  .

echo
echo "Pushed: ${REGISTRY}/${NAMESPACE}/${IMAGE}:${TAG}"
echo "Pushed: ${REGISTRY}/${NAMESPACE}/${IMAGE}:latest"
```

- [ ] **Step 2: Commit**

```bash
git add containers/claude-runner/build.sh
git commit -m "containers/claude-runner: multi-arch build script"
```

### Task 4: Write the container README

**Files:**
- Create: `containers/claude-runner/README.md`

- [ ] **Step 1: Write README**

```markdown
# claude-runner

Multi-arch container image for running headless Claude Code jobs as k3s
CronJobs on the Radxa arm64 nodes. Bundles `claude`, `git`, `gh`, `kubectl`,
`helm`, `node`, `python3`, `jq`, `yq`, `restic`, `tmux`. **Does not include
Docker by design** — Docker-needing jobs run on the claude-worker VM
via systemd timers.

## Build & push

Run on the claude-worker VM (amd64 host with Docker + qemu-user-static):

```bash
sudo apt install -y qemu-user-static binfmt-support  # one-time
docker login gitea.chifor.dev                         # one-time
./build.sh
```

This produces `gitea.chifor.dev/c4/claude-runner:<date>-<sha>` and `:latest`,
multi-arch (`linux/amd64,linux/arm64`).

## Entrypoint

`/usr/local/bin/claude-run-pod` reads:
- `/jobs/prompt.md`         — the prompt
- `/jobs/allowed-tools.txt` — comma-separated tool allow-list
- `/jobs/job.env`           — optional env vars

…and writes transcripts to `/workspace/runs/<UTC-ts>/`.

OAuth credential is expected at `/var/run/claude/credentials.json`
(mounted from the `claude-oauth` Secret); the entrypoint symlinks it to
`~/.claude/.credentials.json`.
```

- [ ] **Step 2: Commit**

```bash
git add containers/claude-runner/README.md
git commit -m "containers/claude-runner: README"
```

### Task 5: Build amd64-only first and verify the entrypoint works

This is a smoke test before the multi-arch build, because the cross-build is slow.

- [ ] **Step 1: SSH to the claude-worker VM and ensure prerequisites**

Run on the VM:

```bash
sudo apt-get update && sudo apt-get install -y qemu-user-static binfmt-support
docker buildx version
```

Expected: buildx version printed; no errors.

- [ ] **Step 2: Build amd64 image locally (no push)**

Run on the VM, in the cloned repo:

```bash
cd containers/claude-runner
docker buildx build --platform linux/amd64 --tag claude-runner:smoke --load .
```

Expected: build completes; `docker images | grep claude-runner` shows the image.

- [ ] **Step 3: Smoke-test the image**

```bash
docker run --rm --entrypoint claude claude-runner:smoke --version
docker run --rm --entrypoint kubectl claude-runner:smoke version --client=true
docker run --rm --entrypoint helm claude-runner:smoke version
```

Expected: each prints a version, exit 0.

- [ ] **Step 4: Smoke-test the entrypoint with a fake jobs dir**

```bash
mkdir -p /tmp/fake-jobs
echo "Print the word PONG and exit." > /tmp/fake-jobs/prompt.md
echo "Read"                          > /tmp/fake-jobs/allowed-tools.txt
mkdir -p /tmp/fake-ws

# Fail-mode check: no credential mounted, should fail with an auth error.
docker run --rm \
  -v /tmp/fake-jobs:/jobs:ro \
  -v /tmp/fake-ws:/workspace \
  claude-runner:smoke || echo "expected failure: no credential"
```

Expected: claude prints an auth error (no credential mounted). The `meta.log` should be in `/tmp/fake-ws/runs/<ts>/`.

### Task 6: Build and push multi-arch

- [ ] **Step 1: docker login**

Run on the VM:

```bash
docker login gitea.chifor.dev
```

Expected: "Login Succeeded".

- [ ] **Step 2: Run build.sh**

```bash
cd containers/claude-runner
./build.sh
```

Expected: build completes for both amd64 and arm64; final lines show two pushed tags.

- [ ] **Step 3: Verify pull on a Radxa node**

From the Windows workstation:

```bash
ssh c4@192.168.0.174 'sudo k3s ctr images pull gitea.chifor.dev/c4/claude-runner:latest'
```

Expected: digest printed, exit 0. If gitea registry requires auth, configure `/etc/rancher/k3s/registries.yaml` on each Radxa node first (out of scope here — note as a prerequisite if it fails).

---

## Phase 2: Cluster prerequisites

### Task 7: Label Radxa nodes for explicit scheduling

This lets us pin CronJobs with `nodeSelector` independent of architecture — robust if a non-Radxa arm64 node is added later.

- [ ] **Step 1: Verify current node labels**

```bash
kubectl get nodes -L kubernetes.io/arch
```

Expected: 4 arm64 nodes (the Radxas) + the amd64 server VM.

- [ ] **Step 2: Apply role label to each Radxa**

```bash
for ip in 192.168.0.174 192.168.0.200 192.168.0.129 192.168.1.167; do
  node=$(kubectl get nodes -o jsonpath="{.items[?(@.status.addresses[?(@.address=='$ip')])].metadata.name}")
  kubectl label node "$node" homelab.chifor/role=claude-worker --overwrite
done
```

- [ ] **Step 3: Verify**

```bash
kubectl get nodes -l homelab.chifor/role=claude-worker
```

Expected: 4 nodes listed; the server VM is NOT listed.

### Task 8: Confirm the claude-agent namespace and ServiceAccounts already exist

The `claude-agent-ro` and `claude-agent-rw` ServiceAccounts are created by the existing platform/files/k8s/claude-agent-rbac.yaml.tftpl applied during the VM bootstrap. Verify rather than recreate.

- [ ] **Step 1: Verify**

```bash
kubectl get ns claude-agent
kubectl -n claude-agent get sa claude-agent-ro claude-agent-rw
```

Expected: namespace exists, both SAs exist.

- [ ] **Step 2: If missing, apply rbac.yaml from the platform**

```bash
# Only if step 1 showed NotFound:
kubectl apply -f /path/to/rendered/claude-agent-rbac.yaml
```

### Task 9: Create the claude-oauth Secret from the VM credential

The OAuth bearer is reused as-is — same credential currently on the VM. If Anthropic enforces a per-credential concurrency cap, this becomes a follow-up task (issue new logins per Radxa).

- [ ] **Step 1: Fetch the credential from the VM**

From the Windows workstation:

```bash
ssh c4@<claude-worker-vm-ip> "sudo cat /home/claude-agent/.claude/.credentials.json" > /tmp/credentials.json
```

Expected: a JSON file ~1-4 KiB containing an OAuth token.

- [ ] **Step 2: Create the Secret**

```bash
kubectl -n claude-agent create secret generic claude-oauth \
  --from-file=credentials.json=/tmp/credentials.json \
  --dry-run=client -o yaml | kubectl apply -f -
rm /tmp/credentials.json
```

Expected: `secret/claude-oauth created` or `configured`.

- [ ] **Step 3: Verify**

```bash
kubectl -n claude-agent get secret claude-oauth -o jsonpath='{.data.credentials\.json}' | wc -c
```

Expected: non-zero (base64-encoded size), should be roughly 4/3 the original byte size.

### Task 10: Smoke-test image pull + credential mount with `kubectl run`

Verify the image is pullable, the Secret mounts where the entrypoint expects, and `claude --version` exits 0 inside a pod.

- [ ] **Step 1: Write a one-shot Pod spec**

Create `/tmp/claude-smoke.yaml`:

```yaml
apiVersion: v1
kind: Pod
metadata: { name: claude-smoke, namespace: claude-agent }
spec:
  restartPolicy: Never
  serviceAccountName: claude-agent-ro
  nodeSelector: { homelab.chifor/role: claude-worker }
  containers:
    - name: claude
      image: gitea.chifor.dev/c4/claude-runner:latest
      command: ["claude", "--version"]
      volumeMounts:
        - { name: oauth, mountPath: /var/run/claude, readOnly: true }
  volumes:
    - name: oauth
      secret:
        secretName: claude-oauth
        defaultMode: 0400
```

- [ ] **Step 2: Apply and check logs**

```bash
kubectl apply -f /tmp/claude-smoke.yaml
kubectl -n claude-agent wait --for=condition=Ready pod/claude-smoke --timeout=120s || \
  kubectl -n claude-agent get pod claude-smoke -o wide
kubectl -n claude-agent logs claude-smoke
kubectl -n claude-agent delete pod claude-smoke
```

Expected: pod scheduled on a Radxa node (`NODE` column), logs print the claude CLI version, pod terminates with status `Completed`.

---

## Phase 3: Helm chart for claude-jobs

### Task 11: Chart skeleton

**Files:**
- Create: `apps/charts/claude-jobs/Chart.yaml`
- Create: `apps/charts/claude-jobs/values.yaml`

- [ ] **Step 1: Chart.yaml**

```yaml
apiVersion: v2
name: claude-jobs
description: Headless Claude Code jobs scheduled onto Radxa arm64 k3s workers
type: application
version: 0.1.0
appVersion: "0.1.0"
```

- [ ] **Step 2: values.yaml (defaults shared by every job instance)**

```yaml
# Defaults. Each job is installed as its own release with a values file
# overriding `job.name`, `job.schedule`, `job.prompt`, `job.allowedTools`,
# and optionally `serviceAccount` (default: ro).

image:
  repository: gitea.chifor.dev/c4/claude-runner
  tag: latest
  pullPolicy: IfNotPresent

namespace: claude-agent
serviceAccount: claude-agent-ro      # override to claude-agent-rw for mutating jobs

nodeSelector:
  homelab.chifor/role: claude-worker

tolerations: []
affinity: {}

storage:
  storageClass: longhorn
  size: 5Gi

oauth:
  secretName: claude-oauth
  keyName: credentials.json

# Baseline settings.json content (deny-list). Rendered into its own
# ConfigMap and mounted at /home/claude-agent/.claude/settings.json.
baselineSettings:
  permissions:
    deny:
      - "Bash(docker:*)"
      - "Bash(docker-compose:*)"
      - "Bash(docker compose:*)"
      - "Bash(podman:*)"
      - "Bash(nerdctl:*)"
      - "Bash(ctr:*)"

job:
  name: ""                # REQUIRED — per-values
  schedule: ""            # REQUIRED — cron, e.g. "17 */6 * * *"
  prompt: ""              # REQUIRED — multi-line string
  allowedTools: ""        # REQUIRED — comma-separated, e.g. "Read,Grep,Bash(kubectl get:*)"
  env: {}                 # optional key=value pairs piped into /jobs/job.env
  activeDeadlineSeconds: 1800
  concurrencyPolicy: Forbid
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 5
  backoffLimit: 0
  maxTurns: 30
```

- [ ] **Step 3: Commit**

```bash
git add apps/charts/claude-jobs/Chart.yaml apps/charts/claude-jobs/values.yaml
git commit -m "apps/charts/claude-jobs: chart skeleton + values defaults"
```

### Task 12: _helpers.tpl

**Files:**
- Create: `apps/charts/claude-jobs/templates/_helpers.tpl`

- [ ] **Step 1: Write helpers**

```yaml
{{/* Validate that required fields are set. */}}
{{- define "claude-jobs.validate" -}}
{{- if not .Values.job.name -}}{{ fail "job.name is required" }}{{- end -}}
{{- if not .Values.job.schedule -}}{{ fail "job.schedule is required" }}{{- end -}}
{{- if not .Values.job.prompt -}}{{ fail "job.prompt is required" }}{{- end -}}
{{- if not .Values.job.allowedTools -}}{{ fail "job.allowedTools is required" }}{{- end -}}
{{- end -}}

{{- define "claude-jobs.fullname" -}}
claude-job-{{ .Values.job.name }}
{{- end -}}

{{- define "claude-jobs.labels" -}}
app.kubernetes.io/name: claude-jobs
app.kubernetes.io/instance: {{ include "claude-jobs.fullname" . }}
app.kubernetes.io/component: claude-job
homelab.chifor/job-name: {{ .Values.job.name }}
{{- end -}}
```

- [ ] **Step 2: Commit**

```bash
git add apps/charts/claude-jobs/templates/_helpers.tpl
git commit -m "apps/charts/claude-jobs: helpers"
```

### Task 13: ConfigMap templates (per-job + baseline settings)

**Files:**
- Create: `apps/charts/claude-jobs/templates/configmap-job.yaml`
- Create: `apps/charts/claude-jobs/templates/configmap-baseline-settings.yaml`

- [ ] **Step 1: configmap-job.yaml**

```yaml
{{- include "claude-jobs.validate" . }}
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "claude-jobs.fullname" . }}
  namespace: {{ .Values.namespace }}
  labels: {{- include "claude-jobs.labels" . | nindent 4 }}
data:
  prompt.md: |-
{{ .Values.job.prompt | indent 4 }}
  allowed-tools.txt: |-
    {{ .Values.job.allowedTools }}
  job.env: |-
    CLAUDE_MAX_TURNS={{ .Values.job.maxTurns }}
{{- range $k, $v := .Values.job.env }}
    {{ $k }}={{ $v }}
{{- end }}
```

- [ ] **Step 2: configmap-baseline-settings.yaml**

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ include "claude-jobs.fullname" . }}-settings
  namespace: {{ .Values.namespace }}
  labels: {{- include "claude-jobs.labels" . | nindent 4 }}
data:
  settings.json: |-
{{ .Values.baselineSettings | toJson | indent 4 }}
```

- [ ] **Step 3: Commit**

```bash
git add apps/charts/claude-jobs/templates/configmap-job.yaml \
        apps/charts/claude-jobs/templates/configmap-baseline-settings.yaml
git commit -m "apps/charts/claude-jobs: ConfigMaps for per-job + baseline settings"
```

### Task 14: PVC template

**Files:**
- Create: `apps/charts/claude-jobs/templates/pvc.yaml`

- [ ] **Step 1: Write the PVC**

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: {{ include "claude-jobs.fullname" . }}-workspace
  namespace: {{ .Values.namespace }}
  labels: {{- include "claude-jobs.labels" . | nindent 4 }}
spec:
  accessModes: ["ReadWriteOnce"]
  storageClassName: {{ .Values.storage.storageClass }}
  resources:
    requests:
      storage: {{ .Values.storage.size }}
```

- [ ] **Step 2: Commit**

```bash
git add apps/charts/claude-jobs/templates/pvc.yaml
git commit -m "apps/charts/claude-jobs: PVC template (Longhorn-backed)"
```

### Task 15: CronJob template

**Files:**
- Create: `apps/charts/claude-jobs/templates/cronjob.yaml`

- [ ] **Step 1: Write the CronJob**

```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: {{ include "claude-jobs.fullname" . }}
  namespace: {{ .Values.namespace }}
  labels: {{- include "claude-jobs.labels" . | nindent 4 }}
spec:
  schedule: "{{ .Values.job.schedule }}"
  concurrencyPolicy: {{ .Values.job.concurrencyPolicy }}
  successfulJobsHistoryLimit: {{ .Values.job.successfulJobsHistoryLimit }}
  failedJobsHistoryLimit: {{ .Values.job.failedJobsHistoryLimit }}
  jobTemplate:
    spec:
      backoffLimit: {{ .Values.job.backoffLimit }}
      activeDeadlineSeconds: {{ .Values.job.activeDeadlineSeconds }}
      template:
        metadata:
          labels: {{- include "claude-jobs.labels" . | nindent 12 }}
        spec:
          serviceAccountName: {{ .Values.serviceAccount }}
          restartPolicy: Never
          nodeSelector:
            {{- toYaml .Values.nodeSelector | nindent 12 }}
          {{- with .Values.tolerations }}
          tolerations: {{- toYaml . | nindent 12 }}
          {{- end }}
          {{- with .Values.affinity }}
          affinity: {{- toYaml . | nindent 12 }}
          {{- end }}
          containers:
            - name: claude
              image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
              imagePullPolicy: {{ .Values.image.pullPolicy }}
              env:
                - name: NODE_NAME
                  valueFrom:
                    fieldRef: { fieldPath: spec.nodeName }
              volumeMounts:
                - { name: workspace,        mountPath: /workspace }
                - { name: job-config,       mountPath: /jobs, readOnly: true }
                - { name: oauth,            mountPath: /var/run/claude, readOnly: true }
                - { name: baseline-settings, mountPath: /home/claude-agent/.claude/settings.json, subPath: settings.json, readOnly: true }
          volumes:
            - name: workspace
              persistentVolumeClaim:
                claimName: {{ include "claude-jobs.fullname" . }}-workspace
            - name: job-config
              configMap:
                name: {{ include "claude-jobs.fullname" . }}
            - name: oauth
              secret:
                secretName: {{ .Values.oauth.secretName }}
                defaultMode: 0400
                items:
                  - key: {{ .Values.oauth.keyName }}
                    path: credentials.json
            - name: baseline-settings
              configMap:
                name: {{ include "claude-jobs.fullname" . }}-settings
```

- [ ] **Step 2: Commit**

```bash
git add apps/charts/claude-jobs/templates/cronjob.yaml
git commit -m "apps/charts/claude-jobs: CronJob template"
```

### Task 16: Lint and template-render the chart

- [ ] **Step 1: helm lint with empty values fails on the required-field check**

```bash
cd apps/charts/claude-jobs
helm lint .
```

Expected: lint reports at least one ERROR — "job.name is required" (or similar). This proves the validation helper fires.

- [ ] **Step 2: helm template with a dummy values set passes**

```bash
helm template smoke . \
  --set job.name=smoke \
  --set job.schedule="0 0 * * *" \
  --set job.prompt="Say hi." \
  --set job.allowedTools="Read"
```

Expected: yaml manifests printed for ConfigMap, ConfigMap-settings, PVC, CronJob. No errors. Quick visual: the CronJob references the right Secret/ConfigMap/PVC names.

---

## Phase 4: Pilot — longhorn-health

### Task 17: Write the pilot values file

**Files:**
- Create: `apps/charts/claude-jobs/values-longhorn-health.yaml`

- [ ] **Step 1: Write values**

```yaml
serviceAccount: claude-agent-ro

storage:
  size: 2Gi

job:
  name: longhorn-health
  schedule: "17 */6 * * *"
  activeDeadlineSeconds: 900
  maxTurns: 20
  allowedTools: "Read,Grep,Bash(kubectl get:*),Bash(kubectl describe:*),Bash(kubectl logs:*)"
  prompt: |
    You are a homelab SRE assistant. Inspect Longhorn health across the cluster.

    Use kubectl against the in-pod ServiceAccount (claude-agent-ro). Do NOT
    attempt to mutate anything. Report:
      1. Volume count: total, healthy, degraded, faulted.
      2. Any volume in non-healthy state — name, replicas, last-state-change.
      3. Any Longhorn manager/engine pod not Running.
      4. Disk capacity per node — flag any node >80% used.

    Be concise. End with a single-line SUMMARY: line that says either
    "OK" or "ATTENTION: <short reason>".
```

- [ ] **Step 2: Commit**

```bash
git add apps/charts/claude-jobs/values-longhorn-health.yaml
git commit -m "apps/charts/claude-jobs: longhorn-health pilot values"
```

### Task 18: Install the pilot CronJob

- [ ] **Step 1: helm template dry-run**

```bash
helm template longhorn-health apps/charts/claude-jobs \
  --namespace claude-agent \
  -f apps/charts/claude-jobs/values-longhorn-health.yaml
```

Expected: yaml renders without errors. Skim the output.

- [ ] **Step 2: kubectl apply via helm**

```bash
helm install longhorn-health apps/charts/claude-jobs \
  --namespace claude-agent \
  -f apps/charts/claude-jobs/values-longhorn-health.yaml
```

Expected: 4 resources created (`ConfigMap`, `ConfigMap` settings, `PVC`, `CronJob`).

- [ ] **Step 3: Verify resources**

```bash
kubectl -n claude-agent get cronjob,configmap,pvc -l homelab.chifor/job-name=longhorn-health
```

Expected: 1 CronJob, 2 ConfigMaps, 1 PVC. PVC `STATUS=Bound`.

### Task 19: Manually trigger a run and verify success

- [ ] **Step 1: Kick off a one-shot Job from the CronJob**

```bash
kubectl -n claude-agent create job longhorn-health-manual --from=cronjob/claude-job-longhorn-health
```

- [ ] **Step 2: Wait and watch**

```bash
kubectl -n claude-agent get pods -l job-name=longhorn-health-manual -w
```

Expected (eventually): `STATUS=Completed`. Press Ctrl-C once you see it. If it goes `Error` or `Pending` for >2 min, check `kubectl describe` next.

- [ ] **Step 3: Inspect logs**

```bash
kubectl -n claude-agent logs -l job-name=longhorn-health-manual --tail=-1
```

Expected: stream-json transcript ending with a `SUMMARY: OK` (or `ATTENTION: ...`) line. No `permission denied`. No `command not found`.

- [ ] **Step 4: Confirm Radxa scheduling**

```bash
kubectl -n claude-agent get pod -l job-name=longhorn-health-manual -o jsonpath='{.items[0].spec.nodeName}{"\n"}'
```

Expected: one of the 4 Radxa node names.

- [ ] **Step 5: Inspect workspace persistence**

```bash
kubectl -n claude-agent run pvc-inspect --rm -i --tty --restart=Never \
  --image=busybox \
  --overrides='{"spec":{"containers":[{"name":"sh","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"ws","mountPath":"/workspace"}]}],"volumes":[{"name":"ws","persistentVolumeClaim":{"claimName":"claude-job-longhorn-health-workspace"}}]}}' \
  -- sh
# inside the shell:
ls -la /workspace/runs/
exit
```

Expected: at least one timestamped subdirectory containing `transcript.jsonl`, `meta.log`, and `stderr.log`.

- [ ] **Step 6: Clean up the manual job**

```bash
kubectl -n claude-agent delete job longhorn-health-manual
```

### Task 20: Verify the deny-list works

- [ ] **Step 1: Write a one-off test pod that tries `docker ps`**

Create `/tmp/deny-probe.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata: { name: deny-probe, namespace: claude-agent }
data:
  prompt.md: |
    Run `docker ps`. Report what happened — success, denied, or not found.
  allowed-tools.txt: "Read,Bash(docker:*),Bash(echo:*)"
  job.env: |
    CLAUDE_MAX_TURNS=5
---
apiVersion: batch/v1
kind: Job
metadata: { name: deny-probe, namespace: claude-agent }
spec:
  backoffLimit: 0
  template:
    spec:
      serviceAccountName: claude-agent-ro
      restartPolicy: Never
      nodeSelector: { homelab.chifor/role: claude-worker }
      containers:
        - name: claude
          image: gitea.chifor.dev/c4/claude-runner:latest
          env:
            - name: NODE_NAME
              valueFrom: { fieldRef: { fieldPath: spec.nodeName } }
          volumeMounts:
            - { name: workspace,        mountPath: /workspace }
            - { name: job-config,       mountPath: /jobs, readOnly: true }
            - { name: oauth,            mountPath: /var/run/claude, readOnly: true }
            - { name: baseline-settings, mountPath: /home/claude-agent/.claude/settings.json, subPath: settings.json, readOnly: true }
      volumes:
        - { name: workspace,        emptyDir: {} }
        - { name: job-config,       configMap: { name: deny-probe } }
        - { name: oauth,            secret: { secretName: claude-oauth, defaultMode: 0400, items: [{ key: credentials.json, path: credentials.json }] } }
        - { name: baseline-settings, configMap: { name: claude-job-longhorn-health-settings } }
```

- [ ] **Step 2: Apply and read logs**

```bash
kubectl apply -f /tmp/deny-probe.yaml
kubectl -n claude-agent wait --for=condition=Complete --timeout=300s job/deny-probe || \
  kubectl -n claude-agent describe job deny-probe
kubectl -n claude-agent logs -l job-name=deny-probe --tail=-1
```

Expected: Claude reports either "docker not found" (binary not in image — layer 1 win) or "permission denied" (deny-list — layer 2 win). Both are acceptable; both demonstrate Docker is blocked.

- [ ] **Step 3: Clean up**

```bash
kubectl -n claude-agent delete job deny-probe
kubectl -n claude-agent delete configmap deny-probe
```

### Task 21: Let the scheduled run fire and observe

- [ ] **Step 1: Wait for the next scheduled trigger**

```bash
kubectl -n claude-agent get cronjob claude-job-longhorn-health -o wide
```

Note the `LAST SCHEDULE` and `ACTIVE` columns. Wait until at least one automatic run completes (cron is `17 */6 * * *`, so within ~6 hours).

- [ ] **Step 2: Confirm history retention**

```bash
kubectl -n claude-agent get jobs -l homelab.chifor/job-name=longhorn-health
```

Expected: 1-3 historical jobs visible (we set `successfulJobsHistoryLimit: 3`).

- [ ] **Step 3: Compare output quality vs the VM equivalent**

Read both transcripts:

```bash
# Latest Radxa run
JOB=$(kubectl -n claude-agent get jobs -l homelab.chifor/job-name=longhorn-health \
  --sort-by=.metadata.creationTimestamp -o jsonpath='{.items[-1].metadata.name}')
kubectl -n claude-agent logs -l job-name=$JOB --tail=-1 > /tmp/radxa-run.jsonl

# Latest VM run (assuming the VM timer is still running in parallel)
ssh c4@<claude-worker-vm-ip> 'sudo ls -td /workspace/runs/longhorn-health/* | head -1 | xargs -I{} sudo cat {}/transcript.jsonl' \
  > /tmp/vm-run.jsonl
```

Manual inspection: does the Radxa run reach the same SUMMARY line? Same depth of analysis?

---

## Phase 5: VM-side handoff for the pilot

### Task 22: Disable (don't remove) the VM systemd timer

Keeping the unit file in place gives you a 10-minute rollback path. Remove it only after the 2-week observation window.

- [ ] **Step 1: Disable the timer**

```bash
ssh c4@<claude-worker-vm-ip> "sudo systemctl disable --now claude-job@longhorn-health.timer"
```

Expected: timer reported as stopped and disabled.

- [ ] **Step 2: Verify**

```bash
ssh c4@<claude-worker-vm-ip> "systemctl is-enabled claude-job@longhorn-health.timer; systemctl is-active claude-job@longhorn-health.timer"
```

Expected: "disabled" and "inactive".

- [ ] **Step 3: Commit a one-line note in the homelab README or runbook**

Edit the relevant ops doc (e.g. `platform/modules/proxmox_vm_claude_worker/README.md`) noting that longhorn-health has moved to the k3s CronJob.

```bash
git add platform/modules/proxmox_vm_claude_worker/README.md
git commit -m "claude-worker: note that longhorn-health has moved to k3s CronJob (pilot)"
```

### Task 23: 2-week decision gate

- [ ] **Step 1: Set a calendar reminder for 2026-05-26**

On 2026-05-26, review:
- Did all 56 scheduled runs (4/day × 14 days) succeed?
- Any auth errors that would suggest OAuth concurrency cap?
- PVC consumption — is workspace bloating?
- Output parity with the VM run vs. degradation?

- [ ] **Step 2: Decision**

If green: proceed to migrate the remaining VM timers (separate plan).
If red: re-enable the VM timer, capture root cause, file follow-up. Rollback is `systemctl enable --now claude-job@longhorn-health.timer` on the VM + `helm uninstall longhorn-health -n claude-agent`.

---

## Self-Review

**Spec coverage** (against the conversation, since there's no separate spec doc):
- ✅ Pure-Claude on Radxas, no Docker — image deliberately excludes Docker; deny-list enforces it (Tasks 1, 13, 20).
- ✅ Reuse existing `claude-agent-ro`/`-rw` SAs — Task 8 verifies; Task 17 references; Task 15 mounts.
- ✅ OAuth from VM, mounted via Secret — Task 9 (copy), Task 15 (mount), Task 2 (entrypoint symlinks to canonical path).
- ✅ Longhorn PVC per job — Task 14.
- ✅ Pinned to Radxas via explicit label — Task 7 labels nodes, Task 11 defaults `nodeSelector` accordingly.
- ✅ Helm chart so subsequent jobs are a values file — Tasks 11-15.
- ✅ Pilot end-to-end — Tasks 17-21.
- ✅ Smoke tests at each phase boundary (image, secret, pod, deny-list) — Tasks 5, 10, 20.
- ⚠ Not covered (explicit out-of-scope per goal): PVC backup, Velero, full timer migration, multi-OAuth, ttyd-in-pod, Sysbox.

**Placeholder scan:** No "TBD" / "fill in" — every code block contains the actual contents. All commands have expected outputs. Risk callouts (gitea auth on Radxa nodes) note "out of scope here — note as a prerequisite if it fails" rather than hand-waving.

**Type/name consistency:**
- Chart name: `claude-jobs` (singular release-per-job).
- Fullname pattern: `claude-job-<name>` (matches existing VM systemd-unit naming).
- ConfigMap names: `claude-job-<name>` (job config) + `claude-job-<name>-settings` (baseline).
- PVC name: `claude-job-<name>-workspace`.
- All references in Task 15's CronJob template match the names produced by Tasks 13 + 14.
- OAuth Secret keyed by `credentials.json` everywhere (Tasks 2, 9, 15).
- Node label key/value `homelab.chifor/role=claude-worker` consistent across Tasks 7, 11, 17.

**Known risks recorded inline:**
- Gitea container registry must be enabled + Radxa nodes must trust it (Task 6 Step 3 flags this).
- Anthropic OAuth concurrency cap unverified — Task 23 watches for it.
- Armbian is not in the official Sysbox-supported distro list, but Sysbox is not used here, so this risk is N/A for this plan.

---

## Execution

**Plan complete and saved to `docs/superpowers/plans/2026-05-12-claude-radxa-jobs.md`.**

Two execution options:

1. **Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?

---

## Build outcome — what actually shipped (2026-05-12)

The pilot is live in the `home-lab` k3s cluster (`helm install longhorn-health …`,
revision 2). Several design points changed between this plan and the final
commits on the `worktree-quiet-strolling-oasis` branch; future readers should
treat the git log as authoritative on these:

**1. Image distribution path is not Gitea-push.**
The plan called for `docker buildx build --push` to `gitea.chifor.dev/c4/claude-runner`.
In practice, Gitea Docker auth was not set up on either the workstation or the
VM. Workflow used instead: arm64 build on the VM (under `qemu-user-static`),
output as a docker tar via `--output type=docker,dest=...`, then for each Radxa
`ssh c4@VM cat /tmp/…-arm64.tar | ssh c4@RADXA sudo k3s ctr images import -`.
The image tag stays `gitea.chifor.dev/c4/claude-runner:latest`; with
`imagePullPolicy: IfNotPresent` the pod never tries to pull from the registry.
`build.sh` in the repo still encodes the push path — works once Gitea Docker
auth is set up.

**2. Auth: `claude setup-token` env var, not `.credentials.json` file mount.**
The plan's file-mount design fell over in production: OAuth tokens from
`claude auth login` rotate roughly every 30 minutes while the interactive
`claude` session is in use, so the cluster-side Secret snapshot quickly went
stale and scheduled pods 401'd. Final design (commit `3965e5b`): run
`claude setup-token` once to mint a long-lived (~1y) token, store under key
`CLAUDE_CODE_OAUTH_TOKEN` in `secret/claude-oauth`, project into the pod
as an env var of the same name. No file mount, no rotation, no watcher.
Token renewal in ~1y is a one-liner with `kubectl create secret … --dry-run …
| kubectl apply -f -`; no chart re-render needed.

**3. Dockerfile fixes that plan-time reviewers missed.**
Four runtime/build problems surfaced during the actual build/run and got
their own commits:
- `${TARGETARCH/amd64/x64}` is bash-only; Dockerfile RUN uses `/bin/sh`
  (dash) — replaced with a POSIX `case` (`0a5d225`).
- `debian:12-slim` lacks `xz-utils` (needed by `tar -xJ` for Node tarball)
  (`ec62b3c`).
- `claude -p --output-format=stream-json` requires `--verbose` (`ce70fef`).
- `/home/claude-agent/.claude/` must be pre-created in the image; otherwise
  the chart's subPath mount of `settings.json` makes kubelet create the
  parent dir as root, locking UID 1000 out of writing the credential
  symlink (`b8d3d73`).

**4. CronJob template additions during code review.**
- `securityContext.runAsUser/runAsGroup/fsGroup: 1000` is required so the
  Longhorn PVC mount is writable by the runner user.
- The OAuth Secret originally had `defaultMode: 0400` — too restrictive once
  `fsGroup: 1000` chowns it to `root:1000`. Fixed to `0440` (`911eee9`).
  (Obsolete after item 2: the file mount itself was removed.)

**5. VM systemd timer for `longhorn-health` was enabled+failing.**
The claude-worker VM had `claude-job@longhorn-health.timer` enabled but
silently failing (no `claude` binary at the time). Task 22 disabled it.
A separate `claude-job@nightly-repo-audit.timer` remains enabled and likely
silently-failing — not in pilot scope; flag for future cleanup.

**6. Adjacent VM work done during the migration.**
- `claude` CLI installed on the VM for both `c4` and `claude-agent` users.
- `claude-agent`'s `.bash_profile` added so login shells inherit the
  `~/.npm-global/bin` PATH from `.bashrc`.
- `inotify-tools` installed (it would have backed the OAuth watcher in
  fallback path B; unused after switching to env-var auth — harmless).

**Files added beyond the original plan:**
- `apps/charts/claude-jobs/README.md` (chart-level operator runbook)
- `apps/charts/claude-jobs/preflight.sh` (pre-install validation)
- `apps/charts/claude-jobs/values.yaml` gained `storage.keepOnUninstall`
  (opt-in PVC retention for future stateful jobs).

