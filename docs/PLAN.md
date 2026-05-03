# Implementation plan (historical)

This is the planning document that drove the initial implementation
of this project. Some sections diverged from the final implementation:

| Original plan | Final state | Why |
|---|---|---|
| Sysbox-CE on every node | **Deferred** — see comment block in `main.tf` | Sysbox 0.6.5 + k3s 1.30 + containerd 1.7.22 has an unresolved CRI v1 service registration bug. Workers fall back to a privileged DinD pattern (see `examples/dind-pattern-1-statefulset.yaml`). |
| Helm `wait` timeout 600s for Longhorn | Bumped to 1200s | ARM64 image pulls (~500 MB × 5 nodes) consistently exceed 10 minutes on first install. |
| `proxmox_lxc.features { nesting=true }` and `mountpoint { … }` blocks | Set via `pct set` over SSH after creation (see `null_resource.bind_mount` in `modules/proxmox_lxc_minio/`) | PVE hardcodes "feature flags / bind mounts only allowed for root@pam"; API tokens are blocked regardless of role. |
| `proxmox_vm_qemu` without `serial { id=0 type="socket" }` | Added | Debian cloud image's kernel cmdline expects a serial console; without it the cloned VM boots blind and cloud-init networking never applies. |
| Telmate provider `= 3.0.1-rc4` | Bumped to `= 3.0.2-rc07` | Earlier RCs require the now-removed `VM.Monitor` privilege; PVE 9 rejects it as invalid. |
| Workers as `ssh_user = "rock"` | `ssh_user = "c4"` | Operator's actual user on the Radxa boards. |

The implementation followed the plan in **two phases** as documented in
`README.md` §"First apply"; this PLAN.md preserves the original reasoning
in case anyone wants to understand *why* the project is shaped the way it is.

---

# Proxmox Hybrid Cluster Automation — OpenTofu Plan

## Context

The user is building a hybrid home-lab Kubernetes cluster on existing hardware: an Intel N150 Proxmox VE 8+ host (32GB DDR5, 2× SATA SSD boot, 4× 1TB NVMe in ZFS pool `nvme-pool`, dual 2.5GbE bonded as `bond0`/`vmbr0`, host IP 192.168.0.185) plus four Radxa Q6A SBCs (RK3576, 4C/4T, 12GB LPDDR5, 500GB NVMe). The original prompt and a refined `infra.md` describe the design; per the user's clarifications, the resolved stack is **k3s on Debian 12 (control plane VM) and Armbian (workers)** with a privileged Alpine LXC running **MinIO** for S3-compatible NAS, all glued together by **OpenTofu** so adding a fifth worker is a one-line change.

The intended outcome is a single-command (modulo a one-time two-phase first apply) IaC project that provisions the full stack: NAS LXC, control-plane VM, four worker joins, Longhorn storage with MinIO as the S3 backup target, and MTU 9000 jumbo frames end-to-end.

The original prompt's `K3s Control Plane` + `Talos Linux` combination was incompatible (Talos has no kubeadm/SSH path; workers must run Talos). The user resolved this by dropping Talos in favor of k3s on Debian/Armbian everywhere — this plan reflects that decision and supersedes any Talos references in `infra.md`.

## Resolved decisions (locked in)

| Item | Decision |
|---|---|
| K8s distribution | k3s (`v1.30.6+k3s1`, pinned) on Debian 12 control-plane + Armbian workers |
| NAS | Privileged Alpine LXC running MinIO (1 core, 4GB RAM, IP 192.168.0.186) |
| NAS bind mount | host `/nvme-pool` → container `/mnt/storage` |
| Control-plane VM | Debian 12 cloud image, 2 cores `cpu=host`, 6GB RAM, 32GB on `local-zfs`, IP 192.168.0.187, qemu-guest-agent + virtio-scsi-single |
| Workers | 4× Radxa Q6A on Armbian, joined as k3s agents via `null_resource` + SSH `remote-exec` (map-keyed `for_each` so a 5th = 1 line) |
| Storage | Longhorn via Helm, MinIO bucket `longhorn-backups` as S3 backup target |
| MTU | 9000 jumbo frames (rolled out in two phases — see Risks) |
| Project location | `C:\Users\chifo\work\home\homelab\` |
| ISO/template strategy | Assume pre-uploaded to Proxmox; document one-time upload in `README.md` |
| Provider auth | `tofu-prov@pve!tofu-token` Administrator-at-`/` token per `ProxmoxApiToken.md`; secret via `TF_VAR_pm_api_token_secret` env var |

## Architecture

```
Operator machine (this Windows host)
  └─ tofu apply
        │
        ├──► Proxmox API (192.168.0.185:8006)
        │       ├─ proxmox_lxc.nas        (Alpine + MinIO, 192.168.0.186)
        │       └─ proxmox_vm_qemu.k3s    (Debian + k3s server, 192.168.0.187)
        │
        ├──► SSH to k3s server VM
        │       ├─ wait for /var/lib/rancher/k3s/server/node-token
        │       ├─ fetch token  → ./.k3s_token  (chmod 600, gitignored)
        │       └─ fetch kubeconfig → ./kubeconfig  (server URL rewritten 127.0.0.1 → 192.168.0.187)
        │
        ├──► SSH to each Radxa worker (parallel, for_each)
        │       └─ install k3s agent with K3S_URL + K3S_TOKEN, set MTU
        │
        └──► Helm + kubectl (config_path = ./kubeconfig)
                ├─ helm_release.longhorn   (chart longhorn/longhorn 1.7.x)
                └─ kubectl_manifest.backuptarget  (Longhorn → MinIO S3)
```

## File layout

Flat root + two small modules. Workers live as a single `null_resource` in the root (a module wrapper would buy nothing).

```
C:\Users\chifo\work\home\homelab\
  versions.tf                         # required_version + required_providers (pinned)
  providers.tf                        # provider blocks (proxmox, helm, kubectl, null, random)
  variables.tf                        # all inputs, grouped by domain via comment headers
  locals.tf                           # derived values (server URL, helm values, etc.)
  main.tf                             # module calls + null_resources for k3s glue
  outputs.tf                          # NAS IP, CP IP, kubeconfig path, MinIO creds (sensitive)
  terraform.tfvars.example            # commit; real .tfvars is gitignored
  .gitignore                          # *.tfvars (except example), *.tfstate*, .terraform/, .k3s_token, kubeconfig
  README.md                           # prereqs (ISO upload, API token, SSH keys), 2-phase first apply, recovery
  modules/
    proxmox_lxc_minio/
      main.tf                         # proxmox_lxc + remote-exec to install/configure MinIO
      variables.tf
      outputs.tf                      # ip, minio_root_user, minio_root_password (sensitive), minio_endpoint
    proxmox_vm_k3s_server/
      main.tf                         # proxmox_vm_qemu + cloud-init for k3s server
      variables.tf
      outputs.tf                      # vm_ip, ssh_user
  files/
    cloud-init/
      k3s-server-user-data.yaml.tftpl # rendered with templatefile() — installs qemu-agent, k3s server, sets MTU, writes ready marker
      minio-bootstrap.sh.tftpl        # installs MinIO binary + systemd unit pointing at /mnt/storage
    helm/
      longhorn-values.yaml.tftpl      # version-pinned chart values (replicaCount, defaultStorageClass)
```

**Why not heavier modularization:** two reuse boundaries actually exist (LXC + VM blueprints). Workers are a `for_each`, not a module — wrapping them would force the helm/kubectl providers above the wrapper and creates the classic "Provider configuration not present" footgun on destroy. One state file is the right call for ~12 resources.

## Provider versions

| Provider | Source | Pin | Why |
|---|---|---|---|
| Proxmox | `Telmate/proxmox` | `= 3.0.1-rc4` | Need the nested `disks` block for the spec'd VirtIO/SCSI layout. 3.x is RC — pin EXACTLY (`=`) because RC-to-RC schema breakage is real. Fallback: `= 2.9.14` with the legacy flat `disk` block. |
| Helm | `hashicorp/helm` | `~> 2.13` | `kubernetes { config_path = ... }` works cleanly. Avoid 3.x (still maturing). |
| Kubectl | `alekc/kubectl` | `~> 2.0` | Maintained fork of `gavinbunney/kubectl` (which is effectively unmaintained since 2022). Same resource names — drop-in. |
| Null | `hashicorp/null` | `~> 3.2` | Worker bootstrap + token/kubeconfig fetch. |
| Random | `hashicorp/random` | `~> 3.6` | `random_password` for MinIO root. |

OpenTofu floor: `required_version = ">= 1.7.0"` (clean state-file format, `terraform_data` if we want to switch from `null_resource` later).

**Skipped:** `hashicorp/kubernetes` (use `kubectl_manifest` instead — it's lazier on plan-time and handles CRD-defined types like Longhorn `BackupTarget` better). `community/ssh-agent` (one-shot file copies don't justify a niche provider).

## Variable schema (grouped via comment headers in one file)

```
# === Proxmox auth ===  (pm_api_url, pm_api_token_id, pm_api_token_secret [sensitive],
#                        pm_tls_insecure=true, pm_node_name="pve")
# === Network ===       (lan_cidr, lan_gateway, lan_dns, bridge="vmbr0", mtu=1500 initially, see Risks)
# === NAS LXC ===       (nas_hostname, nas_ip="192.168.0.186", nas_cores=1, nas_memory_mb=4096,
#                        nas_rootfs_size="8G", nas_storage_pool="local-zfs",
#                        nas_template="local:vztmpl/alpine-3.19-default_*.tar.xz",
#                        nas_bind_host_path="/nvme-pool", nas_bind_ct_path="/mnt/storage",
#                        minio_version, minio_bucket_longhorn="longhorn-backups")
# === Control plane ===  (cp_hostname, cp_ip="192.168.0.187", cp_cores=2, cp_sockets=1,
#                         cp_memory_mb=6144, cp_disk_size="32G", cp_storage_pool="local-zfs",
#                         cp_cloud_image_iso="local:iso/debian-12-genericcloud-amd64.qcow2",
#                         cp_bios="seabios" — see Risks, k3s_version="v1.30.6+k3s1",
#                         k3s_extra_server_args=["--disable=traefik"])
# === Workers ===
# workers = map(object({
#   name      = string  # k8s node name
#   address   = string  # SSH IP
#   ssh_user  = string  # Armbian default ("rock"/"radxa" — verify per board)
#   ssh_key   = string  # path to private key
#   labels    = map(string)
#   taints    = list(string)
# }))
# Default: q6a-1..q6a-4 at 192.168.0.191..194
# === Longhorn ===     (longhorn_chart_version="1.7.2", longhorn_namespace="longhorn-system",
#                       longhorn_replica_count=2, longhorn_default_storage_class_name="longhorn")
# === Local artefacts === (local_kubeconfig_path="${path.root}/kubeconfig",
#                          local_token_path="${path.root}/.k3s_token")
```

**Workers as `map(object)`, not `list`** — `for_each` keys by name, so adding a 5th worker doesn't churn the others the way a list append would after any reordering.

## Resource dependency graph and apply order

```
random_password.minio_root
        │
        ▼
module.nas_minio  ──┐                module.k3s_server  (parallel with NAS — no cross-dep)
                    │                         │
                    │              null_resource.wait_for_k3s_ready
                    │                         │   (remote-exec poll until node-token exists
                    │                         │    AND kubectl get nodes is Ready)
                    │                         ▼
                    │              null_resource.fetch_token       (local-exec scp; writes ./.k3s_token chmod 600)
                    │              null_resource.fetch_kubeconfig  (local-exec scp + sed s/127.0.0.1/${cp_ip}/; writes ./kubeconfig chmod 600)
                    │                         │
                    │              data.local_sensitive_file.k3s_token       (depends_on fetch_token)
                    │              data.local_sensitive_file.kubeconfig      (depends_on fetch_kubeconfig)
                    │                         │
                    │              null_resource.bootstrap_worker[for_each]  (parallel × 4; uses K3S_URL + K3S_TOKEN)
                    │                         │
                    │              ┌──────────┴──────────┐
                    └──────────────►│  helm_release.longhorn       (depends_on values(bootstrap_worker))
                                   │  kubectl_manifest.backuptarget (depends_on helm_release + module.nas_minio)
                                   └─────────────────────┘
```

**Where `depends_on` is required (not just recommended):**
1. `wait_for_k3s_ready` → `module.k3s_server` (the VM resource completes when QEMU boots; cloud-init runs async).
2. `fetch_token` / `fetch_kubeconfig` → `wait_for_k3s_ready` (don't read what cloud-init hasn't written).
3. `bootstrap_worker[*]` → `data.local_sensitive_file.k3s_token` AND `wait_for_k3s_ready`.
4. `helm_release.longhorn` → `values(null_resource.bootstrap_worker)` (Longhorn `replicaCount=2` only makes sense if ≥2 worker nodes are Ready).
5. `kubectl_manifest.backuptarget` → `helm_release.longhorn` (CRD must exist) AND `module.nas_minio` (S3 must respond).

## Critical patterns

### K3s join token bridge (the trickiest piece)

**Pattern: `null_resource.fetch_token` → local file → `data "local_sensitive_file"` → referenced from worker bootstrap.**

```
1. null_resource.wait_for_k3s_ready  (remote-exec):
     while ! sudo test -f /var/lib/rancher/k3s/server/node-token; do sleep 2; done
     while ! sudo k3s kubectl get nodes 2>/dev/null | grep -q ' Ready '; do sleep 2; done

2. null_resource.fetch_token  (local-exec, depends_on wait_for_k3s_ready):
     ssh -i <key> debian@${cp_ip} sudo cat /var/lib/rancher/k3s/server/node-token \
       > ${local_token_path} && chmod 600 ${local_token_path}

3. data "local_sensitive_file" "k3s_token" {
     filename   = local_token_path
     depends_on = [null_resource.fetch_token]
   }
   # value: data.local_sensitive_file.k3s_token.content (auto-sensitive)

4. null_resource.bootstrap_worker[each.key]  remote-exec environment:
     K3S_URL   = "https://${cp_ip}:6443"
     K3S_TOKEN = data.local_sensitive_file.k3s_token.content
     INSTALL_K3S_VERSION = var.k3s_version
   inline:
     curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC=agent sh -
```

**Worker `triggers` (re-bootstrap semantics):**
```
triggers = {
  token_hash  = sha256(data.local_sensitive_file.k3s_token.content)
  server_url  = "https://${cp_ip}:6443"
  k3s_version = var.k3s_version
  worker_addr = each.value.address
}
```
Rotating the token, changing the server URL, or bumping k3s version → re-runs the installer. Label/taint changes do NOT re-bootstrap (apply via `kubectl` instead).

### Kubeconfig fetch + URL rewrite

K3s writes `/etc/rancher/k3s/k3s.yaml` with `server: https://127.0.0.1:6443`. The Helm provider runs on the operator's machine and would try 127.0.0.1 locally. Fix in the same `local-exec`:

```
ssh -i <key> debian@${cp_ip} sudo cat /etc/rancher/k3s/k3s.yaml \
  | sed 's|https://127.0.0.1:6443|https://${cp_ip}:6443|' \
  > ${local_kubeconfig_path} && chmod 600 ${local_kubeconfig_path}
```

The k3s server install MUST include `--tls-san ${cp_ip}` so the rewritten URL doesn't trip a cert hostname mismatch.

### Helm + kubectl provider config

```
data "local_sensitive_file" "kubeconfig" {
  filename   = var.local_kubeconfig_path
  depends_on = [null_resource.fetch_kubeconfig]
}

provider "helm"   { kubernetes { config_path = var.local_kubeconfig_path } }
provider "kubectl" { config_path = var.local_kubeconfig_path  load_config_file = true }
```

The data source isn't strictly read by the provider but it gives OpenTofu the dep edge.

### MinIO bootstrap inside the LXC

After `proxmox_lxc.nas` is created, a `null_resource` runs `pct exec ${ctid} -- /bin/sh -c '...'` from the operator machine over SSH to the Proxmox host (or a `remote-exec` directly into the LXC if SSH is enabled there). Steps: `apk add --no-cache minio` (or download release binary if not packaged), render `/etc/conf.d/minio` with `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD`/`MINIO_VOLUMES=/mnt/storage`, install OpenRC service, `rc-service minio start`, then `mc mb local/longhorn-backups`.

## Sensitive value handling

| Item | Storage | Output | Notes |
|---|---|---|---|
| Proxmox API token secret | `TF_VAR_pm_api_token_secret` env var (do NOT put in `.tfvars`) | none | Marked `sensitive=true` in `variables.tf`. |
| MinIO root user | literal | `output { sensitive = true }` | OK to be deterministic ("admin"). |
| MinIO root password | `random_password` (32 chars, no special) | `output { sensitive = true }` | Used by Longhorn BackupTarget secret. |
| K3s join token | local file `./.k3s_token` (chmod 600, gitignored) | optional sensitive output | Treat state itself as sensitive — `chmod 600 terraform.tfstate`. |
| Kubeconfig | local file `./kubeconfig` (chmod 600, gitignored) | `output kubeconfig_path` (path, not content) | |
| Longhorn S3 secret | k8s `Secret` created by `kubectl_manifest` | none | Lives only in cluster. |

`.gitignore` keeps `*.tfvars` (except `terraform.tfvars.example`), `*.tfstate*`, `.terraform/`, `.k3s_token`, `kubeconfig`, `crash.log`. **Commit `.terraform.lock.hcl`** — the lockfile is the whole point of pinning.

## MTU 9000 propagation

| Hop | Owner | OpenTofu? | How |
|---|---|---|---|
| Physical switch ports | switch admin | NO | Manual; verify jumbo enabled. |
| Proxmox host `bond0` + `vmbr0` | `/etc/network/interfaces` on PVE | NO | Manual one-time; document in README. |
| LXC `eth0` | provider `proxmox_lxc.network[0].mtu` | YES | Set in module. |
| VM `net0` | provider `proxmox_vm_qemu.network[0].mtu` (3.x) | YES | If on 2.9.x fallback, set via cloud-init netplan. |
| Inside VM (Debian) | cloud-init `network-config` template | YES | Render `/etc/netplan/50-cloud-init.yaml` with `mtu: 9000`. |
| Inside worker (Armbian) | bootstrap `remote-exec` | YES | Detect `/etc/netplan` vs `/etc/systemd/network` vs `/etc/network/interfaces.d/`, write the right file, `ip link set eth0 mtu 9000`. |
| Flannel VXLAN overlay | k3s install with `--flannel-iface eth0` | PARTIAL | Flannel auto-derives pod-network MTU = host MTU − 50. Verify. |

**Verification:** `ping -M do -s 8972 <other-node>` from each node (8972 = 9000 − 20 IP − 8 ICMP). 0% loss = MTU OK.

## Top 5 risks (ranked by likelihood × impact)

1. **First-apply chicken-and-egg with helm/kubectl providers** (HIGH × HIGH). The Helm provider initializes once at apply start; if `./kubeconfig` doesn't exist yet, every plan/apply fails with "no such file." **Mitigation:** the first bootstrap is a documented two-phase apply (see next section). Every apply after that is single-command.

2. **Privileged LXC + bind mount UID/GID** (HIGH × HIGH). `unprivileged=false` means root in container = root on host, which is what makes MinIO writes to `/nvme-pool` Just Work. If anyone ever flips `unprivileged=true` without re-doing the mount strategy, ZFS perms break silently. **Mitigation:** add a module `precondition`: `condition = var.unprivileged == false` with a clear error message.

3. **Q6A cgroupv2 / `memory` cgroup missing on Armbian for RK3576** (HIGH × HIGH). Some RK3576 Armbian builds disable `memory` cgroup; kubelet refuses to start. **Mitigation:** worker bootstrap script does a pre-flight `grep -q '^memory.*1$' /proc/cgroups` and fails loudly with the exact `armbianEnv.txt` line to add (`extraargs=cgroup_enable=memory cgroup_memory=1 systemd.unified_cgroup_hierarchy=1`) and the reboot instruction. Document as a pre-bootstrap manual check in README.

4. **MTU mismatch causing silent CNI breakage** (MEDIUM × HIGH). Nodes register Ready but pod-to-pod TLS handshakes fail mid-stream. **Mitigation:** roll MTU 9000 in two phases — first apply at MTU 1500 (verify cluster forms, Longhorn installs), then flip `var.mtu = 9000` and re-apply. Document explicitly in README. Do NOT do it all at once on first bootstrap.

5. **`telmate/proxmox` 3.x is RC; schema can shift between RCs** (MEDIUM × MEDIUM). **Mitigation:** pin with `=`, not `~>`. Test upgrades manually. Fallback to `2.9.14` documented for if you hit a blocker.

**Honorable mentions:** Debian cloud images don't ship `qemu-guest-agent` — install via cloud-init `runcmd` or the VM resource times out waiting for an IP. Cloud-init drive must be on `ide2` (Telmate convention). `bios = "seabios"` is the right v1 default — `ovmf` requires an `efidisk` resource that's finicky in the Telmate provider. `scsihw = "virtio-scsi-single"` + `iothread = true` requires the disk on a `scsi` bus, not `sata`.

## First-apply procedure (two-phase, one-time only)

```pwsh
# Set the API token secret (do NOT put in tfvars):
$env:TF_VAR_pm_api_token_secret = "<paste-secret-from-pveum>"

cd C:\Users\chifo\work\home\homelab
tofu init

# Phase 1: bring up Proxmox resources + k3s server, fetch kubeconfig + token.
tofu apply `
  -target=module.nas_minio `
  -target=module.k3s_server `
  -target=null_resource.wait_for_k3s_ready `
  -target=null_resource.fetch_token `
  -target=null_resource.fetch_kubeconfig

# Phase 2: providers can now read ./kubeconfig; bootstrap workers + Longhorn.
tofu apply
```

Subsequent applies (idempotent updates, scaling workers, version bumps) are single-command: `tofu apply`.

## Verification plan (end-to-end)

Run in order; each step has a pass criterion.

**A. Proxmox layer** (on the Proxmox host shell):
- `pct list` → expect `nas-minio` Running.
- `pct exec <CTID> -- ip a show eth0` → 192.168.0.186/24, MTU as configured.
- `pct exec <CTID> -- mount | grep storage` → `/nvme-pool on /mnt/storage`.
- `qm list` → expect `k3s-server-01` Running.
- `qm guest cmd <VMID> network-get-interfaces` → eth0 with 192.168.0.187.

**B. MinIO** (from operator):
- `curl -sI http://192.168.0.186:9000/minio/health/live` → `200`.
- `mc alias set home http://192.168.0.186:9000 <user> <pw>` then `mc admin info home`.
- `mc ls home` → see `longhorn-backups/`.

**C. K3s cluster** (with `KUBECONFIG=$PWD/kubeconfig`):
- `kubectl get nodes -o wide` → 5 Ready (1 server amd64 + 4 workers arm64), correct INTERNAL-IP per node.
- `kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.nodeInfo.architecture}{"\n"}{end}'` confirms architectures.

**D. Pod-to-pod networking + MTU end-to-end:**
- Spawn a busybox pod on amd64 (`nodeSelector: kubernetes.io/arch=amd64`) and another on arm64.
- From amd64 pod: `ping -M do -s 8922 <arm-pod-ip>` → 0% loss (8922 = pod MTU 8950 − 28). If fragmentation, MTU broken.

**E. Longhorn:**
- `kubectl -n longhorn-system get pods` → all Running (manager, instance-manager, ui).
- `kubectl get storageclass` → `longhorn` present (default if so configured).
- `kubectl -n longhorn-system get backuptarget` → 1 entry, `Available=true`.
- Smoke PVC: `kubectl apply` a 1Gi PVC with `storageClassName: longhorn`, expect `Bound` within 30s, then delete.

**F. Backup round-trip (ties MinIO + Longhorn):**
- Via Longhorn UI (port-forward `svc/longhorn-frontend`), create a volume → snapshot → backup.
- `mc ls home/longhorn-backups/backupstore/` → expect `volumes/` tree appearing.

**G. Re-apply idempotency:**
- `tofu plan` after a successful apply → MUST report `No changes.` If drift, fix the non-idempotent provisioner before declaring done.

## Critical files (to be created during implementation)

In priority order (most load-bearing first):
- `C:\Users\chifo\work\home\homelab\main.tf`
- `C:\Users\chifo\work\home\homelab\providers.tf`
- `C:\Users\chifo\work\home\homelab\versions.tf`
- `C:\Users\chifo\work\home\homelab\variables.tf`
- `C:\Users\chifo\work\home\homelab\modules\proxmox_vm_k3s_server\main.tf`
- `C:\Users\chifo\work\home\homelab\modules\proxmox_lxc_minio\main.tf`
- `C:\Users\chifo\work\home\homelab\files\cloud-init\k3s-server-user-data.yaml.tftpl`
- `C:\Users\chifo\work\home\homelab\files\cloud-init\minio-bootstrap.sh.tftpl`
- `C:\Users\chifo\work\home\homelab\files\helm\longhorn-values.yaml.tftpl`
- `C:\Users\chifo\work\home\homelab\outputs.tf`
- `C:\Users\chifo\work\home\homelab\locals.tf`
- `C:\Users\chifo\work\home\homelab\terraform.tfvars.example`
- `C:\Users\chifo\work\home\homelab\.gitignore`
- `C:\Users\chifo\work\home\homelab\README.md`

## References (existing files consulted)

- `C:\Users\chifo\work\home\infra.md` — refined hardware/architecture spec. Note: the Talos references in this file are superseded by the user's k3s decision; the RAM/CPU/storage allocations and Longhorn/MinIO design are kept.
- `C:\Users\chifo\work\home\ProxmoxApiToken.md` — accurate prereq doc. Use the `tofu-prov@pve!tofu-token` token format with Administrator role at `/` (required for privileged LXC + host bind mounts; lower roles return `403 Forbidden`).
- Provider schemas validated against Telmate's GitHub master docs (LXC `mountpoint`/`network`/`features`, VM `disks`/`cpu`/`network`/`ipconfig0`/`scsihw`).

## Out of scope for v1 (deferred)

- Multi-server k3s HA (single server is fine for home-lab; embedded etcd would need ≥3 server nodes).
- Vault/SOPS for secret management — local 0600 files alongside state are fine for a single-operator home lab.
- Remote state backend on the same MinIO — chicken-and-egg on first bootstrap; defer.
- ARM64 image registry mirror / pull-through cache — add later when image-pull traffic becomes a problem.

---

# Improvement v2: Sysbox + Rancher (added 2026-05-03)

## v2 Context

v1 ships a working hybrid k3s cluster with persistent storage. v2 adds two operational capabilities the user asked for:

1. **Sysbox-CE on every k3s node** (control-plane VM + 4 Radxa workers) so pods can run Docker / `docker compose` / systemd / kubelet inside themselves without `privileged: true`. This is the only path to a real Docker-in-Docker (DinD) story on k3s — vanilla `docker:dind` images require `privileged: true`, which most cluster admins (and Rancher's policies) reject.
2. **Rancher Server** in-cluster, for a web UI that gives cluster, workload, pod, log, and shell access — replacing the patchwork of `kubectl`, k9s, and the Longhorn UI with one place.

These are additive: existing v1 resources keep working unchanged. No data migration. Workers do not need to be reflashed. The cluster suffers brief per-node outages when k3s restarts to pick up the new containerd config.

## v2 Resolved decisions (locked in)

| Item | Decision |
|---|---|
| Sysbox scope | k3s nodes only (1 server VM + 4 workers). NOT installed in the MinIO LXC — it's a single-process container; LXC + Sysbox is brittle. |
| Sysbox version | Pinned `v0.6.5` (latest stable Sysbox-CE; both amd64 and arm64 .deb packages published by Nestybox). |
| Sysbox install method | Direct .deb install over SSH per node (NOT the `sysbox-deploy-k8s` DaemonSet — that DS targets CRI-O; k3s uses containerd, where the manual install is the documented path). |
| k3s containerd hook | `/var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl` extending the built-in `base` template (k3s regenerates `config.toml` on every start; the `.tmpl` file is the only persistent override). |
| Sysbox runtime exposure | k8s `RuntimeClass` named `sysbox-runc` with `handler: sysbox-runc`. Pods opt in via `runtimeClassName: sysbox-runc`. |
| Ingress | Re-enable Traefik (drop `--disable=traefik` from `k3s_extra_server_args`). k3s ships Traefik as a HelmChart manifest — comes back automatically on server restart. |
| TLS | cert-manager + self-signed `ClusterIssuer`. Rancher's chart default `ingress.tls.source=rancher` self-signs internally; we override with `ingress.tls.source=secret` and reference a cert-manager-issued cert so the same issuer can serve other workloads. |
| Rancher version | Pinned `v2.10.x` Helm chart (latest stable line at decision time; multi-arch images, ARM64 supported since v2.7). |
| Rancher hostname | `rancher.lan`, resolved via the operator's hosts file or local DNS to the k3s server VM IP `192.168.0.187` (Traefik's LoadBalancer service is published on node IPs by k3s's klipper-lb / svclb). |
| Rancher monitoring | Skipped for v2; can be installed later from the Rancher UI when desired (saves ~3GB RAM upfront). |
| Rancher bootstrap password | Set explicitly via `--set bootstrapPassword=...`, sourced from a `random_password` resource (regenerable via `tofu taint`). Marked sensitive. |
| Rollout style | Incremental (no destroy/recreate). Run `tofu apply` against the existing v1 cluster; Sysbox installs sequentially per node with brief k3s/k3s-agent restarts. |

## v2 Architecture (delta)

```
                         (existing v1 …)
                                │
                                ▼
                  module.k3s_server (Debian VM)
                                │
                                ▼
                  null_resource.k3s_server_bootstrap     (existing)
                                │
                                ▼
                  null_resource.sysbox_install["server"] (NEW: SSH; install sysbox-ce, write
                                │                              config.toml.tmpl, restart k3s)
                                │
                  null_resource.bootstrap_worker[for_each] (existing)
                                │
                                ▼
                  null_resource.sysbox_install[for_each workers]  (NEW: same script, ARM64 .deb,
                                │                                       restart k3s-agent)
                                │
                                ▼
                  data.local_sensitive_file.kubeconfig  (existing — providers ready)
                                │
       ┌────────────────────────┼─────────────────────────┐
       ▼                        ▼                         ▼
 helm_release.longhorn   helm_release.cert_manager   kubectl_manifest.runtimeclass_sysbox  (NEW)
   (existing)             (NEW)                       (NEW)
                              │
                              ▼
                  kubectl_manifest.selfsigned_clusterissuer  (NEW)
                              │
                              ▼
                  helm_release.rancher  (NEW; depends on cert-manager + Traefik up)
                              │
                              ▼
                  kubectl_manifest.rancher_ingress_class_patch  (NEW; ensures Rancher's
                                                                  Ingress targets Traefik)
```

Sysbox installs serialize PER NODE (each restarts its own k3s/k3s-agent), but the 5 nodes run in parallel (`for_each`). The whole rollout adds ~2 minutes to a fresh apply or ~3 minutes to an incremental apply against an existing cluster.

## v2 New + modified files

**New:**
- `files/cloud-init/sysbox-install.sh.tftpl` — runs over SSH on each node. Installs sysbox-ce .deb (arch-detected), writes `config.toml.tmpl`, restarts the relevant k3s service, verifies sysbox-runc binary is registered.
- `files/helm/rancher-values.yaml.tftpl` — Rancher chart values (hostname, replicas, ingressClassName=traefik, tls source).

**Modified:**
- `variables.tf` — add Sysbox + Rancher + cert-manager variable groups (see schema below).
- `locals.tf` — drop `--disable=traefik` from the default `k3s_extra_server_args` (or expose it as a separate `disable_traefik` bool that defaults `false` now).
- `main.tf` — add 4 new resources: `null_resource.sysbox_install` (for_each over server + workers), `kubectl_manifest.runtimeclass_sysbox`, `helm_release.cert_manager`, `kubectl_manifest.selfsigned_clusterissuer`, `helm_release.rancher`. Optionally `random_password.rancher_bootstrap`.
- `outputs.tf` — add `rancher_url`, `rancher_bootstrap_password` (sensitive), `sysbox_runtime_class_name`.
- `README.md` — Sysbox usage section (RuntimeClass, example pod), Rancher access section (hostname, hosts-file entry, first-login flow), incremental rollout procedure, new troubleshooting entries.
- `terraform.tfvars.example` — surface the Rancher hostname + sysbox/rancher version pins as commented examples.

**Unchanged:** the LXC and VM modules don't need to be touched. All v2 work is at the root level.

## v2 Variable schema additions

```
# === Sysbox ===
# sysbox_version       string  default "0.6.5"  (Sysbox-CE release; downloads.nestybox.com naming convention)
# sysbox_runtime_name  string  default "sysbox-runc"  (k8s RuntimeClass name; pods opt in via this)

# === Cert-manager ===
# cert_manager_chart_version  string  default "v1.16.2"
# cert_manager_namespace      string  default "cert-manager"

# === Rancher ===
# rancher_chart_version       string  default "2.10.1"
# rancher_namespace           string  default "cattle-system"
# rancher_hostname            string  default "rancher.lan"  (operator must resolve this to var.cp_ip)
# rancher_replicas            number  default 1   (single-node home lab; 3 for HA needs LB)
# rancher_bootstrap_password  string  sensitive=true
#                                     default = null → triggers random_password generation
#                                     (allows operator to override with a stable known value if desired)

# === Traefik (existing k3s ingress, re-enabled) ===
# (No new var; we just remove --disable=traefik from var.k3s_extra_server_args.
#  Optionally add `enable_traefik = true` and have locals.tf compute extra args.)
```

## v2 Resource dependency additions

| New resource | depends_on (explicit) | Notes |
|---|---|---|
| `null_resource.sysbox_install["server"]` | `null_resource.k3s_server_bootstrap` | Restarts k3s; brief CP outage. |
| `null_resource.sysbox_install[for_each in workers]` | `null_resource.bootstrap_worker[each.key]` | Each restarts only its own k3s-agent. Parallel across workers. |
| `kubectl_manifest.runtimeclass_sysbox` | `data.local_sensitive_file.kubeconfig`, all `sysbox_install` (so the runtime exists everywhere when the class is created) | Cluster-scoped; one apply. |
| `helm_release.cert_manager` | `data.local_sensitive_file.kubeconfig`, all `bootstrap_worker` (so cert-manager has nodes to schedule on) | Independent of Sysbox. |
| `kubectl_manifest.selfsigned_clusterissuer` | `helm_release.cert_manager` | Cluster-scoped. |
| `helm_release.rancher` | `helm_release.cert_manager`, `kubectl_manifest.selfsigned_clusterissuer`, `null_resource.k3s_server_bootstrap` (so Traefik HelmChart has had time to deploy) | Long apply (5–10 min: cattle-system, fleet, agents). Set `timeout = 900`. |

The dependency `helm_release.rancher` → "Traefik is up" is implicit, not explicit. If Traefik takes too long to deploy, the Rancher Ingress might be created before Traefik watches it; Traefik picks it up on its next reconcile loop. No action needed unless the timeout is hit.

## v2 Critical patterns

### A. Sysbox-CE install on a k3s node

`files/cloud-init/sysbox-install.sh.tftpl` (rendered per-node, runs as root over SSH):

```bash
#!/bin/bash
set -euo pipefail
SYSBOX_VERSION='${sysbox_version}'           # e.g. "0.6.5"
K3S_SERVICE='${k3s_service}'                  # "k3s" on server, "k3s-agent" on workers

ARCH=$(dpkg --print-architecture)            # "amd64" or "arm64"
DEB_URL="https://downloads.nestybox.com/sysbox/releases/v$${SYSBOX_VERSION}/sysbox-ce_$${SYSBOX_VERSION}-0.linux_$${ARCH}.deb"

# 1. Install dependencies (Sysbox needs fuse/fuse3 + iptables on most distros)
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq fuse iptables wget

# 2. Install sysbox-ce (idempotent — apt-get install on the same .deb is a no-op)
INSTALLED_VERSION=$(dpkg-query -W -f='$${Version}' sysbox-ce 2>/dev/null || echo "")
if [ "$INSTALLED_VERSION" != "$${SYSBOX_VERSION}-0" ]; then
  wget -q -O /tmp/sysbox-ce.deb "$DEB_URL"
  apt-get install -y -qq /tmp/sysbox-ce.deb
  rm -f /tmp/sysbox-ce.deb
fi

# 3. Configure k3s containerd to expose sysbox-runc as a runtime.
#    {{ template "base" . }} is k3s's own template variable that expands to the default config.
mkdir -p /var/lib/rancher/k3s/agent/etc/containerd
cat > /var/lib/rancher/k3s/agent/etc/containerd/config.toml.tmpl <<'TOMLEOF'
{{ template "base" . }}

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.sysbox-runc]
  runtime_type = "io.containerd.runc.v2"
  runtime_root = "/run/sysbox-runc"
  pod_annotations = ["nestybox.com/*", "io.kubernetes.cri-o.*"]
  privileged_without_host_devices = false

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.sysbox-runc.options]
  BinaryName = "/usr/bin/sysbox-runc"
  SystemdCgroup = false
TOMLEOF

# 4. Restart k3s (or k3s-agent) to pick up the new containerd config.
systemctl restart "$K3S_SERVICE"

# 5. Verify
sleep 5
[ -x /usr/bin/sysbox-runc ] || { echo "ERROR: sysbox-runc binary missing"; exit 1; }
systemctl is-active --quiet "$K3S_SERVICE" || { echo "ERROR: $K3S_SERVICE failed to restart"; exit 1; }
echo "Sysbox $${SYSBOX_VERSION} installed and registered on $(hostname)"
```

**HCL wrapper (`null_resource.sysbox_install`):**

```hcl
locals {
  # Combine server + workers into one map keyed for for_each.
  sysbox_targets = merge(
    {
      "server" = {
        address      = var.cp_ip
        ssh_user     = var.cp_ssh_user
        ssh_key      = var.cp_ssh_private_key_path
        k3s_service  = "k3s"
        depends_node = null_resource.k3s_server_bootstrap.id
      }
    },
    {
      for k, w in var.workers : k => {
        address      = w.address
        ssh_user     = w.ssh_user
        ssh_key      = w.ssh_key
        k3s_service  = "k3s-agent"
        depends_node = null_resource.bootstrap_worker[k].id
      }
    },
  )
}

resource "null_resource" "sysbox_install" {
  for_each = local.sysbox_targets

  triggers = {
    sysbox_version = var.sysbox_version
    node_addr      = each.value.address
    upstream_id    = each.value.depends_node    # auto-rerun if the underlying node was re-bootstrapped
  }

  connection {
    type        = "ssh"
    host        = each.value.address
    user        = each.value.ssh_user
    private_key = file(pathexpand(each.value.ssh_key))
    timeout     = "10m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/files/cloud-init/sysbox-install.sh.tftpl", {
      sysbox_version = var.sysbox_version
      k3s_service    = each.value.k3s_service
    })
    destination = "/tmp/sysbox-install.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/sysbox-install.sh",
      "sudo /tmp/sysbox-install.sh",
      "rm -f /tmp/sysbox-install.sh",
    ]
  }
}
```

### B. RuntimeClass exposing sysbox to pods

```hcl
resource "kubectl_manifest" "runtimeclass_sysbox" {
  depends_on = [
    null_resource.sysbox_install,
    data.local_sensitive_file.kubeconfig,
  ]

  yaml_body = yamlencode({
    apiVersion = "node.k8s.io/v1"
    kind       = "RuntimeClass"
    metadata   = { name = var.sysbox_runtime_name }
    handler    = var.sysbox_runtime_name
  })
}
```

**Pod usage** (documented in README, not in the .tf):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: docker-in-pod
spec:
  runtimeClassName: sysbox-runc
  containers:
    - name: dind
      image: docker:24-dind
      # No `securityContext.privileged: true` needed.
```

### C. Re-enabling Traefik

`locals.tf` change:

```hcl
locals {
  # OLD: var.k3s_extra_server_args defaulted to ["--disable=traefik"].
  # NEW: drop the --disable=traefik default so k3s ships its built-in Traefik HelmChart.
  k3s_server_install_env = {
    INSTALL_K3S_VERSION = var.k3s_version
    INSTALL_K3S_EXEC = trim(join(" ", concat([
      "server",
      "--write-kubeconfig-mode=644",
      "--node-ip=${var.cp_ip}",
      "--tls-san=${var.cp_ip}",
      "--flannel-iface=eth0",
    ], var.k3s_extra_server_args)), " ")
  }
}
```

`variables.tf` change: change the `k3s_extra_server_args` default from `["--disable=traefik"]` to `[]`.

This change to the variable's default ALSO changes the trigger hash for `null_resource.k3s_server_bootstrap` (because `k3s_install_exec` is in the triggers). On `tofu apply`, the server bootstrap re-runs, which re-installs k3s. **k3s install script is idempotent on `INSTALL_K3S_VERSION` match — it will not re-download or destroy state**, but it will re-run the script and re-issue the systemd unit. Brief CP outage. Document in README.

After Traefik comes up: `kubectl get svc -n kube-system traefik` shows a `LoadBalancer` service with `EXTERNAL-IP: 192.168.0.187` (k3s's klipper-lb publishes on node IPs). Rancher's Ingress will route via this.

### D. cert-manager + self-signed ClusterIssuer

```hcl
resource "helm_release" "cert_manager" {
  depends_on = [
    null_resource.bootstrap_worker,
    data.local_sensitive_file.kubeconfig,
  ]

  name             = "cert-manager"
  namespace        = var.cert_manager_namespace
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version

  set {
    name  = "crds.enabled"
    value = "true"
  }

  timeout = 300
  wait    = true
}

resource "kubectl_manifest" "selfsigned_clusterissuer" {
  depends_on = [helm_release.cert_manager]
  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata   = { name = "selfsigned-issuer" }
    spec = { selfSigned = {} }
  })
}
```

The CRDs come in via `crds.enabled=true` (current chart flag — older docs used `installCRDs=true` which the chart now translates internally; both work but `crds.enabled` is the canonical name).

### E. Rancher install

```hcl
# Always create — cheap and avoids the count=0 index-on-empty-list footgun
# in conditionals (Terraform evaluates both branches of `?:` at plan time).
resource "random_password" "rancher_bootstrap" {
  length  = 24
  special = false
}

locals {
  # coalesce returns the first non-null/non-empty value: operator override wins; otherwise random.
  rancher_bootstrap = sensitive(coalesce(
    var.rancher_bootstrap_password,
    random_password.rancher_bootstrap.result,
  ))
}

resource "helm_release" "rancher" {
  depends_on = [
    helm_release.cert_manager,
    kubectl_manifest.selfsigned_clusterissuer,
    null_resource.k3s_server_bootstrap,   # Traefik must be up
    kubectl_manifest.runtimeclass_sysbox, # not strictly required, but lets Rancher list the class
  ]

  name             = "rancher"
  namespace        = var.rancher_namespace
  create_namespace = true
  repository       = "https://releases.rancher.com/server-charts/stable"
  chart            = "rancher"
  version          = var.rancher_chart_version

  values = [templatefile("${path.module}/files/helm/rancher-values.yaml.tftpl", {
    hostname           = var.rancher_hostname
    replicas           = var.rancher_replicas
    ingress_class_name = "traefik"
  })]

  set_sensitive {
    name  = "bootstrapPassword"
    value = local.rancher_bootstrap
  }

  timeout = 900   # cattle-system + fleet + agents take a while on first install
  wait    = true
}
```

Rancher values template (`files/helm/rancher-values.yaml.tftpl`):

```yaml
hostname: ${hostname}
replicas: ${replicas}

ingress:
  ingressClassName: ${ingress_class_name}
  tls:
    source: secret  # use cert issued via cert-manager (we'll add a Certificate later if needed)
                    # 'rancher' here would have Rancher self-sign internally; 'secret' uses an existing Secret named tls-rancher-ingress
                    # On first install with empty Secret, Rancher's chart bootstraps a placeholder cert; you can rotate by issuing a real cert via cert-manager later.

# Multi-arch scheduling — let Rancher land wherever; images are multi-arch since v2.7.
antiAffinity: preferred
```

(For absolute simplicity in v2, switch `tls.source: rancher` to use Rancher's internal self-signing and skip the cert-manager Certificate dance entirely. The cert-manager is still useful for OTHER workloads. The plan keeps cert-manager for future use even if Rancher self-signs.)

### F. Hosts-file resolution for `rancher.lan`

The plan does NOT manage DNS. The user adds an entry on each operator machine that wants browser access:

```
192.168.0.187   rancher.lan
```

(Windows: `C:\Windows\System32\drivers\etc\hosts`. macOS/Linux: `/etc/hosts`.)

If the home network has Pi-hole / OPNsense / a router with local DNS, register `rancher.lan → 192.168.0.187` there for cluster-wide resolution.

## v2 Sensitive value handling additions

| Item | Storage | Output | Notes |
|---|---|---|---|
| Rancher bootstrap password | `random_password.rancher_bootstrap` (or operator-provided var) | `output { sensitive = true }` | Used to log in for the first time; Rancher prompts to set a new admin password on first login. After that, this value is largely a curiosity. |
| Sysbox-CE .deb package | downloaded fresh per node from Nestybox CDN | none | Hash-verify in the install script (optional improvement). |
| TLS material | cert-manager–managed Secrets in `cattle-system` namespace | none | Lives only in the cluster. |

No new state-file secrets beyond the bootstrap password (and even that can be operator-supplied so it never lands in state — pass via `TF_VAR_rancher_bootstrap_password`).

## v2 Top risks (additive)

1. **Sysbox + k3s containerd template breakage** (HIGH × HIGH). The `{{ template "base" . }}` directive depends on k3s's internal templating. If a future k3s release renames or removes the `base` template, the override silently fails (k3s falls back to default config, sysbox-runc isn't registered). **Mitigation:** the install script verifies after restart that the runtime is registered (`crictl info | grep sysbox-runc` or query containerd directly). README documents the recovery: re-render the tmpl from k3s's current default config.

2. **k3s server restart on Traefik re-enable** (MEDIUM × MEDIUM). Re-enabling Traefik changes the install_exec, which retriggers the bootstrap. The k3s install script is idempotent at the binary level but does restart the systemd unit. ~30s API outage; existing pods keep running. **Mitigation:** roll this in a maintenance window; it only happens once.

3. **Rancher chart pulls many images on first install** (MEDIUM × MEDIUM). Cattle-system, fleet-system, capi-system, … on a slow link this can exceed the 900s timeout. **Mitigation:** bump `helm_release.rancher.timeout` to 1800s if needed; or pre-pull images with a sidecar DaemonSet.

4. **Sysbox + ARM64 specific gotchas** (MEDIUM × LOW). Sysbox-CE has ARM64 builds, but some kernel features it relies on (`unprivileged_userns_clone`) need verification on the Q6A's RK3576 kernel. **Mitigation:** the install script can pre-check `cat /proc/sys/kernel/unprivileged_userns_clone` (must be `1`); if missing or `0`, document the sysctl fix.

5. **Traefik LoadBalancer collision with future MetalLB** (LOW × MEDIUM). k3s's klipper-lb publishes the Traefik service on node IPs. If you ever add MetalLB later, you'll need to disable klipper-lb (`--disable=servicelb`). **Mitigation:** none needed now; documented in README.

## v2 Apply procedure

**Incremental rollout against an existing v1 cluster (no destroy):**

```pwsh
cd C:\Users\chifo\work\home\homelab

# Pull new variables/resources from this v2 plan into the .tf files (separate task).
# Set the bootstrap password (optional — random one is generated if unset):
$env:TF_VAR_rancher_bootstrap_password = "<choose-or-leave-empty>"

tofu init -upgrade   # in case any new providers
tofu plan            # review: ~6 new resources, 1 modified (k3s server bootstrap re-runs)
tofu apply
```

What happens, in order:
1. `null_resource.k3s_server_bootstrap` re-runs (Traefik re-enabled). Brief CP API outage (~30s).
2. `null_resource.sysbox_install["server"]` runs: installs sysbox, restarts k3s. Another brief CP outage.
3. `null_resource.sysbox_install[for_each workers]` runs in parallel. Each worker's k3s-agent restarts; pods on that worker are rescheduled.
4. `kubectl_manifest.runtimeclass_sysbox` applied.
5. `helm_release.cert_manager` installs (~2 min).
6. `kubectl_manifest.selfsigned_clusterissuer` applied.
7. `helm_release.rancher` installs (~5–10 min).

Total wall-clock: ~15 minutes against an existing healthy v1 cluster.

**Fresh apply (v1 + v2 from scratch):** still uses the v1 two-phase procedure for the helm/kubectl provider chicken-and-egg; v2 resources land cleanly in the second phase.

## v2 Verification additions

**A. Sysbox runtime registered on every node:**

```pwsh
foreach ($n in '192.168.0.187','192.168.0.191','192.168.0.192','192.168.0.193','192.168.0.194') {
  ssh -i ~/.ssh/id_ed25519 "user@$n" 'sudo /usr/local/bin/k3s crictl info 2>/dev/null | grep -A2 runtimes | grep sysbox-runc || sudo /usr/bin/k3s crictl info 2>/dev/null | grep sysbox-runc'
}
# Each node prints a sysbox-runc entry. If empty: containerd config tmpl wasn't applied.
```

**B. RuntimeClass exists:**

```
kubectl get runtimeclass sysbox-runc
# expect: NAME          HANDLER       AGE
#         sysbox-runc   sysbox-runc   <recent>
```

**C. Smoke pod with Sysbox running docker-in-pod:**

```yaml
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
```

```
kubectl apply -f sysbox-smoke.yaml
kubectl logs -f pod/sysbox-smoke         # expect 'Hello from Docker!'
kubectl delete pod sysbox-smoke
```

**D. cert-manager healthy:**

```
kubectl -n cert-manager get pods         # cert-manager, cainjector, webhook all Running
kubectl get clusterissuer selfsigned-issuer -o jsonpath='{.status.conditions[0].status}'
# expect: True
```

**E. Rancher up + login:**

1. Add `192.168.0.187 rancher.lan` to hosts file on the operator machine.
2. `kubectl -n cattle-system rollout status deploy/rancher --timeout=10m` → expect `successfully rolled out`.
3. Browser → `https://rancher.lan`. Accept self-signed cert.
4. Log in with `admin` / `tofu output -raw rancher_bootstrap_password`.
5. Set new admin password. Verify the local cluster is listed under "Cluster Management".

**F. Re-apply idempotency (still required):**

```
tofu plan   # MUST be 'No changes' after a successful apply. Sysbox install is the most likely culprit if drift; confirm the trigger hash is stable.
```

## v2 Critical files

In priority order:
- `C:\Users\chifo\work\home\homelab\main.tf` (modified — append 5 new resources + locals)
- `C:\Users\chifo\work\home\homelab\variables.tf` (modified — Sysbox + Rancher + cert-manager groups)
- `C:\Users\chifo\work\home\homelab\locals.tf` (modified — drop --disable=traefik default; add sysbox_targets local)
- `C:\Users\chifo\work\home\homelab\files\cloud-init\sysbox-install.sh.tftpl` (NEW)
- `C:\Users\chifo\work\home\homelab\files\helm\rancher-values.yaml.tftpl` (NEW)
- `C:\Users\chifo\work\home\homelab\outputs.tf` (modified — Rancher URL + bootstrap pw)
- `C:\Users\chifo\work\home\homelab\terraform.tfvars.example` (modified — surface new vars)
- `C:\Users\chifo\work\home\homelab\README.md` (modified — Sysbox usage + Rancher access + incremental rollout)

## v2 Out of scope (deferred to v3+)

- **MetalLB** for proper LoadBalancer IPs (would replace klipper-lb; useful if you outgrow the "Traefik on the CP IP" model).
- **Rancher Monitoring** (kube-prometheus-stack chart). Install via the Rancher UI when you want it; ~3GB RAM.
- **Rancher Backups** chart (snapshots Rancher state to MinIO). Useful but adds a CRD set; defer.
- **Real Let's Encrypt cert** via cert-manager DNS-01 (requires public DNS + a supported provider). The self-signed flow is fine for LAN use.
- **Container image registry mirror** (Harbor or distribution) backed by MinIO — replaces hitting public registries on every pull. Worth considering once image pulls become the dominant network usage.
- **Hardening Sysbox**: enabling `unprivileged_userns_clone` audits, restricting which namespaces can use the RuntimeClass via PodSecurityAdmission/Kyverno policies.

