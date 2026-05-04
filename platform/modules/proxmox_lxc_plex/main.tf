terraform {
  required_providers {
    proxmox = { source = "Telmate/proxmox" }
    null    = { source = "hashicorp/null" }
  }
}

# Privileged Debian LXC with /dev/dri (Intel iGPU) bind-mounted from the host
# for Plex hardware-accelerated transcoding via QuickSync. Mirrors the MinIO
# LXC pattern (see modules/proxmox_lxc_minio) — same workarounds for the PVE
# API-token bind-mount restriction.
resource "terraform_data" "privileged_precondition" {
  lifecycle {
    precondition {
      condition     = var.unprivileged == false
      error_message = "iGPU /dev/dri bind-mount + Plex group permissions assume a privileged container. Don't flip unprivileged=true without remapping the cgroup device allows for shifted UIDs."
    }
  }
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

  # Bind mounts (mp0 = library/media on /nvme-pool) added via post-create
  # null_resource — PVE blocks bind-mount declarations from API tokens.

  network {
    name   = "eth0"
    bridge = var.bridge
    ip     = "${var.ip}${var.lan_cidr_suffix}"
    gw     = var.gateway
    mtu    = var.mtu
  }

  nameserver = join(" ", var.dns)

  ssh_public_keys = var.ssh_public_key

  start  = true
  onboot = true
}

# Storage bind (/nvme-pool/plex → /srv/plex) and iGPU /dev/dri bind via
# host-side `pct set` + direct conf append (cgroup device allows aren't
# expressible as PVE `pct set` parameters; they go straight into the conf).
resource "null_resource" "lxc_postcreate" {
  depends_on = [proxmox_lxc.this]

  triggers = {
    ctid              = proxmox_lxc.this.vmid
    bind_host_path    = var.bind_host_path
    bind_ct_path      = var.bind_ct_path
    igpu              = var.igpu_passthrough_enabled ? "yes" : "no"
    igpu_card_minor   = var.igpu_card_minor
    igpu_render_minor = var.igpu_render_minor
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_host_address
    user        = var.proxmox_host_ssh_user
    private_key = file(var.proxmox_host_ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      # 1. Storage bind for library + media
      "pct set ${proxmox_lxc.this.vmid} -mp0 ${var.bind_host_path},mp=${var.bind_ct_path},backup=0",

      # 2. iGPU passthrough — append cgroup allows + dev mount entries to the
      #    LXC conf directly. /etc/pve/lxc/<ctid>.conf is the canonical place
      #    for `lxc.mount.entry` and `lxc.cgroup2.devices.allow` (no PVE-level
      #    abstraction for these). Idempotent: grep first, append only if missing.
      #    Device names + minors come from `ls -la /dev/dri` on the host —
      #    Alder Lake-N exposes card1 + renderD128 (not card0). Override via
      #    var.igpu_card_minor / var.igpu_render_minor for other systems.
      var.igpu_passthrough_enabled ? <<-EOT
        CONF=/etc/pve/lxc/${proxmox_lxc.this.vmid}.conf
        for line in \
          'lxc.cgroup2.devices.allow: c 226:${var.igpu_card_minor} rwm' \
          'lxc.cgroup2.devices.allow: c 226:${var.igpu_render_minor} rwm' \
          'lxc.mount.entry: /dev/dri/${var.igpu_card_name} dev/dri/${var.igpu_card_name} none bind,optional,create=file' \
          'lxc.mount.entry: /dev/dri/${var.igpu_render_name} dev/dri/${var.igpu_render_name} none bind,optional,create=file'; do
          grep -qF "$line" $CONF || echo "$line" >> $CONF
        done
      EOT
      : "echo 'iGPU passthrough disabled — skipping /dev/dri bind'",

      # Restart the CT so all the new config takes effect
      "pct stop ${proxmox_lxc.this.vmid} 2>/dev/null || true",
      "pct start ${proxmox_lxc.this.vmid}",
      # Wait for it to come back up before any downstream provisioner runs
      "for i in $(seq 1 30); do pct status ${proxmox_lxc.this.vmid} | grep -q 'status: running' && exit 0; sleep 2; done; echo 'CT did not start' >&2; exit 1",
    ]
  }
}

# Plex install: SSH to Proxmox host, drive `pct exec` to run inside the LXC.
resource "null_resource" "plex_bootstrap" {
  depends_on = [proxmox_lxc.this, null_resource.lxc_postcreate]

  triggers = {
    ctid         = proxmox_lxc.this.vmid
    plex_version = var.plex_version
    bind_ct_path = var.bind_ct_path
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_host_address
    user        = var.proxmox_host_ssh_user
    private_key = file(var.proxmox_host_ssh_private_key_path)
  }

  provisioner "file" {
    content = templatefile("${path.module}/../../files/cloud-init/plex-bootstrap.sh.tftpl", {
      ctid          = proxmox_lxc.this.vmid
      plex_version  = var.plex_version
      plex_data_dir = var.bind_ct_path
    })
    destination = "/tmp/plex-bootstrap-${proxmox_lxc.this.vmid}.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/plex-bootstrap-${proxmox_lxc.this.vmid}.sh",
      "/tmp/plex-bootstrap-${proxmox_lxc.this.vmid}.sh",
      "rm -f /tmp/plex-bootstrap-${proxmox_lxc.this.vmid}.sh",
    ]
  }
}
