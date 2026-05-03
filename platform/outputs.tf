output "nas_ip" {
  value       = module.nas_minio.ip
  description = "MinIO LXC static IP."
}

output "nas_vmid" {
  value       = module.nas_minio.vmid
  description = "Proxmox container ID for the NAS LXC."
}

output "minio_endpoint" {
  value       = module.nas_minio.minio_endpoint
  description = "MinIO S3 endpoint URL."
}

output "minio_root_user" {
  value       = module.nas_minio.minio_root_user
  description = "MinIO root username."
  sensitive   = true
}

output "minio_root_password" {
  value       = module.nas_minio.minio_root_password
  description = "MinIO root password (random per apply; rotate by tainting random_password.minio_root in the LXC module)."
  sensitive   = true
}

output "k3s_server_ip" {
  value       = module.k3s_server.vm_ip
  description = "k3s control-plane VM static IP."
}

output "k3s_server_vmid" {
  value       = module.k3s_server.vmid
  description = "Proxmox VM ID for the control-plane VM."
}

output "kubeconfig_path" {
  value       = abspath(var.local_kubeconfig_path)
  description = "Absolute path to the locally-fetched kubeconfig (server URL rewritten from 127.0.0.1 to the VM IP)."
}

output "worker_ips" {
  value       = { for k, w in var.workers : k => w.address }
  description = "Worker node IPs."
}

output "longhorn_url" {
  value       = "kubectl -n ${var.longhorn_namespace} port-forward svc/longhorn-frontend 8081:80"
  description = "How to reach the Longhorn UI from the operator machine."
}

# --- v2: Sysbox + Rancher ---

output "sysbox_runtime_class_name" {
  value       = var.sysbox_runtime_name
  description = "k8s RuntimeClass to set on pods that need Sysbox (docker-in-pod, systemd-in-pod, etc.)."
}

output "rancher_url" {
  value       = "https://${var.rancher_hostname}"
  description = "Rancher UI URL. Add an entry mapping rancher_hostname to the k3s server VM IP in your hosts file (or local DNS) so the browser can resolve it."
}

output "rancher_bootstrap_password" {
  value       = sensitive(coalesce(var.rancher_bootstrap_password, random_password.rancher_bootstrap.result))
  description = "Initial admin password for Rancher. Read with `tofu output -raw rancher_bootstrap_password`. Rancher will prompt to set a new password on first login."
  sensitive   = true
}
