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

  # Two disks:
  #   scsi0 - root  (OS, apt cache, /var/lib/docker — treated as ephemeral)
  #   scsi1 - data  (mounted /workspace inside the VM; ZFS-snapshotted on the host)
  disks {
    scsi {
      scsi0 {
        disk {
          storage  = var.storage_pool
          size     = var.root_disk_size
          iothread = true
          format   = "raw"
        }
      }
      scsi1 {
        disk {
          storage  = var.storage_pool
          size     = var.data_disk_size
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

  serial {
    id   = 0
    type = "socket"
  }

  ciuser       = var.ssh_user
  sshkeys      = var.ssh_public_key
  ipconfig0    = "ip=${var.ip}${var.lan_cidr_suffix},gw=${var.gateway}"
  nameserver   = join(" ", var.dns)
  searchdomain = "lan"

  onboot   = true
  vm_state = "running"

  lifecycle {
    ignore_changes = [
      network[0].macaddr,
      disks[0].scsi[0].scsi0[0].disk[0].iothread,
      disks[0].scsi[0].scsi1[0].disk[0].iothread,
    ]
  }
}
