terraform {
  required_providers {
    proxmox = { source = "Telmate/proxmox" }
    random  = { source = "hashicorp/random" }
    null    = { source = "hashicorp/null" }
  }
}

# Bind-mount + privileged-LXC strategy assumes uid 0 in container == uid 0 on host.
# Flipping unprivileged=true here without redoing the mount perms breaks ZFS access
# silently from inside the container.
resource "terraform_data" "privileged_precondition" {
  lifecycle {
    precondition {
      condition     = var.unprivileged == false
      error_message = "Bind-mount + MinIO permission strategy assumes a privileged container. Do not set unprivileged=true without re-doing the bind-mount UID/GID mapping."
    }
  }
}

resource "random_password" "minio_root" {
  length  = 32
  special = false
  upper   = true
  lower   = true
  numeric = true
}

resource "proxmox_lxc" "this" {
  depends_on = [terraform_data.privileged_precondition]

  target_node  = var.node_name
  hostname     = var.hostname
  ostemplate   = var.template
  unprivileged = var.unprivileged

  cores  = var.cores
  memory = var.memory_mb

  rootfs {
    storage = var.storage_pool
    size    = var.rootfs_size
  }

  # NOTE: bind mounts are NOT declared here. PVE hardcodes a security check
  # ("mount point type bind is only allowed for root@pam") that blocks API
  # tokens from creating LXCs with bind mounts, regardless of role/permissions.
  # Workaround: a separate null_resource SSHes to the Proxmox host as root
  # and runs `pct set <ctid> -mp0 ...` after the container is created.
  # See null_resource.bind_mount below.

  network {
    name   = "eth0"
    bridge = var.bridge
    ip     = "${var.ip}${var.lan_cidr_suffix}"
    gw     = var.gateway
    mtu    = var.mtu
  }

  nameserver = join(" ", var.dns)

  # NOTE: `features { nesting = ... }` is intentionally omitted. PVE blocks
  # API tokens from changing feature flags on privileged containers
  # ("only allowed for root@pam") — same class as the bind-mount restriction.
  # MinIO doesn't need nesting/keyctl/fuse/mount features, so we just don't
  # set them. If a future use case requires them, add via `pct set` from a
  # post-create null_resource (mirroring null_resource.bind_mount).

  ssh_public_keys = var.ssh_public_key

  start  = true
  onboot = true
}

# Add the bind mount via `pct set` from the Proxmox host (workaround for the
# API-token restriction described above). Stops + starts the container so the
# new mount is actually visible inside.
resource "null_resource" "bind_mount" {
  depends_on = [proxmox_lxc.this]

  triggers = {
    ctid           = proxmox_lxc.this.vmid
    bind_host_path = var.bind_host_path
    bind_ct_path   = var.bind_ct_path
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_host_address
    user        = var.proxmox_host_ssh_user
    private_key = file(var.proxmox_host_ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      # Idempotent: -mp0 just (re)sets it; if already set with same value, no-op.
      "pct set ${proxmox_lxc.this.vmid} -mp0 ${var.bind_host_path},mp=${var.bind_ct_path},backup=0",
      # Restart the CT so the mount appears inside.
      "pct stop ${proxmox_lxc.this.vmid} 2>/dev/null || true",
      "pct start ${proxmox_lxc.this.vmid}",
      # Wait for the CT to be running again before any downstream provisioner runs.
      "for i in $(seq 1 30); do pct status ${proxmox_lxc.this.vmid} | grep -q 'status: running' && exit 0; sleep 2; done; echo 'CT did not start' >&2; exit 1",
    ]
  }
}

# MinIO bootstrap: SSH to the Proxmox host and use `pct exec` to run inside the LXC.
# (Driving via the host avoids requiring sshd inside the container.)
resource "null_resource" "minio_bootstrap" {
  depends_on = [proxmox_lxc.this, null_resource.bind_mount]

  triggers = {
    ctid          = proxmox_lxc.this.vmid
    minio_version = var.minio_version
    minio_root_pw = sha256(random_password.minio_root.result) # rotate triggers re-bootstrap
    bucket        = var.minio_bucket_longhorn
    bind_ct_path  = var.bind_ct_path
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_host_address
    user        = var.proxmox_host_ssh_user
    private_key = file(var.proxmox_host_ssh_private_key_path)
  }

  provisioner "file" {
    content = templatefile("${path.module}/../../files/cloud-init/minio-bootstrap.sh.tftpl", {
      ctid            = proxmox_lxc.this.vmid
      minio_version   = var.minio_version
      minio_root_user = "admin"
      minio_root_pw   = random_password.minio_root.result
      minio_data_dir  = var.bind_ct_path
      minio_bucket    = var.minio_bucket_longhorn
    })
    destination = "/tmp/minio-bootstrap-${proxmox_lxc.this.vmid}.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/minio-bootstrap-${proxmox_lxc.this.vmid}.sh",
      "/tmp/minio-bootstrap-${proxmox_lxc.this.vmid}.sh",
      "rm -f /tmp/minio-bootstrap-${proxmox_lxc.this.vmid}.sh",
    ]
  }
}
