variable "node_name" {
  type        = string
  description = "Proxmox node name to deploy the VM on."
}

variable "hostname" {
  type        = string
  description = "VM hostname / Proxmox VM name."
}

variable "template_name" {
  type        = string
  description = "Pre-existing Debian 12 cloud-init template VM to clone from."
}

variable "cores" {
  type        = number
  description = "vCPU cores per socket."
}

variable "sockets" {
  type        = number
  description = "vCPU sockets."
}

variable "memory_mb" {
  type        = number
  description = "RAM in MB."
}

variable "disk_size" {
  type        = string
  description = "Root disk size, e.g. 32G."
}

variable "storage_pool" {
  type        = string
  description = "Proxmox storage pool for the disk."
}

variable "bios" {
  type        = string
  description = "VM firmware (seabios|ovmf)."
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
  type        = string
  description = "Network bridge."
}

variable "mtu" {
  type        = number
  description = "Layer-2 MTU."
}

variable "ssh_user" {
  type        = string
  description = "Cloud-init default user (Debian image: 'debian')."
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key authorized for ssh_user."
}
