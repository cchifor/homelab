output "vmid" {
  value       = proxmox_vm_qemu.this.vmid
  description = "Proxmox VM ID."
}

output "vm_ip" {
  value       = var.ip
  description = "Static IP of the worker VM."
}

output "ssh_user" {
  value       = var.ssh_user
  description = "SSH user (cloud-init default user)."
}
