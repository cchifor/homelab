variable "node_name" {
  type        = string
  description = "Proxmox node name to deploy the LXC on."
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
  type        = string
  default     = "/24"
  description = "Mask portion appended to var.ip for the LXC network block."
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
  type        = string
  description = "Network bridge."
}

variable "mtu" {
  type        = number
  description = "Layer-2 MTU for the container interface."
}

variable "cores" {
  type        = number
  description = "vCPU cores."
}

variable "memory_mb" {
  type        = number
  description = "RAM in MB."
}

variable "rootfs_size" {
  type        = string
  description = "Rootfs size, e.g. 8G."
}

variable "storage_pool" {
  type        = string
  description = "Proxmox storage pool for rootfs."
}

variable "template" {
  type        = string
  description = "Pre-uploaded LXC template volume id, e.g. local:vztmpl/alpine-3.23-default_<datestamp>_amd64.tar.xz. Find the actual current filename with `pveam available --section system | grep alpine`."
}

variable "bind_host_path" {
  type        = string
  description = "Host filesystem path bind-mounted into the container."
}

variable "bind_ct_path" {
  type        = string
  description = "In-container path to mount the host bind under."
}

variable "unprivileged" {
  type        = bool
  default     = false
  description = "Privileged (false) is required for the host bind-mount UID strategy. See README before flipping."
}

variable "minio_version" {
  type        = string
  description = "MinIO release tag."
}

variable "minio_bucket_longhorn" {
  type        = string
  description = "Longhorn backup bucket to pre-create."
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key authorized for root in the container."
}

# --- Operator-side SSH config used to drive 'pct exec' over SSH to the Proxmox host ---

variable "proxmox_host_address" {
  type        = string
  description = "SSH-reachable IP/hostname of the Proxmox host (used by the bootstrap null_resource)."
}

variable "proxmox_host_ssh_user" {
  type        = string
  default     = "root"
  description = "SSH user on the Proxmox host."
}

variable "proxmox_host_ssh_private_key_path" {
  type        = string
  description = "Path to the private key authorized for proxmox_host_ssh_user."
}
