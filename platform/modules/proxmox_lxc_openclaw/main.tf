terraform {
  required_providers {
    proxmox = { source = "Telmate/proxmox" }
    null    = { source = "hashicorp/null" }
  }
}

# Privileged Debian LXC running OpenClaw — autonomous AI assistant that uses
# Docker as its sandbox backend + Playwright for browser automation. Mirrors
# the Plex LXC pattern (modules/proxmox_lxc_plex) plus Docker-in-LXC nesting.
resource "terraform_data" "privileged_precondition" {
  lifecycle {
    precondition {
      condition     = var.unprivileged == false
      error_message = "Docker-in-LXC requires a privileged container plus nesting+keyctl features. Flipping unprivileged=true breaks Docker without remapping kernel cap allowlists."
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

# Storage bind mount + Docker-in-LXC features (nesting + keyctl) added via
# host-side `pct set` — same workaround as the Plex/MinIO LXCs because PVE
# blocks API tokens from setting features at create time.
resource "null_resource" "lxc_postcreate" {
  depends_on = [proxmox_lxc.this]

  triggers = {
    ctid           = proxmox_lxc.this.vmid
    bind_host_path = var.bind_host_path
    bind_ct_path   = var.bind_ct_path
    features       = "nesting=1,keyctl=1"
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_host_address
    user        = var.proxmox_host_ssh_user
    private_key = file(var.proxmox_host_ssh_private_key_path)
  }

  provisioner "remote-exec" {
    inline = [
      # 1. Storage bind for OpenClaw persistent state (npm global, agent skills,
      #    conversation memory, Playwright cache, Docker volumes).
      "pct set ${proxmox_lxc.this.vmid} -mp0 ${var.bind_host_path},mp=${var.bind_ct_path},backup=0",

      # 2. Enable nesting + keyctl. Docker-in-LXC needs these:
      #    - nesting:    allows the inner Docker daemon to use cgroups + namespaces
      #    - keyctl:     Docker uses kernel keyrings for credential storage
      "pct set ${proxmox_lxc.this.vmid} -features nesting=1,keyctl=1",

      # 3. Restart so all the new config takes effect
      "pct stop ${proxmox_lxc.this.vmid} 2>/dev/null || true",
      "pct start ${proxmox_lxc.this.vmid}",
      "for i in $(seq 1 30); do pct status ${proxmox_lxc.this.vmid} | grep -q 'status: running' && exit 0; sleep 2; done; echo 'CT did not start' >&2; exit 1",
    ]
  }
}

# Bootstrap: install Docker CE, Node 24, OpenClaw, Playwright + browsers
resource "null_resource" "openclaw_bootstrap" {
  depends_on = [proxmox_lxc.this, null_resource.lxc_postcreate]

  triggers = {
    ctid              = proxmox_lxc.this.vmid
    node_major        = var.node_major_version
    openclaw_pkg_spec = var.openclaw_pkg_spec
    bind_ct_path      = var.bind_ct_path
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_host_address
    user        = var.proxmox_host_ssh_user
    private_key = file(var.proxmox_host_ssh_private_key_path)
  }

  provisioner "file" {
    content = templatefile("${path.module}/../../files/cloud-init/openclaw-bootstrap.sh.tftpl", {
      ctid              = proxmox_lxc.this.vmid
      node_major        = var.node_major_version
      openclaw_pkg_spec = var.openclaw_pkg_spec
      data_dir          = var.bind_ct_path
    })
    destination = "/tmp/openclaw-bootstrap-${proxmox_lxc.this.vmid}.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/openclaw-bootstrap-${proxmox_lxc.this.vmid}.sh",
      "/tmp/openclaw-bootstrap-${proxmox_lxc.this.vmid}.sh",
      "rm -f /tmp/openclaw-bootstrap-${proxmox_lxc.this.vmid}.sh",
    ]
  }
}
