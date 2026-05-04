variable "node_name" {
  type        = string
  description = "Proxmox node name."
}

variable "hostname" {
  type        = string
  description = "Container hostname."
}

variable "ip" {
  type        = string
  description = "Static IPv4 (no CIDR)."
}

variable "lan_cidr_suffix" {
  type    = string
  default = "/24"
}

variable "gateway" {
  type        = string
  description = "Default gateway."
}

variable "dns" {
  type        = list(string)
  description = "DNS servers."
}

variable "bridge" {
  type = string
}

variable "mtu" {
  type = number
}

variable "cores" {
  type        = number
  default     = 4
  description = "vCPU cores. Host has 4 physical cores; allocating 4 lets OpenClaw burst when busy and time-slice with other guests when idle."
}

variable "memory_mb" {
  type        = number
  default     = 6144
  description = "RAM in MB. ~500 MB Node + 1.5 GB Playwright browsers + 200 MB Docker + 4 GB headroom for sandbox containers spawned by the agent."
}

variable "rootfs_size" {
  type        = string
  default     = "40G"
  description = "Rootfs for Docker images (Playwright deps + agent's sandbox container images can grow). Expand later via `pct resize` if needed."
}

variable "storage_pool" {
  type    = string
  default = "local-zfs"
}

variable "template" {
  type        = string
  description = "Pre-uploaded LXC template (Debian 12 — Node 24 + Docker CE need glibc, not Alpine's musl)."
}

variable "unprivileged" {
  type        = bool
  default     = false
  description = "Privileged required for Docker-in-LXC + bind mount UID strategy. See README."
}

variable "bind_host_path" {
  type        = string
  description = "Host path for OpenClaw persistent state (e.g. /nvme-pool/openclaw). Holds npm global + agent skills + conversation memory + Playwright cache + Docker volumes."
}

variable "bind_ct_path" {
  type        = string
  default     = "/srv/openclaw"
  description = "Mount path inside the container."
}

variable "node_major_version" {
  type        = string
  default     = "24"
  description = "Node.js major version. OpenClaw recommends 24; 22.14+ also works."
}

variable "openclaw_pkg_spec" {
  type        = string
  default     = "openclaw@latest"
  description = "npm package spec to install. Pin to a specific version for reproducibility, e.g. openclaw@1.2.3."
}

variable "ssh_public_key" {
  type = string
}

variable "proxmox_host_address" {
  type = string
}

variable "proxmox_host_ssh_user" {
  type    = string
  default = "root"
}

variable "proxmox_host_ssh_private_key_path" {
  type = string
}
