output "vmid" {
  value       = proxmox_lxc.this.vmid
  description = "Proxmox container ID."
}

output "ip" {
  value       = var.ip
  description = "Container static IP."
}

output "minio_endpoint" {
  value       = "http://${var.ip}:9000"
  description = "MinIO S3 endpoint URL."
}

output "minio_root_user" {
  value       = "admin"
  sensitive   = true
  description = "MinIO root username."
}

output "minio_root_password" {
  value       = random_password.minio_root.result
  sensitive   = true
  description = "MinIO root password (random, regenerate by tainting random_password.minio_root)."
}

output "minio_bucket_longhorn" {
  value       = var.minio_bucket_longhorn
  description = "Pre-created bucket name for Longhorn backups."
}
