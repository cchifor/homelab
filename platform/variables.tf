# =============================================================================
# Operator-side SSH (for null_resource provisioners that drive the Proxmox host
# and the cluster nodes from the operator machine running tofu)
# =============================================================================

variable "proxmox_host_address" {
  type        = string
  description = "SSH-reachable IP/hostname of the Proxmox host (e.g. 192.168.0.185). Used by the LXC module's MinIO bootstrap to drive `pct exec`."
}

variable "proxmox_host_ssh_user" {
  type        = string
  default     = "root"
  description = "SSH user on the Proxmox host."
}

variable "proxmox_host_ssh_private_key_path" {
  type        = string
  description = "Path to the SSH private key authorized for proxmox_host_ssh_user. Will be path-expanded (~ supported)."
}

variable "local_shell_interpreter" {
  type        = list(string)
  default     = ["pwsh", "-Command"]
  description = "Local shell + flags used by local-exec provisioners. Defaults to PowerShell 7+ (Windows). Use [\"bash\",\"-c\"] on Linux/macOS."
}

# =============================================================================
# Proxmox auth
# =============================================================================

variable "pm_api_url" {
  type        = string
  description = "Proxmox API URL, e.g. https://192.168.0.185:8006/api2/json"
}

variable "pm_api_token_id" {
  type        = string
  description = "Proxmox API token ID in the format user@realm!tokenid (e.g. tofu-prov@pve!tofu-token)"
}

variable "pm_api_token_secret" {
  type        = string
  description = "Proxmox API token secret. Source via TF_VAR_pm_api_token_secret env var; do not commit to .tfvars."
  sensitive   = true
}

variable "pm_tls_insecure" {
  type        = bool
  description = "Skip TLS verification for the Proxmox API (true for self-signed PVE certs)."
  default     = true
}

variable "pm_node_name" {
  type        = string
  description = "Target Proxmox node name."
  default     = "pve"
}

# =============================================================================
# Network
# =============================================================================

variable "lan_cidr" {
  type        = string
  description = "LAN CIDR."
  default     = "192.168.0.0/24"
}

variable "lan_gateway" {
  type        = string
  description = "LAN gateway IP."
  default     = "192.168.0.1"
}

variable "lan_dns" {
  type        = list(string)
  description = "DNS resolvers."
  default     = ["192.168.0.1", "1.1.1.1"]
}

variable "bridge" {
  type        = string
  description = "Proxmox network bridge to attach VMs/CTs to."
  default     = "vmbr0"
}

variable "mtu" {
  type        = number
  description = "Layer-2 MTU for VM/CT interfaces. Start at 1500; flip to 9000 in a second apply once host bond/bridge are also at 9000 (see README)."
  default     = 1500

  validation {
    condition     = var.mtu == 1500 || var.mtu == 9000
    error_message = "MTU must be 1500 (default) or 9000 (jumbo). Use the two-phase rollout described in README."
  }
}

# =============================================================================
# NAS / MinIO LXC
# =============================================================================

variable "nas_hostname" {
  type        = string
  default     = "nas-minio"
  description = "Hostname for the MinIO LXC."
}

variable "nas_ip" {
  type        = string
  default     = "192.168.0.186"
  description = "Static IP for the NAS LXC (no CIDR)."
}

variable "nas_cores" {
  type        = number
  default     = 1
  description = "CPU cores allocated to the NAS LXC."
}

variable "nas_memory_mb" {
  type        = number
  default     = 4096
  description = "RAM (MB) allocated to the NAS LXC."
}

variable "nas_rootfs_size" {
  type        = string
  default     = "8G"
  description = "Rootfs size for the NAS LXC."
}

variable "nas_storage_pool" {
  type        = string
  default     = "local-zfs"
  description = "Proxmox storage pool for the LXC rootfs."
}

variable "nas_template" {
  type        = string
  default     = "local:vztmpl/alpine-3.23-default_20251217_amd64.tar.xz"
  description = "Pre-uploaded LXC template volume ID. Date stamp drifts as Proxmox refreshes its catalog — confirm the exact current filename with `pveam available --section system | grep alpine` and override here."
}

variable "nas_bind_host_path" {
  type        = string
  default     = "/nvme-pool"
  description = "Host filesystem path bind-mounted into the NAS container."
}

variable "nas_bind_ct_path" {
  type        = string
  default     = "/mnt/storage"
  description = "In-container mount point for the host bind."
}

variable "minio_version" {
  type        = string
  default     = "RELEASE.2024-09-22T00-33-43Z"
  description = "MinIO server release tag."
}

variable "minio_bucket_longhorn" {
  type        = string
  default     = "longhorn-backups"
  description = "Bucket name for Longhorn backup target."
}

# =============================================================================
# K3s control-plane VM
# =============================================================================

variable "cp_hostname" {
  type        = string
  default     = "k3s-server-01"
  description = "Hostname for the k3s control-plane VM."
}

variable "cp_ip" {
  type        = string
  default     = "192.168.0.187"
  description = "Static IP for the control-plane VM (no CIDR)."
}

variable "cp_cores" {
  type        = number
  default     = 2
  description = "vCPU cores per socket for the control-plane VM."
}

variable "cp_sockets" {
  type        = number
  default     = 1
  description = "vCPU sockets for the control-plane VM."
}

variable "cp_memory_mb" {
  type        = number
  default     = 12288
  description = "RAM (MB) allocated to the control-plane VM."
}

variable "cp_disk_size" {
  type        = string
  default     = "32G"
  description = "Root disk size for the control-plane VM."
}

variable "cp_storage_pool" {
  type        = string
  default     = "local-zfs"
  description = "Proxmox storage pool for the VM disk."
}

variable "cp_template_name" {
  type        = string
  default     = "debian-12-cloudinit-template"
  description = "Name of a pre-existing Debian 12 cloud-init VM template on Proxmox to clone from. README documents the one-time creation from debian-12-genericcloud-amd64.qcow2."
}

variable "cp_bios" {
  type        = string
  default     = "seabios"
  description = "VM firmware. seabios is the safe default; ovmf requires an efidisk resource that is finicky in the Telmate provider."
  validation {
    condition     = contains(["seabios", "ovmf"], var.cp_bios)
    error_message = "cp_bios must be seabios or ovmf."
  }
}

variable "cp_ssh_user" {
  type        = string
  default     = "debian"
  description = "Default user provisioned by the Debian cloud image."
}

variable "cp_ssh_public_key" {
  type        = string
  description = "SSH public key authorized for cp_ssh_user. Path-expand at the call site (file(...))."
}

variable "cp_ssh_private_key_path" {
  type        = string
  description = "Path to the private SSH key OpenTofu uses to reach the VM for the wait/fetch null_resources."
}

variable "k3s_version" {
  type        = string
  default     = "v1.30.6+k3s1"
  description = "Pinned k3s release. MUST match between server install and worker installs."
}

variable "k3s_extra_server_args" {
  type        = list(string)
  default     = []
  description = "Extra args appended to the k3s server install. v2 keeps Traefik enabled (k3s default) so Rancher can use it; pass [\"--disable=traefik\"] here to swap to nginx-ingress later."
}

# =============================================================================
# Workers
# =============================================================================

variable "workers" {
  # The default below is a starter example. Operationally, the canonical source
  # of truth for cluster IPs / SSH user / key is scripts/cluster.conf (sourced
  # by deploy-prep.sh and check-prereqs.sh). check-prereqs.sh -WriteTfvars
  # generates terraform.tfvars from cluster.conf, which then overrides this default.
  description = "Map of Radxa worker nodes. Adding a 5th = one new entry. Map keys become for_each keys, so renames or reorders do not churn the others."
  type = map(object({
    name     = string
    address  = string
    ssh_user = string
    ssh_key  = string
    labels   = optional(map(string), {})
    taints   = optional(list(string), [])
  }))
  default = {
    rdxa1 = {
      name     = "rdxa1"
      address  = "192.168.0.131"
      ssh_user = "c4"
      ssh_key  = "~/.ssh/id_ed25519"
    }
    rdxa2 = {
      name     = "rdxa2"
      address  = "192.168.0.132"
      ssh_user = "c4"
      ssh_key  = "~/.ssh/id_ed25519"
    }
    rdxa3 = {
      name     = "rdxa3"
      address  = "192.168.0.133"
      ssh_user = "c4"
      ssh_key  = "~/.ssh/id_ed25519"
    }
    rdxa4 = {
      name     = "rdxa4"
      address  = "192.168.0.134"
      ssh_user = "c4"
      ssh_key  = "~/.ssh/id_ed25519"
    }
  }
}

# =============================================================================
# Longhorn
# =============================================================================

variable "longhorn_chart_version" {
  type        = string
  default     = "1.7.2"
  description = "Longhorn Helm chart version."
}

variable "longhorn_namespace" {
  type        = string
  default     = "longhorn-system"
  description = "Namespace Longhorn is installed into."
}

variable "longhorn_replica_count" {
  type        = number
  default     = 3
  description = "Default volume replica count. With 4 worker nodes (rdxa1/2/3/4) we run 3 — one replica per node — so any single-node outage stays at degraded, not faulted. Was 2 originally; bumped after the 2026-05-17 incident where q6a-1's removal left half the volumes single-replica and q6a-3's overload then risked data loss."
}

variable "longhorn_default_storage_class_name" {
  type        = string
  default     = "longhorn"
  description = "Name of the StorageClass Longhorn creates as default."
}

# =============================================================================
# Sysbox-CE (system-container runtime; enables docker / docker-compose / systemd inside pods)
# =============================================================================

variable "sysbox_version" {
  type        = string
  default     = "0.6.5"
  description = "Sysbox-CE release. Both amd64 and arm64 .deb packages published by Nestybox under this version tag."
}

variable "sysbox_runtime_name" {
  type        = string
  default     = "sysbox-runc"
  description = "Name of the k8s RuntimeClass exposing sysbox to pods. Pods opt in via runtimeClassName."
}

# =============================================================================
# cert-manager
# =============================================================================

variable "cert_manager_chart_version" {
  type        = string
  default     = "v1.16.2"
  description = "cert-manager Helm chart version."
}

variable "cert_manager_namespace" {
  type        = string
  default     = "cert-manager"
  description = "Namespace cert-manager is installed into."
}

# =============================================================================
# Rancher
# =============================================================================

variable "rancher_chart_version" {
  type        = string
  default     = "2.10.1"
  description = "Rancher Helm chart version (rancher-stable)."
}

variable "rancher_namespace" {
  type        = string
  default     = "cattle-system"
  description = "Namespace Rancher is installed into."
}

variable "rancher_hostname" {
  type        = string
  default     = "rancher.lan"
  description = "Hostname Rancher's Ingress responds on. Operator must resolve this to the k3s server VM IP (hosts file or local DNS)."
}

variable "rancher_replicas" {
  type        = number
  default     = 1
  description = "Rancher pod replicas. 1 is fine for single-node home labs; 3 needs a real LB (MetalLB) for HA."
}

variable "rancher_bootstrap_password" {
  type        = string
  default     = null
  sensitive   = true
  description = "Initial admin password. Leave null to auto-generate via random_password (output via tofu output -raw rancher_bootstrap_password). Override via TF_VAR_rancher_bootstrap_password to keep it out of state-on-disk."
}

# =============================================================================
# OpenClaw LXC (optional — gated by var.openclaw_enabled)
#
# Privileged Debian LXC running OpenClaw (autonomous AI assistant). Uses Docker
# as a sandbox backend (so the LXC needs nesting+keyctl features) and Playwright
# for browser automation. Defaults sized for a 4-core / 32 GiB N150 host with
# k3s VM + MinIO + Plex already running.
# =============================================================================

variable "openclaw_enabled" {
  type        = bool
  default     = false
  description = "Deploy the OpenClaw LXC. Defaults off — flip to true (in tfvars or via TF_VAR_openclaw_enabled=true) when you want OpenClaw."
}

variable "openclaw_hostname" {
  type    = string
  default = "openclaw"
}

variable "openclaw_ip" {
  type    = string
  default = "192.168.0.189"
}

variable "openclaw_cores" {
  type    = number
  default = 4
}

variable "openclaw_memory_mb" {
  type    = number
  default = 6144
}

variable "openclaw_rootfs_size" {
  type    = string
  default = "40G"
}

variable "openclaw_storage_pool" {
  type    = string
  default = "local-zfs"
}

variable "openclaw_template" {
  type    = string
  default = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
}

variable "openclaw_bind_host_path" {
  type        = string
  default     = "/nvme-pool/openclaw"
  description = "Host path for OpenClaw persistent state. Pre-create with `mkdir -p /nvme-pool/openclaw && chown 1000:1000 /nvme-pool/openclaw`."
}

variable "openclaw_bind_ct_path" {
  type    = string
  default = "/srv/openclaw"
}

variable "openclaw_node_major_version" {
  type    = string
  default = "24"
}

variable "openclaw_pkg_spec" {
  type        = string
  default     = "openclaw@latest"
  description = "npm package spec. Pin to a version (e.g. openclaw@1.2.3) for reproducibility."
}

# =============================================================================
# Plex LXC (optional — gated by var.plex_enabled)
#
# Privileged Debian LXC with /dev/dri bind-mounted from the host for QuickSync
# hardware transcoding. Library + media stored on /nvme-pool/plex (host).
# LAN-only — first-launch claim required at https://www.plex.tv/claim/
# =============================================================================

variable "plex_enabled" {
  type        = bool
  default     = false
  description = "Deploy the Plex LXC. Defaults off — flip to true (in tfvars or via TF_VAR_plex_enabled=true) when you actually want Plex."
}

variable "plex_hostname" {
  type        = string
  default     = "plex"
  description = "LXC hostname."
}

variable "plex_ip" {
  type        = string
  default     = "192.168.0.188"
  description = "Static LAN IP."
}

variable "plex_cores" {
  type    = number
  default = 4
}

variable "plex_memory_mb" {
  type    = number
  default = 4096
}

variable "plex_rootfs_size" {
  type    = string
  default = "16G"
}

variable "plex_storage_pool" {
  type    = string
  default = "local-zfs"
}

variable "plex_template" {
  type        = string
  default     = "local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst"
  description = "Pre-uploaded LXC template. Plex DEB requires glibc — Debian 12 standard. Find current name: `pveam available --section system | grep debian-12`."
}

variable "plex_bind_host_path" {
  type        = string
  default     = "/nvme-pool/plex"
  description = "Host path for Plex library + media. Pre-create with `mkdir -p /nvme-pool/plex && chown 1000:1000 /nvme-pool/plex`."
}

variable "plex_bind_ct_path" {
  type        = string
  default     = "/srv/plex"
  description = "In-container mount path for plex_bind_host_path."
}

variable "plex_igpu_passthrough_enabled" {
  type    = bool
  default = true
}

variable "plex_igpu_card_name" {
  type        = string
  default     = "card1"
  description = "DRM card device — Alder Lake-N (N150) is card1; older Intel iGPUs may be card0. Check with `ls /dev/dri/` on the Proxmox host."
}

variable "plex_igpu_card_minor" {
  type    = number
  default = 1
}

variable "plex_igpu_render_name" {
  type    = string
  default = "renderD128"
}

variable "plex_igpu_render_minor" {
  type    = number
  default = 128
}

variable "plex_version" {
  type        = string
  default     = "1.41.4.9463-630c9f557"
  description = "Plex Media Server version. Latest at https://www.plex.tv/media-server-downloads/?cat=computer&plat=linux"
}

variable "plex_smb_mounts" {
  type = list(object({
    server      = string
    share       = string
    mount_point = string
    smb_vers    = optional(string, "2.1")
    creds_file  = optional(string, "/root/.smb-creds")
    read_only   = optional(bool, true)
  }))
  default     = []
  description = "SMB/CIFS shares to mount inside the Plex LXC. Each entry produces an /etc/fstab line + a placeholder credentials file at .creds_file (chmod 600). Operator must populate real creds post-apply via `pct exec <ctid> -- printf 'username=...\\npassword=...\\n' > <creds_file>`. Defaults to vers=2.1 because some QNAP firmwares choke on Linux cifs SMB3 negotiation."
}

# =============================================================================
# Let's Encrypt (DNS-01 via Cloudflare)
#
# All three resources here (Secret + 2 ClusterIssuers in main.tf) are gated on
# var.cloudflare_api_token being non-null — leave it null to skip LE entirely
# and keep using the selfsigned-issuer ClusterIssuer.
# =============================================================================

variable "cloudflare_api_token" {
  type        = string
  default     = null
  sensitive   = true
  description = "Cloudflare API token used by BOTH cert-manager (DNS-01 LE challenge) AND the cloudflare-tunnel-ingress-controller. Required scopes: Zone:DNS:Edit + Zone:Zone:Read on letsencrypt_base_domain, plus Account:Cloudflare Tunnel:Edit (only if you want the tunnel operator). Source via TF_VAR_cloudflare_api_token; never commit to .tfvars. Leave null to skip both LE issuers AND the tunnel operator."
}

variable "acme_email" {
  type        = string
  default     = "chifor@gmail.com"
  description = "Contact email for Let's Encrypt account registration. LE sends cert expiry warnings here."
}

variable "letsencrypt_base_domain" {
  type        = string
  default     = "chifor.dev"
  description = "Base domain managed in Cloudflare. Surfaced as an output for convenience; the issuers themselves are domain-agnostic — apps request whatever hostname they need under this domain in their Ingress tls block."
}

# =============================================================================
# Cloudflare Tunnel Ingress Controller (STRRL/cloudflare-tunnel-ingress-controller)
#
# Operator that watches Ingresses with `ingressClassName: cloudflare-tunnel`
# and auto-configures BOTH the Cloudflare Tunnel's Public Hostnames AND the
# DNS CNAMEs. Per-app exposure becomes pure GitOps: just deploy a chart with
# the right ingressClassName, and the operator handles tunnel + DNS for you.
#
# Created only when both var.cloudflare_api_token AND var.cloudflare_account_id
# are set; safe to leave unset to skip (cluster keeps working LAN-only).
# =============================================================================

variable "cloudflare_account_id" {
  type        = string
  default     = null
  description = "Cloudflare account ID (find in CF dashboard right sidebar on any zone's Overview page, or via `wrangler whoami`). Required for the tunnel operator (tunnels are account-scoped). Leave null to skip the tunnel operator entirely (LE issuers still install if cloudflare_api_token is set)."
}

variable "cloudflare_tunnel_name" {
  type        = string
  default     = "homelab"
  description = "Name of the tunnel the operator creates. Will appear in CF dashboard under Networks → Tunnels."
}

variable "cloudflare_tunnel_ingress_chart_version" {
  type        = string
  default     = "0.0.21"
  description = "STRRL/cloudflare-tunnel-ingress-controller Helm chart version. See https://github.com/STRRL/cloudflare-tunnel-ingress-controller/releases."
}

# =============================================================================
# Local artefacts (kubeconfig + token files written by null_resources)
# =============================================================================

variable "local_kubeconfig_path" {
  type        = string
  default     = "./kubeconfig"
  description = "Where the rewritten kubeconfig is written on the operator machine. Gitignored."
}

variable "local_token_path" {
  type        = string
  default     = "./.k3s_token"
  description = "Where the k3s join token is cached on the operator machine. Gitignored."
}

# =============================================================================
# Claude Code worker VM
# =============================================================================

variable "claude_worker_enabled" {
  type        = bool
  default     = false
  description = "Deploy the Claude Code worker VM. Off by default — flip to true (in tfvars or TF_VAR_claude_worker_enabled=true) when you want it."
}

variable "claude_worker_hostname" {
  type    = string
  default = "claude-worker"
}

variable "claude_worker_ip" {
  type        = string
  default     = "192.168.0.190"
  description = "Static LAN IP."
}

variable "claude_worker_cores" {
  type    = number
  default = 4
}

variable "claude_worker_memory_mb" {
  type    = number
  default = 8192
}

variable "claude_worker_root_disk" {
  type        = string
  default     = "32G"
  description = "Root disk for the claude-worker VM. Bumped 16G → 32G on 2026-05-18 after a forge dry-run blew through /tmp (~5 GiB of forge-dry-* dirs) and filled the root partition. 32G gives ~22G headroom over the OS footprint."
}

variable "claude_worker_data_disk" {
  type    = string
  default = "48G"
}

variable "claude_worker_storage_pool" {
  type    = string
  default = "local-zfs"
}

variable "claude_worker_template_name" {
  type        = string
  description = "Pre-existing Debian 12 cloud-init template VM (created by prep-proxmox.sh)."
  default     = "debian-12-cloudinit-template"
}

variable "claude_worker_ssh_user" {
  type        = string
  default     = "c4"
  description = "Primary OS user (sudoer) on the worker."
}

variable "claude_worker_ssh_public_key" {
  type        = string
  default     = ""
  description = "SSH public key contents (the value, not path) authorized for ssh_user. Set in tfvars or via TF_VAR_claude_worker_ssh_public_key."
}

variable "claude_worker_ssh_private_key_path" {
  type        = string
  default     = "~/.ssh/id_ed25519"
  description = "Local path to the SSH private key matching claude_worker_ssh_public_key. Used by null_resource provisioners to drive the VM."
}

# Cloudflare Tunnel token for the worker's standalone cloudflared.
# Create the tunnel in CF Zero Trust dashboard, paste the connector token
# as TF_VAR_claude_worker_cf_tunnel_token. Two DNS routes
# (worker-ssh.chifor.dev, claude.chifor.dev) and the CF Access policy
# are configured in the dashboard out-of-band; see the module README.
variable "claude_worker_cf_tunnel_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Cloudflare tunnel connector token. Leave empty to skip cloudflared install (LAN-only mode)."
}

# Restic + MinIO
variable "claude_worker_restic_repo_url" {
  type        = string
  default     = "s3:http://192.168.0.186:9000/claude-worker-backup"
  description = "Restic repository URL. Points at the NAS LXC's MinIO."
}

variable "claude_worker_restic_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Restic encryption password. Set via TF_VAR_claude_worker_restic_password. Operator MUST also save this in Vaultwarden — losing it makes the backup unrecoverable."
}

# SSH password for the c4 user. When set, the bootstrap sets the password and
# enables sshd PasswordAuthentication so non-key-aware clients (KiTTY default,
# phones, friend's machine) can log in. Leave empty (the default) to keep the
# pubkey-only posture. Set via TF_VAR_claude_worker_c4_password (out-of-band
# secret, NOT in tfvars). Save the value in Vaultwarden — terraform doesn't
# read the system back so a lost password requires a reset on the VM.
variable "claude_worker_c4_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Optional password for the c4 user; enables sshd PasswordAuthentication when non-empty."
}
