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
