output "vmid" {
  value       = proxmox_lxc.this.vmid
  description = "Proxmox container ID."
}

output "ip" {
  value       = var.ip
  description = "Container static IP."
}

output "plex_url" {
  value       = "http://${var.ip}:32400/web"
  description = "Plex Media Server web UI URL (LAN-only — first-launch claim required, see README)."
}
