# =============================================================================
# Incus-hosted claude-worker VMs (rdxa1..rdxa4 each host one VM)
#
# Each rdxa host runs k3s-agent + Incus side-by-side. claude-workerN is a VM
# managed by Incus, pinned to rdxaN via the `target` attribute. The VM gets a
# 32GiB root and a 48GiB custom block volume mounted at /workspace by the
# bootstrap script that runs after first boot.
#
# Naming convention:
#   - Host:                 rdxaN
#   - Incus instance:       claude-worker-N
#   - Incus data volume:    claude-worker-N-data
#   - VM LAN IP:            192.168.0.14N (set via cloud-init.network-config)
#
# The Incus cluster was rebuilt on 2026-05-19 (see platform/README.md §
# "Rebuilding the Incus cluster"). These resources were imported into state
# afterwards via the `terraform import` commands in that section.
#
# The default profile already provides the eth0 macvlan NIC + root disk; this
# file only declares per-instance config: limits, custom data device, and the
# cloud-init blocks. To rotate the SSH key, edit
# var.incus_claude_worker_ssh_pubkey and `tofu apply` — no recreate needed.
# =============================================================================

locals {
  # rdxaN host name from the workers map; assumes 4 workers in the cluster.
  # If the cluster grows beyond 4, add a "claude_worker" flag to var.workers
  # so we can filter by capability instead of relying on the rdxa* naming.
  claude_worker_hosts = {
    for k, w in var.workers : k => w
    if startswith(k, "rdxa")
  }

  # claude-worker-N → rdxaN  (N = the trailing digit on rdxaN)
  claude_workers = {
    for k, w in local.claude_worker_hosts : "claude-worker-${trimprefix(k, "rdxa")}" => {
      target       = k
      vm_ip        = "192.168.0.14${trimprefix(k, "rdxa")}"
      data_volume  = "claude-worker-${trimprefix(k, "rdxa")}-data"
      host_address = w.address
    }
  }
}

# -----------------------------------------------------------------------------
# Per-VM data volume (48 GiB block, mounted at /workspace by bootstrap)
# -----------------------------------------------------------------------------
resource "incus_storage_volume" "claude_worker_data" {
  for_each = local.claude_workers

  name         = each.value.data_volume
  pool         = var.incus_target_pool
  content_type = "block"
  target       = each.value.target

  config = {
    size = var.incus_claude_worker_data_size
  }
}

# -----------------------------------------------------------------------------
# VM instances (one per rdxa host)
# -----------------------------------------------------------------------------
resource "incus_instance" "claude_worker" {
  for_each = local.claude_workers

  name     = each.key
  type     = "virtual-machine"
  image    = var.incus_claude_worker_image
  target   = each.value.target
  profiles = ["default"]

  # VM resource limits — shared CPU + ballooned memory so the host can reclaim
  # under pressure. See project memory for the 2026-05-19 OOM incident: doing
  # two heavy in-VM bootstraps in parallel pushed two rdxa hosts past their
  # safety margin and killed sshd on each.
  config = {
    "boot.autostart"            = "true"
    "limits.cpu"                = var.incus_claude_worker_cpu_limit
    "limits.memory"             = var.incus_claude_worker_memory_limit
    "cloud-init.user-data"      = <<-EOT
      #cloud-config
      hostname: ${each.key}
      manage_etc_hosts: true
      fqdn: ${each.key}.lan
      users:
        - name: c4
          groups: [sudo]
          sudo: ALL=(ALL) NOPASSWD:ALL
          shell: /bin/bash
          ssh_authorized_keys:
            - ${var.incus_claude_worker_ssh_pubkey}
      # openssh-server is missing from images:debian/12/cloud arm64. List it
      # explicitly so SSH ends up on disk even if package_update fails on
      # early-boot DNS.
      package_update: true
      packages:
        - openssh-server
        - qemu-guest-agent
      runcmd:
        - systemctl enable --now ssh
        - systemctl enable --now qemu-guest-agent
    EOT
    "cloud-init.network-config" = <<-EOT
      version: 2
      ethernets:
        primary:
          match:
            driver: virtio_net
          set-name: enp5s0
          dhcp4: false
          addresses:
            - ${each.value.vm_ip}/23
          gateway4: 192.168.0.1
          nameservers:
            addresses:
              - 1.1.1.1
              - 192.168.0.1
    EOT
  }

  # Root disk size override at the instance level (default profile defines the
  # root device's pool but lets us size per-instance).
  device {
    name = "root"
    type = "disk"
    properties = {
      pool = var.incus_target_pool
      path = "/"
      size = var.incus_claude_worker_root_size
    }
  }

  # Custom data block volume (separate from root). The bootstrap script formats
  # /dev/sdb as ext4 and mounts it at /workspace.
  device {
    name = "data"
    type = "disk"
    properties = {
      pool   = var.incus_target_pool
      source = each.value.data_volume
    }
  }

  depends_on = [incus_storage_volume.claude_worker_data]
}

# -----------------------------------------------------------------------------
# Run the claude-worker bootstrap after each VM is up. Idempotent — every step
# in the script checks before acting. SSH'd directly to the VM, not via Incus.
#
# Re-runs only when the rendered script content changes (e.g. you edit the
# template, or the ssh_user variable changes).
# -----------------------------------------------------------------------------
resource "null_resource" "claude_worker_incus_bootstrap" {
  for_each = local.claude_workers

  depends_on = [incus_instance.claude_worker]

  triggers = {
    vm_id = incus_instance.claude_worker[each.key].id
    # Re-run when the bootstrap template changes. The actual rendered content
    # is the source of truth so any edit to the .tftpl triggers a re-apply.
    script_sha = sha256(templatefile("${path.module}/files/cloud-init/claude-worker-bootstrap.sh.tftpl", {
      ssh_user        = "c4"
      cf_tunnel_token = var.claude_worker_cf_tunnel_token
      restic_repo_url = var.claude_worker_restic_repo_url
      restic_password = var.claude_worker_restic_password
      c4_password     = var.claude_worker_c4_password
    }))
  }

  connection {
    type        = "ssh"
    host        = each.value.vm_ip
    user        = "c4"
    private_key = file(pathexpand("~/.ssh/id_ed25519"))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/files/cloud-init/claude-worker-bootstrap.sh.tftpl", {
      ssh_user        = "c4"
      cf_tunnel_token = var.claude_worker_cf_tunnel_token
      restic_repo_url = var.claude_worker_restic_repo_url
      restic_password = var.claude_worker_restic_password
      c4_password     = var.claude_worker_c4_password
    })
    destination = "/tmp/claude-worker-bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/claude-worker-bootstrap.sh",
      "sudo /tmp/claude-worker-bootstrap.sh",
      "rm -f /tmp/claude-worker-bootstrap.sh",
    ]
  }
}
