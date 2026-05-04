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

# --- OpenClaw ---

output "openclaw_gateway_url" {
  value       = var.openclaw_enabled ? "http://${var.openclaw_ip}:18789 — daemon NOT auto-started; ssh + run `openclaw onboard --install-daemon` to configure API keys first" : "(disabled — set openclaw_enabled=true)"
  description = "OpenClaw daemon URL. First-run setup needs API keys (Claude/OpenAI + messaging integrations) — see modules/proxmox_lxc_openclaw/README.md."
}

output "openclaw_vmid" {
  value       = var.openclaw_enabled ? module.openclaw_lxc[0].vmid : null
  description = "OpenClaw LXC container ID."
}

output "openclaw_ip" {
  value       = var.openclaw_enabled ? module.openclaw_lxc[0].ip : null
  description = "OpenClaw LXC IP."
}

# --- Plex ---

output "plex_url" {
  value       = var.plex_enabled ? "http://${var.plex_ip}:32400/web" : "(disabled — set plex_enabled=true)"
  description = "Plex Media Server web UI URL. First launch requires a claim token from https://www.plex.tv/claim/ (4-min TTL): browse to this URL while signed in to plex.tv on the same browser, or paste the claim token into the LXC."
}

output "plex_vmid" {
  value       = var.plex_enabled ? module.plex_lxc[0].vmid : null
  description = "Plex LXC container ID."
}

output "plex_ip" {
  value       = var.plex_enabled ? module.plex_lxc[0].ip : null
  description = "Plex LXC IP."
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

# --- Let's Encrypt ---

output "letsencrypt_issuers" {
  value = local.letsencrypt_enabled ? {
    staging = "letsencrypt-staging"
    prod    = "letsencrypt-prod"
    } : {
    note = "Disabled — set TF_VAR_cloudflare_api_token to enable."
  }
  description = "ClusterIssuer names. Apps annotate their Ingress with cert-manager.io/cluster-issuer: letsencrypt-prod (or letsencrypt-staging while developing — staging certs are untrusted but rate limits are very loose)."
}

output "letsencrypt_base_domain" {
  value       = var.letsencrypt_base_domain
  description = "Base domain LE certs are issued under. Apps under this domain get auto-renewed certs by referencing one of the letsencrypt_issuers in their Ingress annotation."
}

# --- Cloudflare Tunnel ---

output "cloudflare_tunnel_status" {
  value = local.cloudflare_tunnel_enabled ? {
    operator_pods    = "kubectl -n cloudflare-tunnel-ingress-controller get pods"
    operator_logs    = "kubectl -n cloudflare-tunnel-ingress-controller logs -l app.kubernetes.io/name=cloudflare-tunnel-ingress-controller --tail=50"
    cloudflared_logs = "kubectl -n cloudflare-tunnel-ingress-controller logs -l app=cloudflared --tail=50"
    dashboard        = "https://one.dash.cloudflare.com → Networks → Tunnels → ${var.cloudflare_tunnel_name} (auto-created by operator)"
    expose_an_app    = "Add `ingressClassName: cloudflare-tunnel` to the app's Ingress (and the public host under .Values.ingress.host). Operator handles the tunnel hostname + DNS automatically. helm uninstall → operator cleans both up."
    } : {
    note = "Disabled — set TF_VAR_cloudflare_api_token (with Account:Cloudflare Tunnel:Edit scope) AND TF_VAR_cloudflare_account_id."
  }
  description = "Cloudflare Tunnel ingress operator status. Per-app exposure: just set ingressClassName: cloudflare-tunnel on the app's Ingress."
}
