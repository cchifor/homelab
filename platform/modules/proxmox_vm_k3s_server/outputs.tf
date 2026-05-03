output "vmid" {
  value       = proxmox_vm_qemu.this.vmid
  description = "Proxmox VM ID."
}

output "vm_ip" {
  value       = var.ip
  description = "Static IP of the control-plane VM."
}

output "ssh_user" {
  value       = var.ssh_user
  description = "SSH user provisioned by cloud-init."
}
