# homelab / platform

OpenTofu project that provisions a hybrid k3s cluster on Proxmox VE 8+ and four Radxa Q6A workers, plus an **Alpine 3.23** LXC running MinIO for S3 storage, Longhorn for persistent volumes, **Sysbox-CE on every node** so pods can run Docker / `docker compose` / systemd without `privileged: true`, and **Rancher** for cluster management via a web UI.

| Component | Where | Resources |
|---|---|---|
| MinIO (S3 NAS) | Privileged **Alpine 3.23** LXC on Proxmox | 1C / 4GB / 8GB rootfs + bind-mounted `/nvme-pool` |
| k3s control plane | Debian 12 VM on Proxmox | 2C `cpu=host` / 6GB / 32GB on `local-zfs` |
| k3s workers (×4) | Radxa Q6A on Armbian | host hardware |
| Longhorn | Across the cluster | replicaCount=2, MinIO as backup target |
| Sysbox-CE | Every k3s node (server + 4 workers) | RuntimeClass `sysbox-runc` |
| Traefik | k3s built-in | LoadBalancer published on `192.168.0.187` via klipper-lb |
| cert-manager + ClusterIssuer | k8s | self-signed `selfsigned-issuer` |
| Rancher | k8s namespace `cattle-system` | Hostname `rancher.lan` → `192.168.0.187` |

LAN: primary `192.168.0.0/24`, with worker `q6a-4` reachable on `192.168.1.0/24` via inter-VLAN routing. Host `192.168.0.185`, NAS `192.168.0.186`, control plane `192.168.0.187`, workers at `192.168.0.174`, `192.168.0.200`, `192.168.0.129`, and `192.168.1.167`.

---

## Quick start (recommended path)

All scripts under `scripts/` are idempotent and safe to re-run. Bash works on Linux, macOS, and Windows (Git Bash / WSL / Cygwin) — same script everywhere.

**Single edit point for cluster topology:** `scripts/cluster.conf` holds `PROXMOX_HOST`, `WORKERS`, `WORKER_USER`, `SSH_KEY_PATH`, and the API token ID. Edit it once when your IPs / user names / key paths change; both `deploy-prep.sh` and `check-prereqs.sh` source it automatically. CLI flags on either script still override anything set there.

```bash
# Run from the operator machine, in your project directory:
cd /c/Users/chifo/work/home/homelab/platform     # or your shell's path style

# 0. ONE-TIME: authorize your SSH key on Proxmox + every worker.
#    Prompts for each host's password once (5 prompts total on first run).
#    Re-runs are no-ops — already-authorized hosts are skipped silently.
bash scripts/authorize-ssh-keys.sh
# After this, all subsequent SSH operations are key-based (silent); only
# `sudo` on the workers still prompts (one prompt per worker per deploy-prep run).

# 1. Ship + run prep scripts on Proxmox + every worker, in one command.
#    Prompts for the worker user's sudo password once per worker (4 times total).
bash scripts/deploy-prep.sh
# Save the token "value" field that prep-proxmox.sh prints once during this step.

# 2. Single-command idempotent readiness check + tfvars generation.
bash scripts/check-prereqs.sh

# 3. (one-time) merge the project kubeconfig into ~/.kube/config so plain
#    `kubectl ...` works from any directory. Preserves any other clusters you
#    already have. Adds the `home-lab` context and switches to it.
bash scripts/merge-kubeconfig.sh

# Also: if your `kubectl` minor version is more than +/-1 from the server,
# install the matching version (k3s 1.30 → kubectl 1.30.x). One-liner per-user
# install (no admin):
#   mkdir -p ~/bin && curl -sL -o ~/bin/kubectl.exe \
#     https://dl.k8s.io/release/v1.30.10/bin/windows/amd64/kubectl.exe
#   export PATH="$HOME/bin:$PATH"     # add to ~/.bashrc to persist
# What it does in one run:
#   - Loads .env if present (key=value, gitignored). Existing shell env vars win.
#   - Prompts (hidden input) for TF_VAR_pm_api_token_secret if missing, then
#     persists it to .env. Subsequent runs just load it.
#   - SSH-checks Proxmox + every worker (read-only).
#   - Generates terraform.tfvars from discovered values (Alpine template, Debian
#     template VM name, node hostname) on first run only — leaves it alone after.
#     Delete terraform.tfvars to regenerate after a hardware/topology change.
#   - Exits 0 = ready, 1 = blockers found (printed at the end).
```

If you'd rather understand each step or do it by hand, the **Prerequisites** section below documents the manual equivalent of each script. **Manual deployment patterns** further down has the ad-hoc ssh one-liners that `deploy-prep.sh` wraps (handy for debugging a single host).

**About `.env`**: stores `TF_VAR_pm_api_token_secret` (and optionally `TF_VAR_rancher_bootstrap_password`) so secrets persist across shells without exporting per-session. The script loads it as a *fallback* — anything you've already set with `export TF_VAR_x=...` in your current shell still wins. The file is gitignored and `chmod 600` on POSIX.

**On Windows:** the prep-proxmox / prep-worker scripts execute on the remote Linux hosts (always bash). The operator-side scripts (`deploy-prep.sh`, `check-prereqs.sh`) run under Git Bash, WSL, or Cygwin.

---

## Prerequisites (one-time, manual)

These are NOT managed by OpenTofu. Do them once before `tofu init`. **All of §1, §2, §5 below are automated by the `scripts/*` above** — this section is for understanding / running by hand.

### 1. Proxmox API token

> Automated by `scripts/prep-proxmox.sh` (steps 1).

Per `..\ProxmoxApiToken.md` (in the parent directory): create an Administrator-at-`/` token. Privileged LXCs + host bind mounts require the Administrator role; lower roles return `403 Forbidden`.

```bash
# On the Proxmox host shell:
pveum user add tofu-prov@pve --password <secure-password>
pveum aclmod / -user tofu-prov@pve -role Administrator
pveum user token add tofu-prov@pve tofu-token --privsep 0
# Save the token secret — it is shown only once.
```

Then on the operator machine (Windows / PowerShell):
```pwsh
$env:TF_VAR_pm_api_token_secret = "<the-token-secret>"
```

Add `pm_api_token_id = "tofu-prov@pve!tofu-token"` to `terraform.tfvars`.

### 2. Pre-uploaded ISOs / templates on Proxmox

> Automated by `scripts/prep-proxmox.sh` (steps 2 + 3).

The project assumes these are already on Proxmox storage:

- **Alpine LXC template** — current latest stable is **Alpine 3.23** (released 2025-12-03, supported through 2027-11). The exact date stamp Proxmox ships drifts as the catalog refreshes, so look up the actual filename rather than copying:
  ```bash
  # On the Proxmox host:
  pveam update
  pveam available --section system | grep alpine
  # Pick the latest 3.23 line (or 3.22 if 3.23 hasn't propagated yet) and download:
  pveam download local alpine-3.23-default_<datestamp>_amd64.tar.xz
  ```
  Override `nas_template` in `terraform.tfvars` with whatever filename you actually downloaded.

- **Debian 12 cloud-init template VM** named `debian-12-cloudinit-template`. Create it once:
  ```bash
  # On the Proxmox host:
  cd /var/lib/vz/template/iso
  wget https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-amd64.qcow2
  qm create 9000 --name debian-12-cloudinit-template --memory 2048 --net0 virtio,bridge=vmbr0
  qm importdisk 9000 debian-12-genericcloud-amd64.qcow2 local-zfs
  qm set 9000 --scsihw virtio-scsi-single --scsi0 local-zfs:vm-9000-disk-0
  qm set 9000 --ide2 local-zfs:cloudinit
  qm set 9000 --boot c --bootdisk scsi0
  qm set 9000 --serial0 socket --vga serial0
  qm set 9000 --agent enabled=1
  qm template 9000
  ```

### 3. Proxmox host networking (bond + bridge)

Configure `bond0` + `vmbr0` in `/etc/network/interfaces` on the Proxmox host. The bond uses **LACP (`bond-mode 802.3ad`)** for true 5 Gbps aggregation across the two 2.5 GbE NICs, with `bond-xmit-hash-policy layer2+3` (per-IP-pair hashing — Longhorn replication between distinct workers will spread across both links).

Reference `/etc/network/interfaces`:
```
auto lo
iface lo inet loopback

auto nic0
iface nic0 inet manual

auto nic1
iface nic1 inet manual

auto bond0
iface bond0 inet manual
        bond-slaves nic0 nic1
        bond-miimon 100
        bond-mode 802.3ad
        bond-xmit-hash-policy layer2+3

auto vmbr0
iface vmbr0 inet static
        address 192.168.0.185/24
        gateway 192.168.0.1
        bridge-ports bond0
        bridge-stp off
        bridge-fd 0

source /etc/network/interfaces.d/*
```
Reload with `ifreload -a`. (MTU stays at the default 1500 — jumbo frames give negligible benefit on this hardware and add a silent-failure mode if any switch port is misconfigured.)

**LACP requires a matching switch-side aggregation** — it is not auto-negotiated. Without the switch-side LAG, only one link carries traffic and the switch logs MAC-flap warnings. Configure it once in the UniFi controller:

1. Devices → click your switch.
2. **Port Manager** → identify the two ports your `nic0` and `nic1` plug into.
   - Tip: from the Proxmox host, `ethtool -p nic0 5` blinks that NIC's switch-port LED for 5 seconds. Repeat for `nic1` to map them with certainty.
3. Ctrl/Cmd-click both port tiles to multi-select them.
4. With both selected, the right-side panel shows an **Aggregate** action (older UI: "Port Aggregation", or a chain-link icon). Click it.
5. Name the aggregation (e.g. `pve-bond`) and **save**. UniFi defaults match the Linux side: LACP active, `layer2+3` hashing.

Verify on the Proxmox host:
```bash
cat /proc/net/bonding/bond0 | head -25
```
Healthy output should show `Number of ports: 2`, both slaves with the **same** `Aggregator ID`, `Partner Mac Address` non-zero (a Ubiquiti OUI: `1c:0b:8b:...`), and `Actor`/`Partner Churn State: none`. If anything still shows `churned` after a minute, you selected the wrong switch ports in step 2 or one of them has a conflicting profile.

(If your switch is unmanaged or you don't want to deal with the LAG config, switch the bond to `bond-mode active-backup` — one link active, one standby. You give up the throughput aggregation but it works on any switch with zero coordination.)

### 4. SSH keys

- An SSH key authorized as `root` on the Proxmox host (default path `~/.ssh/id_ed25519`).
- An SSH public key for the `debian` cloud-init user on the control-plane VM.
- An SSH key authorized on each Radxa Q6A worker as the user named in `workers.<name>.ssh_user` (defaults to `c4` in this project; the Armbian-image factory default is `rock` if you haven't created your own user yet).

### 5. Radxa Q6A pre-flight (cgroupv2 + Sysbox userns)

> Verified by `scripts/prep-worker.sh` (run on each worker as root). Read-only — does not edit boot config or sysctls.

The Q6A boards in this cluster (QCS6490 SoC, Armbian/Debian on UEFI+GRUB, kernel ≥ 6.x) ship with cgroupv2 unified hierarchy and `CONFIG_MEMCG=y`, so k3s prerequisites are satisfied out of the box. The script just confirms it:

```bash
# As root on the worker — these should all return the expected values:
grep -qw memory /sys/fs/cgroup/cgroup.controllers && echo "memory cgroup OK"
[ ! -e /proc/sys/kernel/unprivileged_userns_clone ] && echo "userns implicitly enabled"
ps -p 1 -o comm=                                   # systemd
systemctl is-active ssh                            # active
```

If a check fails, `prep-worker.sh` prints the exact manual fix (e.g. `update-grub` for GRUB-based systems running cgroupv1, or `sysctl -w` for kernels exposing the userns toggle). It does NOT auto-edit the bootloader — those changes are too system-specific to do safely from a prep script.

### 6. Manual deployment patterns (for ad-hoc / debugging use)

`scripts/deploy-prep.sh` automates the loop, but for a one-off run on a single host or to debug a failure, here are the underlying patterns it uses.

**Proxmox host** (root SSH on by default in PVE — no sudo needed):
```bash
ssh root@192.168.0.185 'bash -s' < scripts/prep-proxmox.sh
```
Stdin redirect means the script never lands on the host — nothing to clean up.

**Single worker** with a sudo-password user (the c4 case):
```bash
scp scripts/prep-worker.sh c4@<worker-ip>:/tmp/
ssh -t c4@<worker-ip> 'sudo bash /tmp/prep-worker.sh && rm /tmp/prep-worker.sh'
```
The `-t` flag allocates a PTY so sudo can prompt for the password. **Don't use the stdin-redirect form for sudo-password workers** — `ssh c4@host 'sudo bash -s' < script` deadlocks (stdin is the script, sudo can't read the password from it).

**All workers sequentially** (replace IPs with yours):
```bash
for h in 192.168.0.174 192.168.0.200 192.168.0.129 192.168.1.167; do
  echo "=== $h ==="
  scp scripts/prep-worker.sh c4@"$h":/tmp/prep-worker.sh
  ssh -t c4@"$h" 'sudo bash /tmp/prep-worker.sh; rm -f /tmp/prep-worker.sh'
done
```
Sequential is easier to debug than parallel — interleaved output from `&` + `wait` is hard to read when something fails.

**Skip Proxmox prep, only do workers** (or vice-versa):
```bash
bash scripts/deploy-prep.sh --only-workers
bash scripts/deploy-prep.sh --only-proxmox
```

### 7. OpenTofu (or Terraform) installed locally

```pwsh
# Either works — the project's HCL is compatible with both. Pick one.
winget install OpenTofu.Tofu     # or: scoop install opentofu
# OR:
choco install terraform           # gives you `terraform` (>= 1.7.0)
```

**Note on `tofu` vs `terraform` in this README:** commands are written as `tofu ...` for OpenTofu users; if you have HashiCorp Terraform installed instead, every `tofu` command in this file works identically as `terraform` (same flags, same behaviour for v1.7+ syntax used here).

---

## First apply (two-phase, one-time only)

The Helm and kubectl providers can't initialize until `./kubeconfig` exists on disk (Longhorn, cert-manager, Rancher, the Sysbox `RuntimeClass`, and the Longhorn `BackupTarget` all live behind these providers). The first bootstrap targets the Proxmox + k3s phase first, which writes the kubeconfig; a second apply then brings up everything else.

```pwsh
cd C:\Users\chifo\work\home\homelab\platform

# Set the Proxmox API token secret (NEVER put in tfvars):
$env:TF_VAR_pm_api_token_secret = "<paste-secret>"

# OPTIONAL: pin the initial Rancher admin password (otherwise a random one is generated;
# read it later with `tofu output -raw rancher_bootstrap_password`).
$env:TF_VAR_rancher_bootstrap_password = "<initial-password>"

# Copy the example tfvars and edit:
Copy-Item terraform.tfvars.example terraform.tfvars
notepad terraform.tfvars

tofu init

# --- Phase 1: Proxmox layer + k3s server + fetch kubeconfig/token ---
tofu apply `
  -target=module.nas_minio `
  -target=module.k3s_server `
  -target=null_resource.k3s_server_bootstrap `
  -target=null_resource.fetch_k3s_token `
  -target=null_resource.fetch_kubeconfig

# Verify ./kubeconfig and ./.k3s_token exist:
Test-Path .\kubeconfig
Test-Path .\.k3s_token

# --- Phase 2: workers + Sysbox + Longhorn + cert-manager + Rancher ---
tofu apply
```

**Every subsequent apply is single-command** (`tofu apply`) — version bumps, scaling workers, adjusting Longhorn settings, bumping Sysbox or Rancher, etc.

---

## Add a 5th (or Nth) worker

Edit `terraform.tfvars`, append one map entry:

```hcl
workers = {
  q6a-1 = { name = "q6a-1", address = "192.168.0.174", ssh_user = "c4", ssh_key = "~/.ssh/id_ed25519" }
  q6a-2 = { name = "q6a-2", address = "192.168.0.200", ssh_user = "c4", ssh_key = "~/.ssh/id_ed25519" }
  q6a-3 = { name = "q6a-3", address = "192.168.0.129", ssh_user = "c4", ssh_key = "~/.ssh/id_ed25519" }
  q6a-4 = { name = "q6a-4", address = "192.168.1.167", ssh_user = "c4", ssh_key = "~/.ssh/id_ed25519" }
  q6a-5 = { name = "q6a-5", address = "192.168.0.175", ssh_user = "c4", ssh_key = "~/.ssh/id_ed25519" }
}
```

Then `tofu apply`. Existing workers are NOT churned (the `for_each` is keyed by map key, not list index).

---

## Verification

With `$env:KUBECONFIG = "$PWD\kubeconfig"` (PowerShell) or `KUBECONFIG=$PWD/kubeconfig` (bash):

```pwsh
# Proxmox layer:
ssh root@192.168.0.185 'pct list ; qm list'
ssh root@192.168.0.185 'pct exec <CTID> -- mount | grep storage'

# MinIO:
curl.exe -sI http://192.168.0.186:9000/minio/health/live    # expect 200

# k3s:
kubectl get nodes -o wide                                   # expect 5 Ready
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.architecture}{"\n"}{end}'

# Sysbox runtime registered on every node:
ssh -i ~/.ssh/id_ed25519 debian@192.168.0.187 'sudo k3s crictl info 2>/dev/null | grep sysbox-runc'
for h in 192.168.0.174 192.168.0.200 192.168.0.129 192.168.1.167; do
  echo "=== $h ==="
  ssh -t -i ~/.ssh/id_ed25519 c4@"$h" 'sudo k3s crictl info 2>/dev/null | grep sysbox-runc'
done
kubectl get runtimeclass sysbox-runc                        # expect: sysbox-runc / handler=sysbox-runc

# Traefik (re-enabled in v2):
kubectl get svc -n kube-system traefik                      # EXTERNAL-IP should be 192.168.0.187

# Longhorn:
kubectl -n longhorn-system get pods
kubectl get storageclass                                    # expect 'longhorn' default
kubectl -n longhorn-system get setting backup-target        # value: s3://longhorn-backups@us-east-1/

# cert-manager:
kubectl -n cert-manager get pods                            # cert-manager, cainjector, webhook all Running
kubectl get clusterissuer selfsigned-issuer -o jsonpath='{.status.conditions[0].status}'   # True

# Rancher:
kubectl -n cattle-system rollout status deploy/rancher --timeout=10m
# Then: hosts file → 192.168.0.187 rancher.lan, browse https://rancher.lan, log in with:
tofu output -raw rancher_bootstrap_password

# Idempotency:
tofu plan                                                   # MUST be 'No changes'
```

Smoke test PVC:
```pwsh
@'
apiVersion: v1
kind: PersistentVolumeClaim
metadata: { name: smoke, namespace: default }
spec:
  accessModes: [ReadWriteOnce]
  resources: { requests: { storage: 1Gi } }
  storageClassName: longhorn
'@ | kubectl apply -f -
kubectl get pvc smoke           # Bound within ~30s
kubectl delete pvc smoke
```

Smoke test Sysbox (docker-in-pod, no `privileged: true`):
```pwsh
@'
apiVersion: v1
kind: Pod
metadata: { name: sysbox-smoke, namespace: default }
spec:
  runtimeClassName: sysbox-runc
  containers:
    - name: dind
      image: docker:24-dind
      env: [{ name: DOCKER_TLS_CERTDIR, value: "" }]
      command: ["sh","-c","dockerd & sleep 8 && docker run --rm hello-world"]
'@ | kubectl apply -f -
kubectl logs -f pod/sysbox-smoke    # expect 'Hello from Docker!'
kubectl delete pod sysbox-smoke
```

---

## Using Sysbox (docker-in-pod / systemd-in-pod)

Pods opt into the Sysbox runtime by setting `runtimeClassName: sysbox-runc`. No `privileged: true` needed.

Example pod that runs Docker inside the pod and pulls `hello-world`:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sysbox-smoke
  namespace: default
spec:
  runtimeClassName: sysbox-runc
  containers:
    - name: dind
      image: docker:24-dind
      env:
        - name: DOCKER_TLS_CERTDIR
          value: ""
      command: ["sh", "-c", "dockerd & sleep 8 && docker run --rm hello-world"]
```

```pwsh
kubectl apply -f sysbox-smoke.yaml
kubectl logs -f pod/sysbox-smoke      # expect 'Hello from Docker!'
kubectl delete pod sysbox-smoke
```

For `docker compose`, add `docker-compose-plugin` to the image's apt/apk install or use an image that already bundles it (e.g., `docker:24-dind` includes it as `docker compose`). Same `runtimeClassName: sysbox-runc`.

To verify Sysbox is registered on every node:
```bash
# Control-plane VM (debian user, no sudo password):
ssh -i ~/.ssh/id_ed25519 debian@192.168.0.187 'sudo k3s crictl info 2>/dev/null | grep sysbox-runc'

# Workers (c4 user with sudo password — `-t` for the prompt):
for h in 192.168.0.174 192.168.0.200 192.168.0.129 192.168.1.167; do
  echo "=== $h ==="
  ssh -t -i ~/.ssh/id_ed25519 c4@"$h" 'sudo k3s crictl info 2>/dev/null | grep sysbox-runc'
done
```

## Accessing Rancher

1. **Resolve `rancher.lan` to the k3s server VM IP.** On the operator machine, add to your hosts file:
   - Windows: `C:\Windows\System32\drivers\etc\hosts` (run editor as Administrator)
   - macOS / Linux: `/etc/hosts`
   ```
   192.168.0.187   rancher.lan
   ```
   If you have a Pi-hole / OPNsense / router-managed DNS, register it there instead for cluster-wide resolution.

2. **Wait for Rancher to be ready:**
   ```pwsh
   kubectl -n cattle-system rollout status deploy/rancher --timeout=10m
   ```

3. **Get the bootstrap password:**
   ```pwsh
   tofu output -raw rancher_bootstrap_password
   ```

4. **Browse to** `https://rancher.lan` — accept the self-signed cert.

5. **Log in** with username `admin` and the bootstrap password. Rancher prompts you to set a new admin password and accept the EULA.

6. **The local cluster is auto-imported** under `Cluster Management` (Rancher detects it via the in-cluster API).

## Running `docker compose` workloads

Sysbox (the original plan for unprivileged docker-in-pod) is **deferred** — Sysbox + k3s + containerd 1.7.x is a known unsupported combination. Two workable patterns instead:

**Pattern 1: Multiple independent DinD pods** (each pod = own dockerd, own image cache, own networks). Strong isolation; recommended for ad-hoc per-project work. Manifest at `examples/dind-pattern-1-statefulset.yaml`; full usage docs in `examples/README.md`. Quick start:

```bash
kubectl apply -f examples/dind-pattern-1-statefulset.yaml
kubectl -n dind exec -it dind-0 -- sh
# Inside the pod:
/ # docker compose up -d
```

**Pattern 2: One shared `dockerd` Deployment + many cheap non-privileged client pods** (CI-style). Better for shared image cache and high-throughput compose runs; only one privileged pod for the whole cluster. Not implemented as a manifest yet — see the inline example in this README's earlier conversation history if you want to deploy it (or ask).

**Trade-off vs Sysbox:** these patterns require `privileged: true` on the dockerd pods, which is acceptable for a single-operator home lab but a no-go for multi-tenant production. Re-evaluate Sysbox or move to Kata Containers (RuntimeClass-based microVM isolation, requires `/dev/kvm` on the workers) if you ever need to safely run untrusted workloads.

## Common operations

| Task | Command |
|---|---|
| Re-bootstrap a single worker | `tofu taint 'null_resource.bootstrap_worker["q6a-2"]' && tofu apply` |
| Re-install Sysbox on a single node | `tofu taint 'null_resource.sysbox_install["q6a-2"]' && tofu apply` |
| Bump Sysbox version | edit `sysbox_version`, `tofu apply` (re-runs install on all nodes; brief k3s/k3s-agent restart per node) |
| Bump Rancher chart | edit `rancher_chart_version`, `tofu apply` |
| Rotate Rancher bootstrap password (BEFORE first login) | `tofu taint random_password.rancher_bootstrap && tofu apply` |
| Rotate MinIO password | `tofu taint 'module.nas_minio.random_password.minio_root' && tofu apply` (also re-runs MinIO bootstrap; old creds remain in cluster Secret until next apply rolls Longhorn pods) |
| Bump k3s version | edit `k3s_version` in tfvars, `tofu apply` (re-runs server install + ALL worker installs) |
| Bump Longhorn chart | edit `longhorn_chart_version`, `tofu apply` |
| Get kubeconfig path | `tofu output kubeconfig_path` |
| Get MinIO password | `tofu output -raw minio_root_password` |
| Destroy everything | `tofu destroy` (ZFS pool data on `/nvme-pool` is NOT touched — bind mount only) |

---

## Troubleshooting

**`Error: stat ./kubeconfig: no such file or directory` on first plan**
You skipped the two-phase first apply. Run the Phase 1 `tofu apply -target=...` command first.

**Helm release stuck for >5 min on first apply**
Longhorn engine images are large for ARM64 (~500MB). On a slow link the first install can take 10+ min. The `helm_release.longhorn` timeout is set to 600s; bump it in `main.tf` if you regularly time out.

**Worker join fails with `Failed to start ContainerManager system validation failed`**
Cgroup memory controller is disabled — see "Radxa Q6A pre-flight" above.

**`pct exec` fails inside the MinIO bootstrap with `command not found: bash`**
The Alpine template doesn't have bash. The bootstrap installs it as a prerequisite; check that `apk add bash` ran. Re-run with `tofu taint 'module.nas_minio.null_resource.minio_bootstrap' && tofu apply`.

**MinIO health check returns 503 right after bootstrap**
First-boot can take ~30s for MinIO to format the data dir. Wait, then `curl http://192.168.0.186:9000/minio/health/live` again.

**`tofu plan` shows non-zero drift on every run**
A non-idempotent provisioner is rewriting state. Inspect the diff and address the specific drift; common culprits are scripts that re-write the same file with a fresh timestamp/uuid in it on every run, or version-detection commands that print differently each time.

**Sysbox install fails: `containerd info did not mention sysbox-runc`**
The `{{ template "base" . }}` directive in `config.toml.tmpl` depends on k3s's internal templating. If a future k3s release renames the `base` template, the override silently fails. Recovery: SSH to the node, copy the current `/var/lib/rancher/k3s/agent/etc/containerd/config.toml` (the rendered file) to `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl`, append the sysbox-runc block from `files/cloud-init/sysbox-install.sh.tftpl`, restart k3s/k3s-agent.

**Sysbox install fails: `unprivileged_userns_clone = 0`**
Some kernels disable this by default. The install script sets it via `/etc/sysctl.d/99-sysbox.conf` and applies live. If it's still failing, the kernel was built without `CONFIG_USER_NS=y` — switch to a kernel that has it.

**Rancher pod CrashLoopBackOff with `failed to call webhook` errors**
cert-manager's webhook isn't ready when Rancher starts. Wait 30s and the deployment retries. If persistent: `kubectl -n cert-manager rollout status deploy/cert-manager-webhook` and ensure it's Available before reapplying Rancher.

**Browser shows `ERR_CONNECTION_REFUSED` for `https://rancher.lan`**
Either (a) `rancher.lan` doesn't resolve — check your hosts file or DNS; (b) Traefik isn't up — `kubectl get svc -n kube-system traefik` should show EXTERNAL-IP `192.168.0.187`; (c) the k3s server VM isn't routable from the operator machine.

---

## Files

```
homelab/
├── versions.tf                  required_version + provider pins
├── providers.tf                 provider blocks (proxmox, helm, kubectl, null, random, local)
├── variables.tf                 all input variables (grouped: Proxmox / NAS / CP / workers / Sysbox / Rancher / Longhorn)
├── locals.tf                    derived values (k3s install env, sysbox_targets map)
├── main.tf                      module calls + null_resources + helm + kubectl + Sysbox + Rancher
├── outputs.tf                   IPs, kubeconfig path, MinIO creds (sensitive), Rancher URL + bootstrap pw (sensitive)
├── terraform.tfvars.example     copy → terraform.tfvars and edit
├── .terraform.lock.hcl          provider lockfile — COMMIT this
├── .gitignore
├── README.md                    this file
├── examples/
│   ├── README.md                            usage notes for each example manifest
│   └── dind-pattern-1-statefulset.yaml      multiple independent docker-in-docker pods (see above)
├── scripts/
│   ├── cluster.conf             single source of truth for cluster topology (IPs, SSH user, key paths,
│   │                            token ID); sourced by every operator-side script
│   ├── authorize-ssh-keys.sh    ONE-TIME bootstrap: pushes ~/.ssh/id_ed25519.pub to Proxmox + workers
│   │                            (idempotent; uses ssh-copy-id, prompts for each host's password once)
│   ├── prep-proxmox.sh          run on Proxmox host (root): API token, templates, network sanity
│   ├── prep-worker.sh           run on each Radxa worker (root): read-only checks (systemd, cgroupv2 memory, userns, sshd) — fails loud with manual fix instructions if anything is wrong
│   ├── deploy-prep.sh           operator-side wrapper: ships prep-proxmox.sh via stdin to root@PVE,
│   │                            and scp+ssh -t prep-worker.sh to each worker (handles sudo password)
│   ├── check-prereqs.sh         run on operator machine (any platform with bash): one-command idempotent —
│   │                            loads .env, prompts for missing token, SSH-checks all hosts, generates
│   │                            terraform.tfvars on first run, exits 0/1.
│   └── merge-kubeconfig.sh      one-time helper: merges the project's ./kubeconfig into ~/.kube/config
│                                (renames default → home-lab; preserves existing clusters). Re-run after
│                                a fresh k3s server bootstrap regenerates ./kubeconfig.
├── modules/
│   ├── proxmox_lxc_minio/       privileged Alpine LXC + MinIO install (variables.tf, main.tf, outputs.tf)
│   └── proxmox_vm_k3s_server/   control-plane VM (clones template, cloud-init for IP) (variables.tf, main.tf, outputs.tf)
└── files/
    ├── cloud-init/
    │   ├── k3s-server-bootstrap.sh.tftpl    qemu-agent + k3s server install, runs in VM via SSH
    │   ├── k3s-worker-bootstrap.sh.tftpl    cgroup pre-flight + MTU + k3s agent join, runs on each worker
    │   ├── minio-bootstrap.sh.tftpl         drives `pct exec` from Proxmox host into the LXC
    │   └── sysbox-install.sh.tftpl          arch-detected sysbox-ce .deb + containerd config.toml.tmpl + restart
    └── helm/
        ├── longhorn-values.yaml.tftpl       replicaCount + defaultDataPath
        └── rancher-values.yaml.tftpl        hostname + ingressClassName + tls.source=rancher
```

## Out of scope (deferred)

- Multi-server k3s HA (single server is fine for home-lab; embedded etcd needs ≥3 server nodes).
- Vault/SOPS for secrets — local 0600 files alongside state are fine for a single-operator setup.
- Remote state backend on the same MinIO — chicken-and-egg on first bootstrap.
- MetalLB for proper LoadBalancer IPs (klipper-lb is fine on a single-node CP).
- Rancher Monitoring (kube-prometheus-stack, ~3GB RAM) — install from the Rancher UI when wanted.
- Rancher Backups chart (snapshots Rancher state to MinIO) — add when you start customising Rancher heavily.
- Real CA-signed cert for Rancher via cert-manager + Let's Encrypt DNS-01 — the self-signed flow is fine on a LAN.
- Hardening the Sysbox `RuntimeClass` (Kyverno / PodSecurityAdmission policies restricting which namespaces can opt in).
- Container image registry mirror (Harbor or distribution) backed by MinIO — useful once image-pull traffic dominates.
