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
  default     = 6144
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
    q6a-1 = {
      name     = "q6a-1"
      address  = "192.168.0.174"
      ssh_user = "c4"
      ssh_key  = "~/.ssh/id_ed25519"
    }
    q6a-2 = {
      name     = "q6a-2"
      address  = "192.168.0.200"
      ssh_user = "c4"
      ssh_key  = "~/.ssh/id_ed25519"
    }
    q6a-3 = {
      name     = "q6a-3"
      address  = "192.168.0.129"
      ssh_user = "c4"
      ssh_key  = "~/.ssh/id_ed25519"
    }
    q6a-4 = {
      name     = "q6a-4"
      address  = "192.168.1.167"
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
  default     = 2
  description = "Default volume replica count. With 4 workers, 2 leaves headroom; 3 is also fine."
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
