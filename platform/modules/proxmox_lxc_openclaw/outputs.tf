output "vmid" {
  value       = proxmox_lxc.this.vmid
  description = "Proxmox container ID."
}

output "ip" {
  value       = var.ip
  description = "Container static IP."
}

output "openclaw_gateway_url" {
  value       = "http://${var.ip}:18789"
  description = "OpenClaw daemon gateway URL (LAN-only). First-time setup needs API keys — see README."
}

output "openclaw_ssh" {
  value       = "ssh root@${var.ip}"
  description = "SSH into the OpenClaw LXC for `openclaw onboard` and other admin tasks."
}
