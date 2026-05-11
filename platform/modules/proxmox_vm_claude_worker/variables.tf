variable "node_name" {
  type        = string
  description = "Proxmox node name."
}

variable "hostname" {
  type        = string
  description = "VM hostname / PVE VM name."
}

variable "template_name" {
  type        = string
  description = "Debian 12 cloud-init template VM to clone."
}

variable "cores" {
  type    = number
  default = 4
}

variable "sockets" {
  type    = number
  default = 1
}

variable "memory_mb" {
  type    = number
  default = 8192
}

variable "root_disk_size" {
  type    = string
  default = "16G"
}

variable "data_disk_size" {
  type    = string
  default = "48G"
}

variable "storage_pool" {
  type    = string
  default = "local-zfs"
}

variable "bios" {
  type    = string
  default = "seabios"
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
  description = "DNS resolvers."
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "mtu" {
  type    = number
  default = 1500
}

variable "ssh_user" {
  type        = string
  description = "Cloud-init default user (e.g. 'c4')."
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key authorized for ssh_user."
}
