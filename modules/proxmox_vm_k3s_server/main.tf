terraform {
  required_providers {
    proxmox = { source = "Telmate/proxmox" }
  }
}

resource "proxmox_vm_qemu" "this" {
  target_node = var.node_name
  name        = var.hostname
  clone       = var.template_name
  full_clone  = true

  agent   = 1
  bios    = var.bios
  scsihw  = "virtio-scsi-single"
  boot    = "order=scsi0"
  os_type = "cloud-init"

  cpu {
    type    = "host"
    cores   = var.cores
    sockets = var.sockets
    numa    = false
  }

  memory = var.memory_mb

  # Resize the cloned disk to disk_size (Telmate handles this on first apply via the
  # nested `disks` block when storage matches the cloned source pool).
  disks {
    scsi {
      scsi0 {
        disk {
          storage  = var.storage_pool
          size     = var.disk_size
          iothread = true
          format   = "raw"
        }
      }
    }
    ide {
      ide2 {
        cloudinit {
          storage = var.storage_pool
        }
      }
    }
  }

  network {
    id     = 0
    model  = "virtio"
    bridge = var.bridge
    mtu    = var.mtu
  }

  # Debian cloud image's kernel cmdline expects a serial console; without this,
  # the clone drops the template's serial0 and boot stalls before cloud-init can
  # apply network config. (`vga: serial0` is inherited from the template.)
  serial {
    id   = 0
    type = "socket"
  }

  # Cloud-init parameters (inline; we install k3s post-boot via a separate null_resource).
  ciuser       = var.ssh_user
  sshkeys      = var.ssh_public_key
  ipconfig0    = "ip=${var.ip}${var.lan_cidr_suffix},gw=${var.gateway}"
  nameserver   = join(" ", var.dns)
  searchdomain = "lan"

  onboot   = true
  vm_state = "running"

  # Don't churn on cosmetic disk attribute drift the provider sometimes reports.
  lifecycle {
    ignore_changes = [
      network[0].macaddr,
      disks[0].scsi[0].scsi0[0].disk[0].iothread,
    ]
  }
}
