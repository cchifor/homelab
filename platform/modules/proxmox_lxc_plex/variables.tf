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
  description = "vCPU cores. 4 lets Plex use multiple parallel transcodes if it falls back to CPU when QuickSync can't help."
}

variable "memory_mb" {
  type        = number
  default     = 4096
  description = "RAM in MB. Plex itself is light (~500 MB); transcoding spikes use more, especially CPU fallback."
}

variable "rootfs_size" {
  type        = string
  default     = "16G"
  description = "Rootfs for Plex binary + libs + transcode temp dir."
}

variable "storage_pool" {
  type = string
}

variable "template" {
  type        = string
  description = "Pre-uploaded LXC template (Debian 12 — Plex DEB requires glibc, not Alpine's musl). Find current name via `pveam available --section system | grep debian`."
}

variable "unprivileged" {
  type        = bool
  default     = false
  description = "Privileged required for /dev/dri bind cgroup allows. See README."
}

variable "bind_host_path" {
  type        = string
  description = "Host path for Plex library + media (e.g. /nvme-pool/plex)."
}

variable "bind_ct_path" {
  type        = string
  default     = "/srv/plex"
  description = "Mount path inside the container."
}

variable "igpu_passthrough_enabled" {
  type        = bool
  default     = true
  description = "Bind /dev/dri/{card,renderD*} into the LXC for QuickSync hardware transcoding. Disable if the host has no Intel iGPU or you want pure CPU transcoding."
}

variable "igpu_card_name" {
  type        = string
  default     = "card1"
  description = "DRM card device name on the host. Alder Lake-N (N150 etc.) exposes card1; older Intel iGPUs may be card0. Verify with `ls /dev/dri` on the Proxmox host."
}

variable "igpu_card_minor" {
  type        = number
  default     = 1
  description = "Minor number of the DRM card device (matches igpu_card_name; cardN minor is N). 0 for card0, 1 for card1."
}

variable "igpu_render_name" {
  type        = string
  default     = "renderD128"
  description = "Render node device name. First render node is renderD128 (minor 128). Multi-GPU systems may have renderD129+."
}

variable "igpu_render_minor" {
  type        = number
  default     = 128
  description = "Minor number of the render node device (renderD128 is 128, renderD129 is 129, etc.)."
}

variable "plex_version" {
  type        = string
  default     = "1.41.4.9463-630c9f557"
  description = "Plex Media Server version. Latest at https://www.plex.tv/media-server-downloads/?cat=computer&plat=linux"
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
