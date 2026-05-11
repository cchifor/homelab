# =============================================================================
# Phase A: Proxmox layer (NAS LXC + k3s control-plane VM)
# =============================================================================

module "nas_minio" {
  source = "./modules/proxmox_lxc_minio"

  node_name = var.pm_node_name
  hostname  = var.nas_hostname

  ip      = var.nas_ip
  gateway = var.lan_gateway
  dns     = var.lan_dns
  bridge  = var.bridge
  mtu     = var.mtu

  cores        = var.nas_cores
  memory_mb    = var.nas_memory_mb
  rootfs_size  = var.nas_rootfs_size
  storage_pool = var.nas_storage_pool
  template     = var.nas_template

  bind_host_path = var.nas_bind_host_path
  bind_ct_path   = var.nas_bind_ct_path

  minio_version         = var.minio_version
  minio_bucket_longhorn = var.minio_bucket_longhorn

  ssh_public_key = var.cp_ssh_public_key

  proxmox_host_address              = var.proxmox_host_address
  proxmox_host_ssh_user             = var.proxmox_host_ssh_user
  proxmox_host_ssh_private_key_path = pathexpand(var.proxmox_host_ssh_private_key_path)
}

module "openclaw_lxc" {
  count  = var.openclaw_enabled ? 1 : 0
  source = "./modules/proxmox_lxc_openclaw"

  node_name = var.pm_node_name
  hostname  = var.openclaw_hostname

  ip      = var.openclaw_ip
  gateway = var.lan_gateway
  dns     = var.lan_dns
  bridge  = var.bridge
  mtu     = var.mtu

  cores        = var.openclaw_cores
  memory_mb    = var.openclaw_memory_mb
  rootfs_size  = var.openclaw_rootfs_size
  storage_pool = var.openclaw_storage_pool
  template     = var.openclaw_template

  bind_host_path = var.openclaw_bind_host_path
  bind_ct_path   = var.openclaw_bind_ct_path

  node_major_version = var.openclaw_node_major_version
  openclaw_pkg_spec  = var.openclaw_pkg_spec

  ssh_public_key = var.cp_ssh_public_key

  proxmox_host_address              = var.proxmox_host_address
  proxmox_host_ssh_user             = var.proxmox_host_ssh_user
  proxmox_host_ssh_private_key_path = pathexpand(var.proxmox_host_ssh_private_key_path)
}

module "plex_lxc" {
  count  = var.plex_enabled ? 1 : 0
  source = "./modules/proxmox_lxc_plex"

  node_name = var.pm_node_name
  hostname  = var.plex_hostname

  ip      = var.plex_ip
  gateway = var.lan_gateway
  dns     = var.lan_dns
  bridge  = var.bridge
  mtu     = var.mtu

  cores        = var.plex_cores
  memory_mb    = var.plex_memory_mb
  rootfs_size  = var.plex_rootfs_size
  storage_pool = var.plex_storage_pool
  template     = var.plex_template

  bind_host_path = var.plex_bind_host_path
  bind_ct_path   = var.plex_bind_ct_path

  igpu_passthrough_enabled = var.plex_igpu_passthrough_enabled
  igpu_card_name           = var.plex_igpu_card_name
  igpu_card_minor          = var.plex_igpu_card_minor
  igpu_render_name         = var.plex_igpu_render_name
  igpu_render_minor        = var.plex_igpu_render_minor

  plex_version = var.plex_version

  smb_mounts = var.plex_smb_mounts

  ssh_public_key = var.cp_ssh_public_key

  proxmox_host_address              = var.proxmox_host_address
  proxmox_host_ssh_user             = var.proxmox_host_ssh_user
  proxmox_host_ssh_private_key_path = pathexpand(var.proxmox_host_ssh_private_key_path)
}

module "claude_worker" {
  count  = var.claude_worker_enabled ? 1 : 0
  source = "./modules/proxmox_vm_claude_worker"

  node_name = var.pm_node_name
  hostname  = var.claude_worker_hostname

  template_name = var.claude_worker_template_name

  cores          = var.claude_worker_cores
  sockets        = 1
  memory_mb      = var.claude_worker_memory_mb
  root_disk_size = var.claude_worker_root_disk
  data_disk_size = var.claude_worker_data_disk
  storage_pool   = var.claude_worker_storage_pool
  bios           = "seabios"

  ip      = var.claude_worker_ip
  gateway = var.lan_gateway
  dns     = var.lan_dns
  bridge  = var.bridge
  mtu     = var.mtu

  ssh_user       = var.claude_worker_ssh_user
  ssh_public_key = var.claude_worker_ssh_public_key
}

module "k3s_server" {
  source = "./modules/proxmox_vm_k3s_server"

  node_name = var.pm_node_name
  hostname  = var.cp_hostname

  template_name = var.cp_template_name

  cores        = var.cp_cores
  sockets      = var.cp_sockets
  memory_mb    = var.cp_memory_mb
  disk_size    = var.cp_disk_size
  storage_pool = var.cp_storage_pool
  bios         = var.cp_bios

  ip      = var.cp_ip
  gateway = var.lan_gateway
  dns     = var.lan_dns
  bridge  = var.bridge
  mtu     = var.mtu

  ssh_user       = var.cp_ssh_user
  ssh_public_key = var.cp_ssh_public_key
}

# =============================================================================
# k3s server bootstrap (install qemu-agent + k3s server inside the VM)
# =============================================================================

resource "null_resource" "k3s_server_bootstrap" {
  depends_on = [module.k3s_server]

  triggers = {
    vm_id            = module.k3s_server.vmid
    k3s_version      = var.k3s_version
    k3s_install_exec = local.k3s_server_install_env.INSTALL_K3S_EXEC
  }

  connection {
    type        = "ssh"
    host        = module.k3s_server.vm_ip
    user        = var.cp_ssh_user
    private_key = file(pathexpand(var.cp_ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/files/cloud-init/k3s-server-bootstrap.sh.tftpl", {
      k3s_version      = var.k3s_version
      k3s_install_exec = local.k3s_server_install_env.INSTALL_K3S_EXEC
    })
    destination = "/tmp/k3s-server-bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/k3s-server-bootstrap.sh",
      "sudo /tmp/k3s-server-bootstrap.sh",
      "rm -f /tmp/k3s-server-bootstrap.sh",
    ]
  }
}

# =============================================================================
# Fetch k3s join token + kubeconfig from the server VM to local files.
# Both run via SSH from the operator machine.
# =============================================================================

resource "null_resource" "fetch_k3s_token" {
  depends_on = [null_resource.k3s_server_bootstrap]

  triggers = {
    bootstrap_id = null_resource.k3s_server_bootstrap.id
  }

  provisioner "local-exec" {
    interpreter = var.local_shell_interpreter
    command = join(" ", [
      "ssh -o StrictHostKeyChecking=accept-new",
      "-i ${pathexpand(var.cp_ssh_private_key_path)}",
      "${var.cp_ssh_user}@${var.cp_ip}",
      "'sudo cat /var/lib/rancher/k3s/server/node-token'",
      "> ${var.local_token_path}",
    ])
  }
}

resource "null_resource" "fetch_kubeconfig" {
  depends_on = [null_resource.k3s_server_bootstrap]

  triggers = {
    bootstrap_id = null_resource.k3s_server_bootstrap.id
    cp_ip        = var.cp_ip
  }

  provisioner "local-exec" {
    interpreter = var.local_shell_interpreter
    command = join(" ", [
      "ssh -o StrictHostKeyChecking=accept-new",
      "-i ${pathexpand(var.cp_ssh_private_key_path)}",
      "${var.cp_ssh_user}@${var.cp_ip}",
      "\"sudo cat /etc/rancher/k3s/k3s.yaml | sed 's|https://127.0.0.1:6443|https://${var.cp_ip}:6443|'\"",
      "> ${var.local_kubeconfig_path}",
    ])
  }
}

data "local_sensitive_file" "k3s_token" {
  filename   = var.local_token_path
  depends_on = [null_resource.fetch_k3s_token]
}

data "local_sensitive_file" "kubeconfig" {
  filename   = var.local_kubeconfig_path
  depends_on = [null_resource.fetch_kubeconfig]
}

# =============================================================================
# Phase B: Workers (k3s agents on Radxa Q6A / Armbian)
# =============================================================================

resource "null_resource" "bootstrap_worker" {
  for_each = var.workers

  depends_on = [
    null_resource.k3s_server_bootstrap,
    data.local_sensitive_file.k3s_token,
  ]

  triggers = {
    token_hash  = sha256(trimspace(data.local_sensitive_file.k3s_token.content))
    server_url  = local.k3s_server_url
    k3s_version = var.k3s_version
    worker_addr = each.value.address
    worker_name = each.value.name
    mtu         = var.mtu
  }

  connection {
    type        = "ssh"
    host        = each.value.address
    user        = each.value.ssh_user
    private_key = file(pathexpand(each.value.ssh_key))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/files/cloud-init/k3s-worker-bootstrap.sh.tftpl", {
      node_name   = each.value.name
      server_url  = local.k3s_server_url
      k3s_token   = trimspace(data.local_sensitive_file.k3s_token.content)
      k3s_version = var.k3s_version
      mtu         = var.mtu
    })
    destination = "/tmp/k3s-worker-bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/k3s-worker-bootstrap.sh",
      "sudo /tmp/k3s-worker-bootstrap.sh",
      "rm -f /tmp/k3s-worker-bootstrap.sh",
    ]
  }
}

# =============================================================================
# v2: Sysbox-CE — DISABLED (May 2026)
#
# Sysbox-CE 0.6.5 is fundamentally incompatible with k3s 1.30.6's embedded
# containerd 1.7.22-k3s1 on this hardware (Radxa Q6A QCS6490 + Debian VM).
# Symptom: even merely installing the sysbox-ce .deb (without registering
# sysbox-runc in containerd config) breaks containerd's CRI v1 service
# registration — k3s gets stuck on "Waiting for containerd startup: rpc
# error: code = Unimplemented desc = unknown service runtime.v1.RuntimeService"
# indefinitely. Reproduces on both server and workers.
#
# Workaround: skip Sysbox in v1. Pods that need docker-in-pod will need to
# use privileged: true with docker:dind for now. Re-evaluate when:
#   - Sysbox upstream confirms support for containerd 1.7.22+
#   - OR we move to RKE2 (different containerd packaging)
#   - OR we pin to an older containerd that's known to work with Sysbox
#
# Resource blocks left commented for easy re-enable; locals.sysbox_targets +
# the sysbox_* variables remain defined.
# =============================================================================

# resource "null_resource" "sysbox_install" { ... }    # see git history if reviving
# resource "kubectl_manifest" "runtimeclass_sysbox" { ... }

# =============================================================================
# Phase C: Longhorn storage (Helm) + MinIO S3 backup target (kubectl)
# =============================================================================

# =============================================================================
# Longhorn — re-enabled May 2026 after fixing the prereqs that caused the
# initial install failure: open-iscsi installed on every worker, helm timeout
# bumped to 20m so ARM64 image pulls (~500MB per node × 5 nodes) can finish
# before the wait deadline.
# =============================================================================

resource "helm_release" "longhorn" {
  depends_on = [
    # Wait for ALL workers so Longhorn can place replicas.
    null_resource.bootstrap_worker,
    data.local_sensitive_file.kubeconfig,
  ]

  name             = "longhorn"
  namespace        = var.longhorn_namespace
  create_namespace = true
  repository       = "https://charts.longhorn.io"
  chart            = "longhorn"
  version          = var.longhorn_chart_version

  values = [templatefile("${path.module}/files/helm/longhorn-values.yaml.tftpl", {
    replica_count = var.longhorn_replica_count
  })]

  # Engine images on ARM64 are large and pull serially. 1200s = 20 min has
  # comfortably worked in practice; the first run usually takes 10-15 min.
  timeout = 1200
  wait    = true
}

# Secret holding MinIO creds for Longhorn's BackupTarget.
resource "kubectl_manifest" "longhorn_minio_secret" {
  depends_on = [helm_release.longhorn]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "minio-backup-secret"
      namespace = var.longhorn_namespace
    }
    type = "Opaque"
    stringData = {
      AWS_ACCESS_KEY_ID     = module.nas_minio.minio_root_user
      AWS_SECRET_ACCESS_KEY = module.nas_minio.minio_root_password
      AWS_ENDPOINTS         = module.nas_minio.minio_endpoint
    }
  })
}

# Longhorn settings: backup target + credential secret name.
# Settings are CRD instances ('settings.longhorn.io'); created idempotently.
resource "kubectl_manifest" "longhorn_backup_target_setting" {
  depends_on = [
    helm_release.longhorn,
    kubectl_manifest.longhorn_minio_secret,
    module.nas_minio,
  ]

  yaml_body = yamlencode({
    apiVersion = "longhorn.io/v1beta2"
    kind       = "Setting"
    metadata = {
      name      = "backup-target"
      namespace = var.longhorn_namespace
    }
    value = "s3://${module.nas_minio.minio_bucket_longhorn}@us-east-1/"
  })
}

resource "kubectl_manifest" "longhorn_backup_target_credential_secret" {
  depends_on = [
    helm_release.longhorn,
    kubectl_manifest.longhorn_minio_secret,
  ]

  yaml_body = yamlencode({
    apiVersion = "longhorn.io/v1beta2"
    kind       = "Setting"
    metadata = {
      name      = "backup-target-credential-secret"
      namespace = var.longhorn_namespace
    }
    value = "minio-backup-secret"
  })
}

# =============================================================================
# v2: cert-manager (independent of Longhorn; runs in parallel)
# =============================================================================

resource "helm_release" "cert_manager" {
  depends_on = [
    null_resource.bootstrap_worker,
    data.local_sensitive_file.kubeconfig,
  ]

  name             = "cert-manager"
  namespace        = var.cert_manager_namespace
  create_namespace = true
  repository       = "https://charts.jetstack.io"
  chart            = "cert-manager"
  version          = var.cert_manager_chart_version

  set {
    name  = "crds.enabled"
    value = "true"
  }

  timeout = 300
  wait    = true
}

resource "kubectl_manifest" "selfsigned_clusterissuer" {
  depends_on = [helm_release.cert_manager]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "selfsigned-issuer"
    }
    spec = {
      selfSigned = {}
    }
  })
}

# =============================================================================
# Let's Encrypt issuers (DNS-01 via Cloudflare)
#
# Apps annotate their Ingress with cert-manager.io/cluster-issuer:
#   - letsencrypt-staging  → untrusted certs, very loose rate limits (use while developing)
#   - letsencrypt-prod     → real certs, 50/week per registered domain (use once stable)
#
# Created only when var.cloudflare_api_token is set; safe to leave unset to keep
# the cluster on selfsigned-issuer only.
# =============================================================================

locals {
  # nonsensitive() strips the inherited-sensitivity from the comparison —
  # safe because "is the token set?" doesn't leak the token value itself,
  # but the plain bool is needed for `count` and for non-sensitive outputs.
  letsencrypt_enabled = nonsensitive(var.cloudflare_api_token != null)
}

resource "kubectl_manifest" "cloudflare_api_token_secret" {
  count = local.letsencrypt_enabled ? 1 : 0

  depends_on = [helm_release.cert_manager]

  sensitive_fields = ["stringData.apiToken"]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    type       = "Opaque"
    metadata = {
      name      = "cloudflare-api-token"
      namespace = var.cert_manager_namespace
    }
    stringData = {
      apiToken = var.cloudflare_api_token
    }
  })
}

resource "kubectl_manifest" "letsencrypt_staging" {
  count = local.letsencrypt_enabled ? 1 : 0

  depends_on = [
    helm_release.cert_manager,
    kubectl_manifest.cloudflare_api_token_secret,
  ]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-staging"
    }
    spec = {
      acme = {
        email  = var.acme_email
        server = "https://acme-staging-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "letsencrypt-staging-account-key"
        }
        solvers = [{
          dns01 = {
            cloudflare = {
              apiTokenSecretRef = {
                name = "cloudflare-api-token"
                key  = "apiToken"
              }
            }
          }
        }]
      }
    }
  })
}

resource "kubectl_manifest" "letsencrypt_prod" {
  count = local.letsencrypt_enabled ? 1 : 0

  depends_on = [
    helm_release.cert_manager,
    kubectl_manifest.cloudflare_api_token_secret,
  ]

  yaml_body = yamlencode({
    apiVersion = "cert-manager.io/v1"
    kind       = "ClusterIssuer"
    metadata = {
      name = "letsencrypt-prod"
    }
    spec = {
      acme = {
        email  = var.acme_email
        server = "https://acme-v02.api.letsencrypt.org/directory"
        privateKeySecretRef = {
          name = "letsencrypt-prod-account-key"
        }
        solvers = [{
          dns01 = {
            cloudflare = {
              apiTokenSecretRef = {
                name = "cloudflare-api-token"
                key  = "apiToken"
              }
            }
          }
        }]
      }
    }
  })
}

# =============================================================================
# Cloudflare Tunnel Ingress Controller (STRRL operator)
#
# Per-app workflow becomes pure GitOps:
#   1. Deploy the app's chart with an Ingress that has:
#        ingressClassName: cloudflare-tunnel
#        rules: [{ host: <app>.chifor.dev, ... }]
#   2. The operator picks it up, configures the tunnel public hostname AND
#      the DNS CNAME automatically. Helm uninstall → operator cleans both up.
#
# Traffic flows for a public app:
#   user (internet) → CF edge (TLS terminated) → tunnel → cloudflared pod
#     (managed by the operator) → app's Service
# =============================================================================

locals {
  cloudflare_tunnel_enabled = local.letsencrypt_enabled && var.cloudflare_account_id != null
}

resource "helm_release" "cloudflare_tunnel_ingress" {
  count = local.cloudflare_tunnel_enabled ? 1 : 0

  depends_on = [
    null_resource.bootstrap_worker,
    data.local_sensitive_file.kubeconfig,
  ]

  name             = "cloudflare-tunnel-ingress-controller"
  namespace        = "cloudflare-tunnel-ingress-controller"
  create_namespace = true
  repository       = "https://helm.strrl.dev"
  chart            = "cloudflare-tunnel-ingress-controller"
  version          = var.cloudflare_tunnel_ingress_chart_version

  set_sensitive {
    name  = "cloudflare.apiToken"
    value = var.cloudflare_api_token
  }
  set {
    name  = "cloudflare.accountId"
    value = var.cloudflare_account_id
  }
  set {
    name  = "cloudflare.tunnelName"
    value = var.cloudflare_tunnel_name
  }

  timeout = 300
  wait    = true
}

# =============================================================================
# v2: Rancher (web UI for cluster + workload management)
# =============================================================================

# Always created — referenced via coalesce so an operator-supplied value (via
# TF_VAR_rancher_bootstrap_password) wins, otherwise the random one is used.
resource "random_password" "rancher_bootstrap" {
  length  = 24
  special = false
}

resource "helm_release" "rancher" {
  depends_on = [
    helm_release.cert_manager,
    kubectl_manifest.selfsigned_clusterissuer,
    null_resource.k3s_server_bootstrap, # Traefik HelmChart needs to be up; this gates on the server being healthy
    # NOTE: kubectl_manifest.runtimeclass_sysbox dropped — Sysbox disabled; see comment block above.
  ]

  name             = "rancher"
  namespace        = var.rancher_namespace
  create_namespace = true
  repository       = "https://releases.rancher.com/server-charts/stable"
  chart            = "rancher"
  version          = var.rancher_chart_version

  values = [templatefile("${path.module}/files/helm/rancher-values.yaml.tftpl", {
    hostname           = var.rancher_hostname
    replicas           = var.rancher_replicas
    ingress_class_name = "traefik"
  })]

  set_sensitive {
    name  = "bootstrapPassword"
    value = sensitive(coalesce(var.rancher_bootstrap_password, random_password.rancher_bootstrap.result))
  }

  # Cattle-system + fleet + agents pull a lot of images on first install.
  timeout = 900
  wait    = true
}
