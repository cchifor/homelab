locals {
  k3s_server_url = "https://${var.cp_ip}:6443"

  # Rendered into the Debian cloud-init userdata for the control plane.
  k3s_server_install_env = {
    INSTALL_K3S_VERSION = var.k3s_version
    INSTALL_K3S_EXEC = trim(join(" ", concat([
      "server",
      "--write-kubeconfig-mode=644",
      "--node-ip=${var.cp_ip}",
      "--tls-san=${var.cp_ip}",
      "--flannel-iface=eth0",
    ], var.k3s_extra_server_args)), " ")
  }

  # Helm values for Longhorn — rendered into a values file at apply time.
  longhorn_values = {
    persistence = {
      defaultClass             = true
      defaultClassReplicaCount = var.longhorn_replica_count
    }
    defaultSettings = {
      defaultDataPath = "/var/lib/longhorn"
    }
  }

  # K3s nodes that need Sysbox-CE installed. Workers only — the control-plane
  # server has the default `node-role.kubernetes.io/control-plane:NoSchedule`
  # taint, so user workloads don't land there and don't need the sysbox runtime.
  # Adding sysbox to the server's containerd has also caused k3s↔containerd CRI
  # handshake failures on this hardware (May 2026); workers are unaffected.
  sysbox_targets = {
    for k, w in var.workers : k => {
      address     = w.address
      ssh_user    = w.ssh_user
      ssh_key     = w.ssh_key
      k3s_service = "k3s-agent"
    }
  }
}
