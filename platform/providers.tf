provider "proxmox" {
  pm_api_url          = var.pm_api_url
  pm_api_token_id     = var.pm_api_token_id
  pm_api_token_secret = var.pm_api_token_secret
  pm_tls_insecure     = var.pm_tls_insecure
}

provider "helm" {
  kubernetes {
    config_path = var.local_kubeconfig_path
  }
  # Isolate from any helm repos the user has configured outside this project
  # (otherwise the provider walks the user's ~/.config/helm and breaks if any
  # cached repo index is missing — e.g. a stale 'nvidia' entry on Windows).
  repository_config_path = "${path.root}/.helm/repositories.yaml"
  repository_cache       = "${path.root}/.helm/cache"
}

provider "kubectl" {
  config_path      = var.local_kubeconfig_path
  load_config_file = true
}

provider "kubernetes" {
  config_path = var.local_kubeconfig_path
}

# Incus provider for the 4-node rdxa cluster. Defaults to the operator's local
# Incus client config at ~/.config/incus/config.yml (Linux/macOS) or
# %AppData%/incus/config.yml (Windows). The default remote should be one of
# the cluster members (e.g. rdxa1) added via `incus remote add` after a
# trust-cert handshake. See platform/README.md § "Operator-side Incus client
# setup" for the one-time configuration.
provider "incus" {
  remote {
    name    = var.incus_remote_name
    address = "https://${var.incus_remote_address}:8443"
    scheme  = "https"
    default = true
  }
}
