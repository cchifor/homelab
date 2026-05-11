# Claude Code Worker — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Provision a Proxmox VM running Claude Code CLI for both interactive (LAN + Cloudflare Access SSH + ttyd) and headless (systemd timers) workloads, with shared OAuth, two-tier k8s RBAC, ZFS-snapshotted workspace, and restic-to-MinIO backup.

**Architecture:** New Terraform module `proxmox_vm_claude_worker` mirroring `proxmox_vm_k3s_server`, gated by `claude_worker_enabled` flag. Cloud-init does NOTHING beyond the standard Debian 12 image — all software install happens in a single `claude-worker-bootstrap.sh.tftpl` run via SSH `null_resource`, the same pattern as `k3s-server-bootstrap.sh.tftpl`. Two ServiceAccounts (`claude-agent-ro`, `claude-agent-rw`) are created via `kubectl_manifest` in root `main.tf`; their kubeconfigs are rendered locally then scped to the VM by a follow-on `null_resource`.

**Tech Stack:** OpenTofu / Terraform, Telmate/proxmox 3.x provider, alekc/kubectl, hashicorp/helm, Debian 12 cloud image, Docker Engine + Compose v2, ttyd, Caddy, cloudflared, sanoid, restic, systemd timers, Claude Code CLI (npm).

**Reference spec:** `docs/superpowers/specs/2026-05-11-claude-code-worker-design.md`

**Conventions to honor (from user memory):**
- Run `terraform fmt -recursive` before every commit
- No `Co-Authored-By: Claude` trailer in commit messages
- Default OS username on new hosts is `c4` (not `chifor`)
- Plan-first, recommend-then-confirm

**Verification commands referenced repeatedly:**
- `tofu plan` from `platform/` — should be `No changes` after each task settles
- `ssh c4@192.168.0.190 '<cmd>'` — verify on the VM
- The full spec § "Verification" runs at end of Task 24

---

## Phase 1 — VM provisioning skeleton

Outcome of this phase: an empty Debian 12 VM at `192.168.0.190` accessible via `ssh c4@`. No claude-code, no docker yet.

### Task 1: Module skeleton

**Files:**
- Create: `platform/modules/proxmox_vm_claude_worker/main.tf`
- Create: `platform/modules/proxmox_vm_claude_worker/variables.tf`
- Create: `platform/modules/proxmox_vm_claude_worker/outputs.tf`

- [ ] **Step 1: Create `platform/modules/proxmox_vm_claude_worker/main.tf`**

```hcl
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
```

- [ ] **Step 2: Create `platform/modules/proxmox_vm_claude_worker/variables.tf`**

```hcl
variable "node_name" {
  type        = string
  description = "Proxmox node name."
}

variable "hostname" {
  type        = string
  description = "VM hostname / PVE VM name."
}

variable "template_name" {
  type        = string
  description = "Debian 12 cloud-init template VM to clone."
}

variable "cores" {
  type    = number
  default = 4
}

variable "sockets" {
  type    = number
  default = 1
}

variable "memory_mb" {
  type    = number
  default = 8192
}

variable "root_disk_size" {
  type    = string
  default = "16G"
}

variable "data_disk_size" {
  type    = string
  default = "48G"
}

variable "storage_pool" {
  type    = string
  default = "local-zfs"
}

variable "bios" {
  type    = string
  default = "seabios"
}

variable "ip" {
  type        = string
  description = "Static IPv4 (no CIDR)."
}

variable "lan_cidr_suffix" {
  type    = string
  default = "/24"
}

variable "gateway" {
  type        = string
  description = "Default gateway."
}

variable "dns" {
  type        = list(string)
  description = "DNS resolvers."
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "mtu" {
  type    = number
  default = 1500
}

variable "ssh_user" {
  type        = string
  description = "Cloud-init default user (e.g. 'c4')."
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key authorized for ssh_user."
}
```

- [ ] **Step 3: Create `platform/modules/proxmox_vm_claude_worker/outputs.tf`**

```hcl
output "vmid" {
  value       = proxmox_vm_qemu.this.vmid
  description = "Proxmox VM ID."
}

output "vm_ip" {
  value       = var.ip
  description = "Static IP of the worker VM."
}

output "ssh_user" {
  value       = var.ssh_user
  description = "SSH user (cloud-init default user)."
}
```

- [ ] **Step 4: Format**

```bash
cd platform && terraform fmt -recursive
```

- [ ] **Step 5: Commit**

```bash
git add platform/modules/proxmox_vm_claude_worker/
git commit -m "claude-worker: empty module skeleton

Mirrors proxmox_vm_k3s_server's structure: clone Debian 12 template,
attach two disks (root 16G, data 48G), set static IP and SSH key via
cloud-init. No software installed yet — that's the bootstrap script in
a follow-up task."
```

---

### Task 2: Root variables for the worker

**Files:**
- Modify: `platform/variables.tf` (append at end)

- [ ] **Step 1: Append claude-worker variable block to `platform/variables.tf`**

```hcl
# =============================================================================
# Claude Code worker VM
# =============================================================================

variable "claude_worker_enabled" {
  type        = bool
  default     = false
  description = "Deploy the Claude Code worker VM. Off by default — flip to true (in tfvars or TF_VAR_claude_worker_enabled=true) when you want it."
}

variable "claude_worker_hostname" {
  type        = string
  default     = "claude-worker"
}

variable "claude_worker_ip" {
  type        = string
  default     = "192.168.0.190"
  description = "Static LAN IP."
}

variable "claude_worker_cores" {
  type    = number
  default = 4
}

variable "claude_worker_memory_mb" {
  type    = number
  default = 8192
}

variable "claude_worker_root_disk" {
  type    = string
  default = "16G"
}

variable "claude_worker_data_disk" {
  type    = string
  default = "48G"
}

variable "claude_worker_storage_pool" {
  type    = string
  default = "local-zfs"
}

variable "claude_worker_template_name" {
  type        = string
  description = "Pre-existing Debian 12 cloud-init template VM (created by prep-proxmox.sh)."
  default     = "debian-12-cloudinit-template"
}

variable "claude_worker_ssh_user" {
  type        = string
  default     = "c4"
  description = "Primary OS user (sudoer) on the worker."
}

variable "claude_worker_ssh_public_key" {
  type        = string
  description = "SSH public key contents (the value, not path) authorized for ssh_user. Set in tfvars or via TF_VAR_claude_worker_ssh_public_key."
}

variable "claude_worker_ssh_private_key_path" {
  type        = string
  default     = "~/.ssh/id_ed25519"
  description = "Local path to the SSH private key matching claude_worker_ssh_public_key. Used by null_resource provisioners to drive the VM."
}

# Cloudflare Tunnel token for the worker's standalone cloudflared.
# Create the tunnel in CF Zero Trust dashboard, paste the connector token
# as TF_VAR_claude_worker_cf_tunnel_token. Two DNS routes
# (worker-ssh.chifor.dev, claude.chifor.dev) and the CF Access policy
# are configured in the dashboard out-of-band; see the module README.
variable "claude_worker_cf_tunnel_token" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Cloudflare tunnel connector token. Leave empty to skip cloudflared install (LAN-only mode)."
}

# Restic + MinIO
variable "claude_worker_restic_repo_url" {
  type        = string
  default     = "s3:http://192.168.0.186:9000/claude-worker-backup"
  description = "Restic repository URL. Points at the NAS LXC's MinIO."
}

variable "claude_worker_restic_password" {
  type        = string
  default     = ""
  sensitive   = true
  description = "Restic encryption password. Set via TF_VAR_claude_worker_restic_password. Operator MUST also save this in Vaultwarden — losing it makes the backup unrecoverable."
}
```

- [ ] **Step 2: Format + commit**

```bash
cd platform && terraform fmt -recursive
git add platform/variables.tf
git commit -m "claude-worker: root variables for the new module

Off by default (claude_worker_enabled=false). Sizing defaults match
spec: 4 vCPU, 8 GB, 16 G + 48 G ZFS-backed disks. Sensitive inputs
(SSH pubkey content, CF tunnel token, restic password) sourced via
env vars; no plaintext in tfvars."
```

---

### Task 3: terraform.tfvars.example entries

**Files:**
- Modify: `platform/terraform.tfvars.example` (append a commented block)

- [ ] **Step 1: Append to `platform/terraform.tfvars.example`**

```hcl

# =============================================================================
# Claude Code worker VM (optional — flip claude_worker_enabled=true to deploy)
# =============================================================================
# Most fields have sane defaults in variables.tf; only override what you need.
# Sensitive values (CF tunnel token, restic password, SSH pubkey) come from
# env vars: TF_VAR_claude_worker_cf_tunnel_token, TF_VAR_claude_worker_restic_password,
# TF_VAR_claude_worker_ssh_public_key.

# claude_worker_enabled    = true
# claude_worker_ip         = "192.168.0.190"
# claude_worker_cores      = 4
# claude_worker_memory_mb  = 8192
# claude_worker_root_disk  = "16G"
# claude_worker_data_disk  = "48G"
```

- [ ] **Step 2: Commit**

```bash
git add platform/terraform.tfvars.example
git commit -m "claude-worker: tfvars.example stub (commented)"
```

---

### Task 4: Wire module into root `main.tf` (VM only, no bootstrap yet)

**Files:**
- Modify: `platform/main.tf` (insert after the `plex_lxc` module block)

- [ ] **Step 1: Insert new module block after the existing `plex_lxc` module**

```hcl
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
```

- [ ] **Step 2: Format**

```bash
cd platform && terraform fmt -recursive
```

- [ ] **Step 3: Plan-only check (with claude_worker_enabled=false, expect no changes)**

```bash
cd platform && tofu plan
```

Expected: `No changes. Your infrastructure matches the configuration.`

- [ ] **Step 4: Commit**

```bash
git add platform/main.tf
git commit -m "claude-worker: wire module into root main.tf

Gated by count = var.claude_worker_enabled ? 1 : 0 — same pattern as
plex_lxc. With the gate off this is a no-op; tofu plan reports no
changes."
```

---

### Task 5: First apply — bring the VM up

**Files:** (none — runtime activation)

- [ ] **Step 1: In `platform/terraform.tfvars`, enable the worker**

Append:
```hcl
claude_worker_enabled        = true
claude_worker_ssh_public_key = file("~/.ssh/id_ed25519.pub")
```

(Note: don't commit terraform.tfvars — it's in .gitignore. This change is operator-side only.)

- [ ] **Step 2: Plan and apply**

```bash
cd platform
tofu plan        # expect: ~1 to add (proxmox_vm_qemu.this)
tofu apply       # type 'yes'
```

- [ ] **Step 3: Verify VM is up and reachable**

```bash
ping -c 3 192.168.0.190
ssh -o StrictHostKeyChecking=accept-new c4@192.168.0.190 'uname -a && lsblk'
```

Expected: ping succeeds, `uname` returns `Linux claude-worker 6.x ...`, `lsblk` shows `sda` (16G root) + `sdb` (48G data, unformatted).

- [ ] **Step 4: Commit (state only — no repo changes)**

No commit at this step. The VM creation is reflected in `terraform.tfstate` which is gitignored.

---

## Phase 2 — Bootstrap script (additive sections)

A single `claude-worker-bootstrap.sh.tftpl` does everything. We build it section-by-section; each task appends one section, re-runs the bootstrap via Terraform, and verifies. Same pattern as `k3s-server-bootstrap.sh.tftpl` but with more layers.

The bootstrap script will be invoked by a `null_resource` `claude_worker_bootstrap` whose `triggers` include a hash of the rendered script contents — so any change to the template re-runs the whole thing. The script is idempotent: every step short-circuits if already applied.

### Task 6: Bootstrap section 1 — base packages + tmux + `claude-agent` user + `/workspace`

**Files:**
- Create: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl`
- Modify: `platform/main.tf` (add `null_resource.claude_worker_bootstrap`)

- [ ] **Step 1: Create `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl`**

```bash
#!/bin/bash
# Claude Code worker post-boot bootstrap.
# Driven from the operator machine via SSH; runs as root on the VM (sudo).
# Idempotent — re-running re-applies; every section short-circuits if already done.

set -euo pipefail

echo "==> claude-worker bootstrap starting"

# -----------------------------------------------------------------------------
# Section 1: base packages + tmux defaults + claude-agent user + /workspace mount
# -----------------------------------------------------------------------------
echo "==> [1/?] base packages + users + /workspace"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  build-essential curl wget git gh jq ripgrep fzf bat \
  tmux htop ncdu unzip ca-certificates gnupg lsb-release \
  ufw acl

# yq is in a different repo on Debian — install via mikefarah binary release.
# Distro 'yq' is the Python jq-wrapper, not what we want.
if ! command -v /usr/local/bin/yq >/dev/null 2>&1; then
  curl -sSLo /usr/local/bin/yq \
    https://github.com/mikefarah/yq/releases/download/v4.44.5/yq_linux_amd64
  chmod +x /usr/local/bin/yq
fi

# claude-agent user (no sudo, no shell login by default)
if ! id claude-agent >/dev/null 2>&1; then
  adduser --system --group --shell /bin/bash --home /home/claude-agent claude-agent
  mkdir -p /home/claude-agent/.ssh
  cp /home/${ssh_user}/.ssh/authorized_keys /home/claude-agent/.ssh/authorized_keys
  chown -R claude-agent:claude-agent /home/claude-agent
  chmod 700 /home/claude-agent/.ssh
  chmod 600 /home/claude-agent/.ssh/authorized_keys
fi

# /workspace from /dev/sdb (the 48 G data disk)
if ! mountpoint -q /workspace; then
  if ! blkid /dev/sdb >/dev/null 2>&1; then
    mkfs.ext4 -L workspace /dev/sdb
  fi
  mkdir -p /workspace
  echo "LABEL=workspace /workspace ext4 defaults,noatime 0 2" >> /etc/fstab
  mount /workspace
fi
# Group-writable, sgid so new files inherit group
chown claude-agent:${ssh_user} /workspace
chmod 2775 /workspace
mkdir -p /workspace/${ssh_user} /workspace/claude-agent /workspace/agent-jobs /workspace/shared
chown ${ssh_user}:${ssh_user}           /workspace/${ssh_user}
chown claude-agent:claude-agent         /workspace/claude-agent
chown claude-agent:claude-agent         /workspace/agent-jobs
chown ${ssh_user}:${ssh_user}           /workspace/shared

# tmux auto-attach on login (only for interactive SSH/ttyd, not cron)
cat > /etc/profile.d/00-tmux-attach.sh <<'EOF'
# Auto-attach interactive shells to the shared 'main' tmux session.
if command -v tmux >/dev/null 2>&1 && [ -n "$SSH_TTY" ] && [ -z "$TMUX" ] && [ "$TERM" != "dumb" ]; then
  tmux new-session -A -s main
fi
EOF
chmod +x /etc/profile.d/00-tmux-attach.sh

# Minimal tmux.conf for both users
cat > /etc/skel/.tmux.conf <<'EOF'
set -g mouse on
set -g history-limit 50000
bind | split-window -h
bind - split-window -v
set -g default-terminal "tmux-256color"
EOF
for u in ${ssh_user} claude-agent; do
  cp /etc/skel/.tmux.conf /home/$u/.tmux.conf
  chown $u:$u /home/$u/.tmux.conf
done

echo "==> claude-worker bootstrap finished"
```

- [ ] **Step 2: Add the bootstrap `null_resource` to `platform/main.tf`** after the `module "claude_worker"` block

```hcl
# =============================================================================
# Claude worker bootstrap (install OS packages, users, software via SSH)
# =============================================================================

resource "null_resource" "claude_worker_bootstrap" {
  count      = var.claude_worker_enabled ? 1 : 0
  depends_on = [module.claude_worker]

  triggers = {
    vm_id          = module.claude_worker[0].vmid
    script_sha     = sha256(templatefile("${path.module}/files/cloud-init/claude-worker-bootstrap.sh.tftpl", {
      ssh_user = var.claude_worker_ssh_user
    }))
  }

  connection {
    type        = "ssh"
    host        = module.claude_worker[0].vm_ip
    user        = var.claude_worker_ssh_user
    private_key = file(pathexpand(var.claude_worker_ssh_private_key_path))
    timeout     = "10m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/files/cloud-init/claude-worker-bootstrap.sh.tftpl", {
      ssh_user = var.claude_worker_ssh_user
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
```

- [ ] **Step 3: Apply + verify**

```bash
cd platform
terraform fmt -recursive
tofu apply       # type yes
```

Verify on the VM:
```bash
ssh c4@192.168.0.190 'id claude-agent && df -h /workspace && stat -c "%U:%G %a" /workspace && ls /etc/profile.d/00-tmux-attach.sh'
```

Expected: `claude-agent` exists, `/workspace` is 48G ext4 mounted, owner `claude-agent:c4` mode `2775`, profile.d file present.

Then disconnect, reconnect, and verify tmux auto-attaches:
```bash
ssh c4@192.168.0.190    # should land you inside tmux session 'main'
```

- [ ] **Step 4: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl platform/main.tf
git commit -m "claude-worker: bootstrap section 1 — base + tmux + /workspace

Idempotent bash script driven via SSH from the operator. Installs
build-essential + shell QoL, creates claude-agent system user, mounts
/dev/sdb as /workspace (ext4 over the ZFS-backed disk), and wires
tmux auto-attach into /etc/profile.d so SSH/ttyd land in a shared
session 'main' by default."
```

---

### Task 7: Bootstrap section 2 — Docker Engine + Compose v2

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 2)

- [ ] **Step 1: Append section 2 to the bootstrap script**, before the final `echo "==> claude-worker bootstrap finished"` line:

```bash
# -----------------------------------------------------------------------------
# Section 2: Docker Engine + Compose v2 (from Docker's apt repo, not Debian's)
# -----------------------------------------------------------------------------
echo "==> [2/?] Docker Engine + Compose v2"

if ! command -v docker >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
     https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
fi

# Both users in docker group (no need for sudo to run docker)
usermod -aG docker ${ssh_user} || true
usermod -aG docker claude-agent || true

systemctl enable --now docker
```

- [ ] **Step 2: Apply + verify**

```bash
cd platform && tofu apply
ssh c4@192.168.0.190 'docker --version && docker compose version && docker run --rm hello-world'
```

Expected: Docker version printed, `docker compose version v2.x`, `hello-world` container runs and prints its greeting.

- [ ] **Step 3: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl
git commit -m "claude-worker: bootstrap section 2 — Docker + Compose v2

From Docker's upstream apt repo (Debian's docker.io is stale and
ships only legacy docker-compose). Both c4 and claude-agent in
'docker' group so they don't need sudo."
```

---

### Task 8: Bootstrap section 3 — Node.js 20 + Claude Code CLI for both users

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 3)

- [ ] **Step 1: Append section 3** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 3: Node.js 20 LTS + Claude Code CLI (per-user, no sudo npm)
# -----------------------------------------------------------------------------
echo "==> [3/?] Node.js + Claude Code"

if ! command -v node >/dev/null 2>&1 || [ "$(node --version | cut -d. -f1)" != "v20" ]; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
  apt-get install -y -qq nodejs
fi

# Per-user global npm prefix so 'npm install -g' works without sudo
install_claude_code_for() {
  local user=$1
  local home
  home=$(getent passwd "$user" | cut -d: -f6)
  sudo -u "$user" mkdir -p "$home/.npm-global"
  sudo -u "$user" npm config set prefix "$home/.npm-global"
  if ! sudo -u "$user" "$home/.npm-global/bin/claude" --version >/dev/null 2>&1; then
    sudo -u "$user" npm install -g @anthropic-ai/claude-code
  fi
  # PATH update in user's ~/.bashrc (idempotent grep guard)
  if ! grep -qF '.npm-global/bin' "$home/.bashrc" 2>/dev/null; then
    echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> "$home/.bashrc"
  fi
}

install_claude_code_for ${ssh_user}
install_claude_code_for claude-agent

# Shared OAuth: c4's interactive shells read claude-agent's credentials
cat > /etc/profile.d/01-claude-shared-oauth.sh <<'EOF'
# Both users share one OAuth token, owned by claude-agent.
# For c4's interactive shells: point CLAUDE_HOME at claude-agent's dir.
# claude-agent's own shells use their default ~/.claude (no override needed).
if [ "$USER" = "${ssh_user}" ]; then
  export CLAUDE_HOME=/home/claude-agent/.claude
fi
EOF
# Substitute ${ssh_user} into the file (the heredoc is single-quoted so $USER stays)
sed -i "s/\$\{ssh_user\}/${ssh_user}/" /etc/profile.d/01-claude-shared-oauth.sh
chmod +x /etc/profile.d/01-claude-shared-oauth.sh

# Grant c4 read access to claude-agent's .claude dir (defaults so future files
# inside .claude inherit). claude-agent stays the owner; c4 is the secondary
# group on the .claude tree.
sudo -u claude-agent mkdir -p /home/claude-agent/.claude
chgrp -R ${ssh_user} /home/claude-agent/.claude
chmod 750 /home/claude-agent /home/claude-agent/.claude
setfacl -R -m g:${ssh_user}:rx /home/claude-agent/.claude
setfacl -R -d -m g:${ssh_user}:rx /home/claude-agent/.claude
```

- [ ] **Step 2: Apply + verify**

```bash
cd platform && tofu apply
ssh c4@192.168.0.190 'node --version && claude --version'
ssh c4@192.168.0.190 'sudo -u claude-agent /home/claude-agent/.npm-global/bin/claude --version'
```

Expected: node v20.x, both `claude --version` invocations succeed.

- [ ] **Step 3: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl
git commit -m "claude-worker: bootstrap section 3 — Node.js 20 + Claude Code

Per-user npm-global prefix avoids sudo npm. Both users get the CLI.
Shared OAuth wired via CLAUDE_HOME env in /etc/profile.d/, with ACLs
giving c4 group:read access to claude-agent's ~/.claude tree."
```

---

### Task 9: Bootstrap section 4 — Python 3.11 + pipx, Go, Rust

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 4)

- [ ] **Step 1: Append section 4** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 4: language toolchains (Python, Go, Rust)
# -----------------------------------------------------------------------------
echo "==> [4/?] Python + Go + Rust"

apt-get install -y -qq python3 python3-venv python3-pip pipx golang-go

# Rust to /opt/rust (shared, both users PATH'd to /opt/rust/cargo/bin)
if [ ! -x /opt/rust/cargo/bin/cargo ]; then
  mkdir -p /opt/rust
  export RUSTUP_HOME=/opt/rust/rustup
  export CARGO_HOME=/opt/rust/cargo
  curl -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --default-toolchain stable
  chmod -R go+rX /opt/rust
fi

cat > /etc/profile.d/02-rust-path.sh <<'EOF'
export RUSTUP_HOME=/opt/rust/rustup
export CARGO_HOME=/opt/rust/cargo
export PATH="$CARGO_HOME/bin:$PATH"
EOF
chmod +x /etc/profile.d/02-rust-path.sh
```

- [ ] **Step 2: Apply + verify**

```bash
cd platform && tofu apply
ssh c4@192.168.0.190 'python3 --version && pipx --version && go version && /opt/rust/cargo/bin/cargo --version'
```

Expected: Python 3.11, pipx prints version, Go 1.19+ (Debian 12 ships 1.19; spec said 1.22 — acceptable to leave at Debian's version since we don't actually require 1.22 anywhere; flag in commit message), Cargo 1.x stable.

- [ ] **Step 3: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl
git commit -m "claude-worker: bootstrap section 4 — Python + Go + Rust

Distro Python 3.11 + pipx, distro Go (1.19; if 1.22+ needed later,
swap to golang.org tarball install). Rust via rustup to shared /opt/rust
so both users share one toolchain; PATH wired via /etc/profile.d/."
```

---

### Task 10: Bootstrap section 5 — kubectl, helm, k9s

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 5)

- [ ] **Step 1: Append section 5** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 5: k8s tooling (kubectl, helm, k9s)
# -----------------------------------------------------------------------------
echo "==> [5/?] kubectl + helm + k9s"

K8S_MINOR="1.30"
if ! command -v kubectl >/dev/null 2>&1; then
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/Release.key" \
    | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v$${K8S_MINOR}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq
  apt-get install -y -qq kubectl
fi

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://baltocdn.com/helm/signing.asc | gpg --dearmor -o /etc/apt/keyrings/helm.gpg
  echo "deb [signed-by=/etc/apt/keyrings/helm.gpg] https://baltocdn.com/helm/stable/debian/ all main" \
    > /etc/apt/sources.list.d/helm-stable-debian.list
  apt-get update -qq
  apt-get install -y -qq helm
fi

# k9s — Debian doesn't have it; install from upstream release tarball
K9S_VER="v0.32.5"
if [ ! -x /usr/local/bin/k9s ] || ! /usr/local/bin/k9s version 2>/dev/null | grep -q "$K9S_VER"; then
  curl -fsSL "https://github.com/derailed/k9s/releases/download/$K9S_VER/k9s_Linux_amd64.tar.gz" \
    | tar -xz -C /tmp k9s
  install -m 0755 /tmp/k9s /usr/local/bin/k9s
  rm -f /tmp/k9s
fi

# /etc/skel/.kube placeholder so future users get the directory; the actual
# kubeconfig is dropped by Terraform in a follow-up null_resource.
install -d -m 0755 /etc/skel/.kube
for u in ${ssh_user} claude-agent; do
  install -d -m 0700 -o "$u" -g "$u" /home/$u/.kube
done
```

- [ ] **Step 2: Apply + verify**

```bash
cd platform && tofu apply
ssh c4@192.168.0.190 'kubectl version --client && helm version --short && k9s version --short'
```

Expected: all three print versions; kubectl is 1.30.x.

- [ ] **Step 3: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl
git commit -m "claude-worker: bootstrap section 5 — kubectl + helm + k9s

kubectl from pkgs.k8s.io (matched to k3s 1.30 line), helm from
baltocdn, k9s from upstream tarball (no Debian package)."
```

---

### Task 11: Bootstrap section 6 — ttyd + Caddy (LAN https)

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 6)

- [ ] **Step 1: Append section 6** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 6: web terminal (ttyd) + Caddy reverse proxy for LAN HTTPS
# -----------------------------------------------------------------------------
echo "==> [6/?] ttyd + Caddy"

TTYD_VER="1.7.7"
if [ ! -x /usr/local/bin/ttyd ] || ! /usr/local/bin/ttyd --version 2>&1 | grep -q "$TTYD_VER"; then
  curl -fsSL "https://github.com/tsl0922/ttyd/releases/download/$TTYD_VER/ttyd.x86_64" \
    -o /usr/local/bin/ttyd
  chmod +x /usr/local/bin/ttyd
fi

# systemd unit — runs as claude-agent, spawns tmux attach into the shared session.
cat > /etc/systemd/system/ttyd.service <<'EOF'
[Unit]
Description=ttyd web terminal (drops to claude-agent, attaches shared tmux)
After=network.target

[Service]
Type=simple
User=claude-agent
Group=claude-agent
ExecStart=/usr/local/bin/ttyd -i 127.0.0.1 -p 7681 -t titleFixed='claude-worker' tmux new-session -A -s main
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Caddy via apt (cloudsmith repo)
if ! command -v caddy >/dev/null 2>&1; then
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor -o /etc/apt/keyrings/caddy-stable.gpg
  curl -fsSL https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt \
    | sed 's|/usr/share/keyrings|/etc/apt/keyrings|; s|caddy-stable-archive-keyring|caddy-stable|' \
    > /etc/apt/sources.list.d/caddy-stable.list
  apt-get update -qq
  apt-get install -y -qq caddy
fi

cat > /etc/caddy/Caddyfile <<'EOF'
# Caddy in front of ttyd. tls internal = self-signed via Caddy's local CA;
# browser will show a "not secure" warning on first visit (trust-on-first-use).
# Public access goes through CF Tunnel + CF Access at claude.chifor.dev with a
# properly-trusted cert from Cloudflare's edge.
:443 {
  tls internal
  reverse_proxy 127.0.0.1:7681
}
:80 {
  redir https://{host}{uri} permanent
}
EOF

systemctl daemon-reload
systemctl enable --now ttyd.service caddy.service
systemctl reload caddy 2>/dev/null || systemctl restart caddy
```

- [ ] **Step 2: Apply + verify**

```bash
cd platform && tofu apply
ssh c4@192.168.0.190 'systemctl is-active ttyd caddy && curl -sk -o /dev/null -w "%{http_code}\n" https://localhost/'
```

Expected: both `active`, HTTPS returns `200`.

Also from another machine on the LAN, visit `https://192.168.0.190` in a browser — accept the cert warning, see a terminal as `claude-agent`.

- [ ] **Step 3: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl
git commit -m "claude-worker: bootstrap section 6 — ttyd + Caddy (LAN HTTPS)

ttyd binds 127.0.0.1:7681 and execs tmux attach against the shared
'main' session as claude-agent. Caddy on :443 reverse-proxies with
'tls internal' (self-signed). Public access to ttyd later goes
through CF Tunnel direct to localhost:7681; this Caddy path is
for LAN access only."
```

---

### Task 12: Bootstrap section 7 — cloudflared (conditional on tunnel token)

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 7, plus add token param)
- Modify: `platform/main.tf` (pass token into the bootstrap template)

- [ ] **Step 1: Append section 7** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 7: cloudflared (only if tunnel token provided)
# -----------------------------------------------------------------------------
echo "==> [7/?] cloudflared"

CF_TUNNEL_TOKEN='${cf_tunnel_token}'

if [ -z "$CF_TUNNEL_TOKEN" ]; then
  echo "    (no CF tunnel token configured — skipping cloudflared install)"
else
  if ! command -v cloudflared >/dev/null 2>&1; then
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
      -o /etc/apt/keyrings/cloudflare-main.gpg
    echo "deb [signed-by=/etc/apt/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared $(. /etc/os-release && echo "$VERSION_CODENAME") main" \
      > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq
    apt-get install -y -qq cloudflared
  fi
  # cloudflared service install with the token
  cloudflared service install "$CF_TUNNEL_TOKEN" 2>&1 | grep -v -i 'already installed' || true
  systemctl enable --now cloudflared
fi
```

- [ ] **Step 2: Update `null_resource.claude_worker_bootstrap`** in `platform/main.tf` to pass the token

Replace the existing `templatefile(...)` call inside `triggers.script_sha` AND inside the `provisioner "file"` content with:

```hcl
content = templatefile("${path.module}/files/cloud-init/claude-worker-bootstrap.sh.tftpl", {
  ssh_user        = var.claude_worker_ssh_user
  cf_tunnel_token = var.claude_worker_cf_tunnel_token
})
```

And update `triggers.script_sha` to pass the same two vars:

```hcl
script_sha = sha256(templatefile("${path.module}/files/cloud-init/claude-worker-bootstrap.sh.tftpl", {
  ssh_user        = var.claude_worker_ssh_user
  cf_tunnel_token = var.claude_worker_cf_tunnel_token
}))
```

- [ ] **Step 3: Apply + verify** (with no token set yet — should skip install)

```bash
cd platform && terraform fmt -recursive && tofu apply
ssh c4@192.168.0.190 'systemctl is-active cloudflared 2>&1 || echo "(not installed yet — expected)"'
```

Expected: prints "(not installed yet — expected)" or "inactive".

- [ ] **Step 4: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl platform/main.tf
git commit -m "claude-worker: bootstrap section 7 — cloudflared (optional)

Skipped when claude_worker_cf_tunnel_token is empty. When set,
installs cloudflared from Cloudflare's apt repo and runs
'cloudflared service install \$TOKEN' which sets up the systemd
service and connects to the named tunnel."
```

---

### Task 13: Bootstrap section 8 — ufw firewall

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 8)

- [ ] **Step 1: Append section 8** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 8: ufw firewall (LAN-only inbound; cloudflared connects outbound)
# -----------------------------------------------------------------------------
echo "==> [8/?] ufw"

# Reset to a known state on first run, then declare desired rules
if [ "$(ufw status | head -1)" != "Status: active" ]; then
  ufw --force reset >/dev/null
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow from 192.168.0.0/24 to any port 22 proto tcp comment 'SSH from LAN'
  ufw allow from 192.168.0.0/24 to any port 443 proto tcp comment 'Caddy HTTPS from LAN'
  ufw allow from 192.168.0.0/24 to any port 80 proto tcp comment 'Caddy HTTP redirect from LAN'
  ufw --force enable
fi
```

- [ ] **Step 2: Apply + verify**

```bash
cd platform && tofu apply
ssh c4@192.168.0.190 'sudo ufw status verbose'
```

Expected: Status: active, rules for 22/443/80 from `192.168.0.0/24`.

- [ ] **Step 3: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl
git commit -m "claude-worker: bootstrap section 8 — ufw inbound deny-by-default

LAN-only inbound on 22/80/443. cloudflared connects outbound to CF
edge so no public port opens on the VM. Idempotent guard against
re-reset on re-runs (status check)."
```

---

### Task 14: Bootstrap section 9 — claude-grant-write helper script

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 9)

- [ ] **Step 1: Append section 9** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 9: claude-grant-write helper (opt-in RW kubeconfig)
# -----------------------------------------------------------------------------
echo "==> [9/?] claude-grant-write"

cat > /usr/local/bin/claude-grant-write <<'EOF'
#!/bin/bash
# Opt-in escalation: switch the current shell's KUBECONFIG to the RW config.
# The RW config is root-readable only — accessing it requires sudo, which
# means the operator has to type their password. Even an agent prompt that
# 'bash -c's its way out cannot reach edit-level RBAC without that password.

set -euo pipefail
RW=/etc/claude-agent/kube-rw-config

if [ ! -r "$RW" ]; then
  if ! sudo test -r "$RW"; then
    echo "claude-grant-write: $RW does not exist yet. Has Terraform fetched the RW kubeconfig?" >&2
    exit 1
  fi
  # Stage a per-user readable copy under /run (tmpfs, ephemeral)
  STAGED="/run/user/$(id -u)/kube-rw-config"
  install -d -m 0700 "$(dirname "$STAGED")"
  sudo install -m 0400 -o "$(id -u)" -g "$(id -g)" "$RW" "$STAGED"
else
  STAGED="$RW"
fi

echo "claude-grant-write: KUBECONFIG=$STAGED exported for this shell."
echo "  - kubectl now has edit-level RBAC against the cluster."
echo "  - 'exit' or open a new shell to drop back to read-only."
exec env KUBECONFIG="$STAGED" "$SHELL"
EOF
chmod 0755 /usr/local/bin/claude-grant-write
```

- [ ] **Step 2: Apply + verify** (the script is present but the RW kubeconfig isn't yet — that's Task 17)

```bash
cd platform && tofu apply
ssh c4@192.168.0.190 'ls -la /usr/local/bin/claude-grant-write && claude-grant-write 2>&1 | head -3 || true'
```

Expected: script exists, executable. Running it complains that `/etc/claude-agent/kube-rw-config` doesn't exist yet (expected — Task 17 creates it).

- [ ] **Step 3: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl
git commit -m "claude-worker: bootstrap section 9 — claude-grant-write helper

Stages a per-shell readable copy of the RW kubeconfig under /run/user
(tmpfs), requires sudo to access the source file. Exec's the current
shell with KUBECONFIG pointed at the staged copy. Exit drops back to
the default RO config."
```

---

## Phase 3 — K8s integration: ServiceAccounts + kubeconfigs

Two SAs in the cluster (`claude-agent-ro` view, `claude-agent-rw` edit), each with a long-lived Secret token, rendered into kubeconfig files locally, then scped to the worker.

### Task 15: SA + RBAC + token Secret manifests

**Files:**
- Create: `platform/files/k8s/claude-agent-rbac.yaml.tftpl`
- Modify: `platform/main.tf` (add `kubectl_manifest` resources at the bottom)

- [ ] **Step 1: Create `platform/files/k8s/claude-agent-rbac.yaml.tftpl`**

```yaml
# Two ServiceAccounts for the Claude worker.
# Each gets a long-lived bearer token Secret (kubernetes.io/service-account-token).
# Token-Request API is preferred but expires; we want a stable token the worker
# can store. The long-lived Secret approach is officially deprecated but still
# supported in k3s 1.30 — re-evaluate if k8s 1.34+ deprecates it for real.
---
apiVersion: v1
kind: Namespace
metadata:
  name: claude-agent
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: claude-agent-ro
  namespace: claude-agent
---
apiVersion: v1
kind: Secret
metadata:
  name: claude-agent-ro-token
  namespace: claude-agent
  annotations:
    kubernetes.io/service-account.name: claude-agent-ro
type: kubernetes.io/service-account-token
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: claude-agent-ro-view
subjects:
  - kind: ServiceAccount
    name: claude-agent-ro
    namespace: claude-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: view
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: claude-agent-rw
  namespace: claude-agent
---
apiVersion: v1
kind: Secret
metadata:
  name: claude-agent-rw-token
  namespace: claude-agent
  annotations:
    kubernetes.io/service-account.name: claude-agent-rw
type: kubernetes.io/service-account-token
---
# 'edit' is a stock ClusterRole; lets the SA mutate namespaced resources
# (deployments, services, configmaps, etc.) but NOT cluster-scoped resources
# (nodes, CRDs, RBAC). Roughly: power-user without admin.
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: claude-agent-rw-edit
subjects:
  - kind: ServiceAccount
    name: claude-agent-rw
    namespace: claude-agent
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: edit
```

- [ ] **Step 2: Append `kubectl_manifest` resources to `platform/main.tf`**

```hcl
# =============================================================================
# Claude worker — k8s ServiceAccounts (RO default + RW opt-in)
# =============================================================================

resource "kubectl_manifest" "claude_agent_rbac" {
  count      = var.claude_worker_enabled ? 1 : 0
  depends_on = [data.local_sensitive_file.kubeconfig]

  yaml_body = file("${path.module}/files/k8s/claude-agent-rbac.yaml.tftpl")
}
```

Note: this needs the kubectl provider, which the repo already has configured. `kubectl_manifest` is single-doc; for multi-doc YAML, the cleaner pattern is `data "kubectl_file_documents"` + `for_each`. Update to use that:

```hcl
data "kubectl_file_documents" "claude_agent_rbac" {
  count   = var.claude_worker_enabled ? 1 : 0
  content = file("${path.module}/files/k8s/claude-agent-rbac.yaml.tftpl")
}

resource "kubectl_manifest" "claude_agent_rbac" {
  for_each = var.claude_worker_enabled ? data.kubectl_file_documents.claude_agent_rbac[0].manifests : {}

  yaml_body  = each.value
  depends_on = [data.local_sensitive_file.kubeconfig]
}
```

- [ ] **Step 3: Apply + verify**

```bash
cd platform && terraform fmt -recursive && tofu apply
KUBECONFIG=./kubeconfig kubectl get sa,secrets,clusterrolebinding -n claude-agent
KUBECONFIG=./kubeconfig kubectl auth can-i list pods --as=system:serviceaccount:claude-agent:claude-agent-ro
KUBECONFIG=./kubeconfig kubectl auth can-i delete pods --as=system:serviceaccount:claude-agent:claude-agent-ro -n default
KUBECONFIG=./kubeconfig kubectl auth can-i delete pods --as=system:serviceaccount:claude-agent:claude-agent-rw -n default
```

Expected:
- 2 SAs, 2 Secrets, 2 ClusterRoleBindings
- `claude-agent-ro` can list pods → yes, can delete pods → no
- `claude-agent-rw` can delete pods → yes

- [ ] **Step 4: Commit**

```bash
git add platform/files/k8s/claude-agent-rbac.yaml.tftpl platform/main.tf
git commit -m "claude-worker: k8s ServiceAccounts + RBAC

claude-agent-ro bound to ClusterRole 'view' (read-only across cluster),
claude-agent-rw bound to 'edit' (namespaced mutate, no cluster-scoped
changes). Long-lived bearer tokens via service-account-token Secrets
so the worker can store and reuse them; reconsider when k3s drops
support for these (still supported in 1.30)."
```

---

### Task 16: Render and ship the two kubeconfigs onto the worker

**Files:**
- Create: `platform/files/k8s/sa-kubeconfig.yaml.tftpl`
- Modify: `platform/main.tf` (add data source for tokens + null_resource that scps the rendered configs)

- [ ] **Step 1: Create `platform/files/k8s/sa-kubeconfig.yaml.tftpl`**

```yaml
apiVersion: v1
kind: Config
clusters:
  - name: homelab
    cluster:
      server: ${cluster_server}
      certificate-authority-data: ${cluster_ca_b64}
contexts:
  - name: ${sa_name}@homelab
    context:
      cluster: homelab
      namespace: default
      user: ${sa_name}
current-context: ${sa_name}@homelab
users:
  - name: ${sa_name}
    user:
      token: ${token}
```

- [ ] **Step 2: Append data + null_resource to `platform/main.tf`**

```hcl
# Read the SA token + cluster CA from the cluster after RBAC is created.
data "kubernetes_secret" "claude_agent_ro_token" {
  count = var.claude_worker_enabled ? 1 : 0

  metadata {
    name      = "claude-agent-ro-token"
    namespace = "claude-agent"
  }

  depends_on = [kubectl_manifest.claude_agent_rbac]
}

data "kubernetes_secret" "claude_agent_rw_token" {
  count = var.claude_worker_enabled ? 1 : 0

  metadata {
    name      = "claude-agent-rw-token"
    namespace = "claude-agent"
  }

  depends_on = [kubectl_manifest.claude_agent_rbac]
}

locals {
  claude_worker_ro_kubeconfig = var.claude_worker_enabled ? templatefile("${path.module}/files/k8s/sa-kubeconfig.yaml.tftpl", {
    cluster_server = "https://${var.cp_ip}:6443"
    cluster_ca_b64 = base64encode(data.kubernetes_secret.claude_agent_ro_token[0].data["ca.crt"])
    sa_name        = "claude-agent-ro"
    token          = data.kubernetes_secret.claude_agent_ro_token[0].data["token"]
  }) : ""

  claude_worker_rw_kubeconfig = var.claude_worker_enabled ? templatefile("${path.module}/files/k8s/sa-kubeconfig.yaml.tftpl", {
    cluster_server = "https://${var.cp_ip}:6443"
    cluster_ca_b64 = base64encode(data.kubernetes_secret.claude_agent_rw_token[0].data["ca.crt"])
    sa_name        = "claude-agent-rw"
    token          = data.kubernetes_secret.claude_agent_rw_token[0].data["token"]
  }) : ""
}

resource "null_resource" "claude_worker_kubeconfigs" {
  count = var.claude_worker_enabled ? 1 : 0

  depends_on = [
    null_resource.claude_worker_bootstrap,
    data.kubernetes_secret.claude_agent_ro_token,
    data.kubernetes_secret.claude_agent_rw_token,
  ]

  triggers = {
    ro_sha = sha256(local.claude_worker_ro_kubeconfig)
    rw_sha = sha256(local.claude_worker_rw_kubeconfig)
  }

  connection {
    type        = "ssh"
    host        = module.claude_worker[0].vm_ip
    user        = var.claude_worker_ssh_user
    private_key = file(pathexpand(var.claude_worker_ssh_private_key_path))
    timeout     = "5m"
  }

  # Stage both files to /tmp; sudo-move into place with correct perms
  provisioner "file" {
    content     = local.claude_worker_ro_kubeconfig
    destination = "/tmp/sa-ro.kubeconfig"
  }

  provisioner "file" {
    content     = local.claude_worker_rw_kubeconfig
    destination = "/tmp/sa-rw.kubeconfig"
  }

  provisioner "remote-exec" {
    inline = [
      # RO kubeconfig → both users' ~/.kube/config, mode 600 each
      "sudo install -m 0600 -o ${var.claude_worker_ssh_user}  -g ${var.claude_worker_ssh_user}  /tmp/sa-ro.kubeconfig /home/${var.claude_worker_ssh_user}/.kube/config",
      "sudo install -m 0600 -o claude-agent -g claude-agent /tmp/sa-ro.kubeconfig /home/claude-agent/.kube/config",
      # RW kubeconfig → root-readable only
      "sudo install -d -m 0700 -o root -g root /etc/claude-agent",
      "sudo install -m 0400 -o root -g root /tmp/sa-rw.kubeconfig /etc/claude-agent/kube-rw-config",
      "rm -f /tmp/sa-ro.kubeconfig /tmp/sa-rw.kubeconfig",
    ]
  }
}
```

- [ ] **Step 3: Apply + verify**

```bash
cd platform && terraform fmt -recursive && tofu apply
ssh c4@192.168.0.190 'kubectl get nodes && kubectl auth can-i delete pods -n default'
```

Expected: `kubectl get nodes` lists all cluster nodes; `can-i delete pods` returns `no`.

Then verify RW escalation:
```bash
ssh c4@192.168.0.190 'echo "y" | claude-grant-write <<<"kubectl auth can-i delete pods -n default && exit"'
```

(Approximation; actual interactive flow requires `sudo` prompt for the staged copy. Easier verification: just SSH in and run `claude-grant-write` manually.)

- [ ] **Step 4: Commit**

```bash
git add platform/files/k8s/sa-kubeconfig.yaml.tftpl platform/main.tf
git commit -m "claude-worker: render + ship SA kubeconfigs onto the worker

Reads the two token Secrets from the cluster, renders kubeconfig YAML
locally with cluster CA + server URL, scps into place:
  - RO config -> ~c4/.kube/config + ~claude-agent/.kube/config (mode 600)
  - RW config -> /etc/claude-agent/kube-rw-config (root-only, opt-in)"
```

---

## Phase 4 — Headless framework

### Task 17: Systemd timer template + two example jobs

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 10)

- [ ] **Step 1: Append section 10** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 10: systemd timer template + example agent-job skeletons
# -----------------------------------------------------------------------------
echo "==> [10/?] claude-job systemd template + examples"

# Parameterised service template; one instance per job name
cat > /etc/systemd/system/claude-job@.service <<'EOF'
[Unit]
Description=Claude Code headless job (%i)
After=network-online.target

[Service]
Type=oneshot
User=claude-agent
Group=claude-agent
WorkingDirectory=/workspace/agent-jobs/%i
EnvironmentFile=-/workspace/agent-jobs/%i/job.env
# Pin OAuth credential path explicitly (cron doesn't load /etc/profile.d)
Environment=CLAUDE_HOME=/home/claude-agent/.claude
Environment=PATH=/home/claude-agent/.npm-global/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=/bin/bash -c 'mkdir -p output && claude -p "$$(cat prompt.md)" --output-format json --allowed-tools "$$(cat allowed-tools.txt | tr "\n" "," | sed s/,$$//)" >> output/$$(date -u +%%Y%%m%%dT%%H%%M%%SZ).jsonl 2>&1'
TimeoutStartSec=30min
EOF

# Example job 1: longhorn-health (every 6 hours)
install -d -o claude-agent -g claude-agent /workspace/agent-jobs/longhorn-health/output
cat > /workspace/agent-jobs/longhorn-health/prompt.md <<'EOF'
You are an SRE assistant for a home-lab k3s cluster. Read the current
Longhorn state via kubectl (your kubeconfig is read-only). Produce a
concise health summary as Markdown: total volumes, attached vs detached,
any volumes with degraded replicas, any nodes with disk pressure, any
recent BackupTarget errors. Write the summary to
/workspace/agent-jobs/longhorn-health/output/summary-$(date +%F).md.
EOF
cat > /workspace/agent-jobs/longhorn-health/allowed-tools.txt <<'EOF'
Bash(kubectl get *)
Bash(kubectl describe *)
Bash(kubectl logs *)
Bash(date *)
Write
EOF
cat > /workspace/agent-jobs/longhorn-health/job.env <<'EOF'
EOF
cat > /etc/systemd/system/claude-job@longhorn-health.timer <<'EOF'
[Unit]
Description=Claude Code longhorn-health every 6h

[Timer]
OnBootSec=15min
OnUnitActiveSec=6h
Unit=claude-job@longhorn-health.service

[Install]
WantedBy=timers.target
EOF
chown -R claude-agent:claude-agent /workspace/agent-jobs/longhorn-health

# Example job 2: nightly-repo-audit (02:00 daily). Disabled until you fill in
# the repo list in prompt.md / job.env.
install -d -o claude-agent -g claude-agent /workspace/agent-jobs/nightly-repo-audit/output
cat > /workspace/agent-jobs/nightly-repo-audit/prompt.md <<'EOF'
You are a code-review assistant. Read $REPO_LIST (one git URL per line, from
job.env). For each repo, clone if missing under /workspace/agent-jobs/nightly-repo-audit/repos/,
then 'git pull'. Run a focused review on commits since the last summary
(stored at output/last-reviewed.txt): look for security issues, broken
tests, TODOs without owners. Write findings to
output/audit-$(date +%F).md.
EOF
cat > /workspace/agent-jobs/nightly-repo-audit/allowed-tools.txt <<'EOF'
Bash(git *)
Bash(date *)
Bash(ls *)
Read
Write
Grep
EOF
cat > /workspace/agent-jobs/nightly-repo-audit/job.env <<'EOF'
# Populate REPO_LIST with newline-separated git URLs to enable this job.
REPO_LIST="
"
EOF
cat > /etc/systemd/system/claude-job@nightly-repo-audit.timer <<'EOF'
[Unit]
Description=Claude Code nightly repo audit at 02:00

[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
Unit=claude-job@nightly-repo-audit.service

[Install]
WantedBy=timers.target
EOF
chown -R claude-agent:claude-agent /workspace/agent-jobs/nightly-repo-audit

systemctl daemon-reload
# Enable the timers but DON'T start nightly-repo-audit until the operator has
# populated REPO_LIST. longhorn-health is safe to start (it just reads).
systemctl enable --now claude-job@longhorn-health.timer
systemctl enable claude-job@nightly-repo-audit.timer
# Stop the nightly-repo-audit timer until configured
systemctl stop  claude-job@nightly-repo-audit.timer || true
```

- [ ] **Step 2: Apply + verify**

```bash
cd platform && tofu apply
ssh c4@192.168.0.190 'systemctl list-timers claude-job@*.timer'
```

Expected: `claude-job@longhorn-health.timer` listed as active with NEXT firing time within 15 min.

Wait ~15 min then check it ran:
```bash
ssh c4@192.168.0.190 'sudo journalctl -u "claude-job@longhorn-health.service" --no-pager | tail -20'
ssh c4@192.168.0.190 'ls /workspace/agent-jobs/longhorn-health/output/'
```

Expected: journalctl shows the service ran; `output/` has a fresh `.jsonl` file.

(Note: this test only works AFTER OAuth bootstrap is done in Task 20. Until then the timer fires but `claude -p` returns "not authenticated" — expected.)

- [ ] **Step 3: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl
git commit -m "claude-worker: bootstrap section 10 — systemd timer template + examples

Parameterised claude-job@.service runs as claude-agent, sources
job-specific env, invokes 'claude -p' with whitelisted tools, captures
output as timestamped jsonl. Two examples shipped:
  - longhorn-health: 6h interval, enabled (read-only, safe)
  - nightly-repo-audit: 02:00 daily, installed but stopped until
    operator populates REPO_LIST."
```

---

## Phase 5 — Snapshots + backup

### Task 18: sanoid on the Proxmox host

**Files:**
- Create: `platform/files/cloud-init/proxmox-sanoid-setup.sh.tftpl`
- Modify: `platform/main.tf` (add a `null_resource` that runs on the Proxmox host)

- [ ] **Step 1: Create `platform/files/cloud-init/proxmox-sanoid-setup.sh.tftpl`**

```bash
#!/bin/bash
# Configure sanoid on the Proxmox host to snapshot the claude-worker's
# two zvols (root + data). Idempotent.
set -euo pipefail

VM_ID='${vm_id}'
POOL='${pool}'

# Install sanoid if missing
if ! command -v sanoid >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq sanoid
fi

mkdir -p /etc/sanoid
cat > /etc/sanoid/sanoid-claude-worker.conf <<EOF
[$${POOL}/vm-$${VM_ID}-disk-0]
use_template = production
[$${POOL}/vm-$${VM_ID}-disk-1]
use_template = workspace

[template_production]
frequently = 0
hourly = 0
daily = 3
monthly = 0
yearly = 0

[template_workspace]
frequently = 0
hourly = 0
daily = 7
weekly = 4
monthly = 0
yearly = 0
autosnap = yes
autoprune = yes
EOF

# sanoid's main config includes everything in /etc/sanoid/*.conf? No — sanoid
# reads only /etc/sanoid/sanoid.conf. We need to source our snippet from there.
if ! grep -qF 'sanoid-claude-worker.conf' /etc/sanoid/sanoid.conf 2>/dev/null; then
  # First-time setup: copy the default + append our datasets
  if [ ! -f /etc/sanoid/sanoid.conf ]; then
    cp /usr/share/sanoid/sanoid.defaults.conf /etc/sanoid/sanoid.conf
  fi
  cat /etc/sanoid/sanoid-claude-worker.conf >> /etc/sanoid/sanoid.conf
fi

# Ensure the systemd timers are running
systemctl enable --now sanoid.timer
echo "sanoid configured for VM $VM_ID disks on pool $POOL"
```

- [ ] **Step 2: Append `null_resource` to `platform/main.tf`**

```hcl
resource "null_resource" "claude_worker_snapshots" {
  count      = var.claude_worker_enabled ? 1 : 0
  depends_on = [null_resource.claude_worker_bootstrap]

  triggers = {
    vm_id = module.claude_worker[0].vmid
  }

  connection {
    type        = "ssh"
    host        = var.proxmox_host_address
    user        = var.proxmox_host_ssh_user
    private_key = file(pathexpand(var.proxmox_host_ssh_private_key_path))
    timeout     = "5m"
  }

  provisioner "file" {
    content = templatefile("${path.module}/files/cloud-init/proxmox-sanoid-setup.sh.tftpl", {
      vm_id = module.claude_worker[0].vmid
      pool  = var.claude_worker_storage_pool
    })
    destination = "/tmp/proxmox-sanoid-setup.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/proxmox-sanoid-setup.sh",
      "/tmp/proxmox-sanoid-setup.sh",
      "rm -f /tmp/proxmox-sanoid-setup.sh",
    ]
  }
}
```

- [ ] **Step 3: Apply + verify**

```bash
cd platform && terraform fmt -recursive && tofu apply
ssh root@192.168.0.185 'systemctl is-active sanoid.timer && cat /etc/sanoid/sanoid-claude-worker.conf'
```

Expected: timer active; config file present with the two zvols.

Wait 24h, verify snapshots exist:
```bash
ssh root@192.168.0.185 'zfs list -t snapshot | grep vm-<VMID>'
```

- [ ] **Step 4: Commit**

```bash
git add platform/files/cloud-init/proxmox-sanoid-setup.sh.tftpl platform/main.tf
git commit -m "claude-worker: ZFS snapshots via sanoid on the Proxmox host

Installs sanoid, drops a sanoid-claude-worker.conf snippet appended to
the main sanoid.conf, schedules:
  - root disk: 3 daily snapshots (low-churn, easy rollback)
  - /workspace disk: 7 daily + 4 weekly
The sanoid.timer runs on the Proxmox host, not the VM."
```

---

### Task 19: restic to MinIO

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 11)
- Modify: `platform/main.tf` (pass restic vars into the template)

- [ ] **Step 1: Append section 11** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 11: restic backup to MinIO (off-host)
# -----------------------------------------------------------------------------
echo "==> [11/?] restic"

RESTIC_REPO='${restic_repo_url}'
RESTIC_PASSWORD='${restic_password}'

if [ -z "$RESTIC_PASSWORD" ]; then
  echo "    (no restic password configured — skipping restic install)"
else
  if ! command -v restic >/dev/null 2>&1; then
    apt-get install -y -qq restic
  fi

  install -d -m 0700 /etc/restic
  echo "$RESTIC_PASSWORD" > /etc/restic/repo.key
  chmod 0600 /etc/restic/repo.key
  cat > /etc/restic/env <<EOF
export RESTIC_REPOSITORY="$RESTIC_REPO"
export RESTIC_PASSWORD_FILE=/etc/restic/repo.key
# AWS_* creds for MinIO (S3-compatible). The NAS LXC's MinIO root user
# is fine for a single-tenant homelab; tighten with a scoped user later.
export AWS_ACCESS_KEY_ID="\$(cat /etc/restic/minio-access)"
export AWS_SECRET_ACCESS_KEY="\$(cat /etc/restic/minio-secret)"
EOF
  chmod 0600 /etc/restic/env

  # Initialize repo if absent (probes via 'restic snapshots' — failure = uninit)
  if ! ( . /etc/restic/env && restic snapshots >/dev/null 2>&1 ); then
    ( . /etc/restic/env && restic init ) || echo "    (restic init failed — likely missing MinIO creds; finish setup in Task 19 step 2)"
  fi

  # Backup unit + timer
  cat > /etc/systemd/system/restic-backup.service <<'EOF'
[Unit]
Description=restic backup to MinIO

[Service]
Type=oneshot
EnvironmentFile=/etc/restic/env
ExecStart=/usr/bin/restic backup --quiet \
  --exclude /workspace/agent-jobs/*/repos \
  --exclude /home/*/.cache \
  --exclude /var/lib/docker \
  /workspace /home /etc/cloudflared /etc/claude-agent
ExecStartPost=/usr/bin/restic forget --quiet --prune \
  --keep-daily 7 --keep-weekly 4 --keep-monthly 6
EOF
  cat > /etc/systemd/system/restic-backup.timer <<'EOF'
[Unit]
Description=Daily restic backup

[Timer]
OnCalendar=*-*-* 04:00:00
Persistent=true
Unit=restic-backup.service

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now restic-backup.timer
fi
```

- [ ] **Step 2: Pass restic vars through the bootstrap templatefile** in `platform/main.tf`. Update both the trigger and the provisioner content:

```hcl
content = templatefile("${path.module}/files/cloud-init/claude-worker-bootstrap.sh.tftpl", {
  ssh_user         = var.claude_worker_ssh_user
  cf_tunnel_token  = var.claude_worker_cf_tunnel_token
  restic_repo_url  = var.claude_worker_restic_repo_url
  restic_password  = var.claude_worker_restic_password
})
```

(And the same in `triggers.script_sha`.)

- [ ] **Step 3: MinIO credentials (one-time operator action)**

After apply, the script tries to `restic init` but will fail without MinIO creds in the env. Drop them in:

```bash
# Get the MinIO root creds from the NAS LXC tofu output (or your records)
ssh c4@192.168.0.190 'sudo bash -c "echo MINIO_ROOT_USER > /etc/restic/minio-access; echo MINIO_ROOT_PASSWORD > /etc/restic/minio-secret; chmod 600 /etc/restic/minio-{access,secret}"'
# Then init:
ssh c4@192.168.0.190 'sudo bash -c ". /etc/restic/env && restic init"'
```

Document this in the module README (Task 22).

- [ ] **Step 4: Apply + verify**

```bash
cd platform && terraform fmt -recursive
TF_VAR_claude_worker_restic_password='<long-random-string-also-in-vaultwarden>' tofu apply
ssh c4@192.168.0.190 'systemctl is-active restic-backup.timer && sudo bash -c ". /etc/restic/env && restic snapshots"'
```

Expected: timer active, `restic snapshots` lists at least one snapshot (after first 04:00 run) or `Initialized` on first run.

- [ ] **Step 5: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl platform/main.tf
git commit -m "claude-worker: bootstrap section 11 — restic to MinIO

Daily backup at 04:00 to s3://claude-worker-backup on the NAS LXC.
Excludes /var/lib/docker (rebuildable), agent-job repo clones
(rebuildable), and user caches. Forget policy: 7 daily + 4 weekly +
6 monthly. Skipped entirely when no password is set; partial init when
MinIO creds aren't yet placed (documented in module README)."
```

---

## Phase 6 — Documentation + verification

### Task 20: Module README documenting operator setup steps

**Files:**
- Create: `platform/modules/proxmox_vm_claude_worker/README.md`

- [ ] **Step 1: Write the README**

Contents (full text — engineer should not need to consult other docs):

```markdown
# proxmox_vm_claude_worker

A Proxmox VM module that provisions a single Debian 12 box dedicated to
running Claude Code (the CLI) for interactive + headless workloads. Mirrors
`proxmox_vm_k3s_server` in structure.

## What this module does

1. Clones the Debian 12 cloud-init template (`debian-12-cloudinit-template`)
2. Attaches two ZFS-backed disks (root 16 G, data 48 G)
3. Sets static IP + SSH key via cloud-init
4. Returns the VM ID and IP

Everything else — Docker, Claude Code, ttyd, Caddy, cloudflared, k8s
service-account kubeconfigs, sanoid snapshot config on the host, restic
backup to MinIO, systemd timer template, two example agent jobs — is done
by `null_resource` resources in the root module after the VM is up.

## Inputs

See `variables.tf`. Sizing defaults: 4 vCPU / 8 GB / 16 G root + 48 G data.

## One-time operator setup (after first `tofu apply`)

### 1. Authenticate Claude Code (OAuth)

```bash
ssh c4@<vm-ip>
sudo -u claude-agent -i
claude login            # opens a URL; follow auth; paste callback URL back
exit
```

Both your interactive shells and cron jobs share this token.

### 2. Set up Cloudflare Tunnel + Access (one-time, dashboard-side)

1. CF Zero Trust dashboard → **Networks → Tunnels → Create tunnel**.
   Name: `claude-worker`. Save.
2. **Public hostname** tab: add two routes
   - `worker-ssh.chifor.dev` → service type `SSH`, URL `localhost:22`
   - `claude.chifor.dev`     → service type `HTTP`, URL `localhost:7681`
3. Copy the connector token. Set it in your shell:
   ```bash
   export TF_VAR_claude_worker_cf_tunnel_token='<token-from-dashboard>'
   ```
4. Re-apply: `tofu apply` — cloudflared installs and connects.
5. CF Zero Trust dashboard → **Access → Applications → Add an application** →
   pick **Self-hosted**. Create two apps:
   - SSH app: domain `worker-ssh.chifor.dev`, policy: `Include → Emails → chifor@gmail.com`
   - HTTP app: domain `claude.chifor.dev`, same policy

### 3. Configure restic to MinIO

```bash
# MinIO creds — get them from tofu output -raw nas_minio_root_password
# (or the NAS LXC's terraform output)
ssh c4@<vm-ip> 'sudo bash -c "
  echo <MINIO_ROOT_USER> > /etc/restic/minio-access
  echo <MINIO_ROOT_PASSWORD> > /etc/restic/minio-secret
  chmod 600 /etc/restic/minio-{access,secret}
  . /etc/restic/env && restic init
"'
```

**Also save `TF_VAR_claude_worker_restic_password` to Vaultwarden.** Losing both
the VM and that password makes the off-host backup unrecoverable.

### 4. Add CF Access SSH config on each device you'll SSH from

Mac/Linux:
```
brew install cloudflared
cat >> ~/.ssh/config <<EOF
Host worker
  HostName worker-ssh.chifor.dev
  ProxyCommand cloudflared access ssh --hostname=%h
  User c4
EOF
ssh worker
```

iOS: use Termius or Blink Shell; both natively support CF Access.

## Operations

- **Enable a cron job:** edit `/workspace/agent-jobs/<name>/{prompt.md,allowed-tools.txt,job.env}`,
  then `sudo systemctl enable --now claude-job@<name>.timer`.
- **Trigger a job ad-hoc:** `ssh worker 'claude-run <name>'` (see `/usr/local/bin/claude-run`).
- **Escalate to write-level k8s for a shell:** `claude-grant-write` (prompts sudo).
- **Restore a workspace file from a snapshot:** on the Proxmox host:
  `zfs list -t snapshot | grep vm-<VMID>-disk-1` to pick a snapshot, then
  `zfs clone local-zfs/vm-<VMID>-disk-1@<snap> local-zfs/restore-temp`,
  mount the clone read-only on the VM (`mount /dev/zd<X> /mnt`), copy the
  files out, then `zfs destroy local-zfs/restore-temp`.
- **Disaster recovery from restic:** spin up a new VM, install restic, point
  it at the MinIO repo + password, `restic restore latest --target /`.

## Outputs

| Output | Value |
|---|---|
| `vmid` | Proxmox VM ID |
| `vm_ip` | Static IP (matches `claude_worker_ip`) |
| `ssh_user` | `c4` |
```

- [ ] **Step 2: Commit**

```bash
git add platform/modules/proxmox_vm_claude_worker/README.md
git commit -m "claude-worker: module README with operator setup runbook

Documents: OAuth bootstrap, CF Tunnel + CF Access dashboard setup,
restic credential placement (and Vaultwarden reminder), per-device
SSH client config, job enable/disable commands, snapshot restore
procedure, restic disaster recovery."
```

---

### Task 21: claude-run dispatcher script

**Files:**
- Modify: `platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl` (append section 12)

- [ ] **Step 1: Append section 12** before the final echo

```bash
# -----------------------------------------------------------------------------
# Section 12: claude-run dispatcher (SSH-triggered ad-hoc job runs)
# -----------------------------------------------------------------------------
echo "==> [12/?] claude-run"

cat > /usr/local/bin/claude-run <<'EOF'
#!/bin/bash
# Trigger an agent job by name. Usage: claude-run <job-name> [extra prompt arg]
# Reads /workspace/agent-jobs/<job-name>/{prompt.md, allowed-tools.txt, job.env}.
# Output is captured to /workspace/agent-jobs/<job-name>/output/<timestamp>.jsonl
# and tailed back to the caller in real time.

set -euo pipefail
JOB="${1:-}"
[ -z "$JOB" ] && { echo "usage: claude-run <job-name> [extra-prompt]" >&2; exit 1; }
DIR="/workspace/agent-jobs/$JOB"
[ -d "$DIR" ] || { echo "claude-run: $DIR does not exist" >&2; exit 1; }

# Run the same systemd unit pattern as the timer so behaviour is identical
exec sudo systemctl start --wait "claude-job@${JOB}.service"
EOF
chmod 0755 /usr/local/bin/claude-run

# Sudoer rule allowing c4 + claude-agent to start claude-job@*.service WITHOUT
# password — but only those units, nothing else
cat > /etc/sudoers.d/claude-job-trigger <<EOF
${ssh_user} ALL=(root) NOPASSWD: /bin/systemctl start --wait claude-job@*.service
${ssh_user} ALL=(root) NOPASSWD: /bin/systemctl start claude-job@*.service
EOF
chmod 0440 /etc/sudoers.d/claude-job-trigger
```

- [ ] **Step 2: Apply + verify**

```bash
cd platform && tofu apply
ssh c4@192.168.0.190 'claude-run longhorn-health'
```

Expected: starts the systemd unit, runs the job, returns when complete; new entry in `/workspace/agent-jobs/longhorn-health/output/`.

- [ ] **Step 3: Commit**

```bash
git add platform/files/cloud-init/claude-worker-bootstrap.sh.tftpl
git commit -m "claude-worker: bootstrap section 12 — claude-run dispatcher

Thin wrapper around 'systemctl start --wait claude-job@<name>.service'
so an SSH-triggered run uses identical sandboxing, env, and output
capture as a cron run. Sudoers.d rule scopes the NOPASSWD to ONLY
claude-job@*.service units."
```

---

### Task 22: End-to-end verification against the spec

**Files:** (none — this is a verification checklist)

Run through the spec's "Verification" section. Each item:

- [ ] **V1: VM exists and is reachable** — `ping 192.168.0.190` + `ssh c4@192.168.0.190 'uname -a'` returns `Linux 6.x ... GNU/Linux`.

- [ ] **V2: Both users exist** — `ssh c4@192.168.0.190 'id c4; id claude-agent'`. c4 in docker, sudo. claude-agent in docker, NOT sudo.

- [ ] **V3: Docker works** — `ssh c4@192.168.0.190 'docker run --rm hello-world'`.

- [ ] **V4: Claude Code installed** — `ssh c4@192.168.0.190 'claude --version'`.

- [ ] **V5: OAuth flow** — after running the manual `claude login` per the README, `ssh c4@192.168.0.190 'claude -p "say hi"'` returns a one-line response.

- [ ] **V6: K8s RO works, RW blocked** — `ssh c4@192.168.0.190 'kubectl get nodes && kubectl auth can-i create ns -n default'`. nodes list OK; can-i returns `no`. Then `claude-grant-write` and verify `can-i create ns` returns `yes`.

- [ ] **V7: Restic backup runs** — after first 04:00 cron tick OR a manual `sudo systemctl start restic-backup.service`, `ssh c4@192.168.0.190 'sudo bash -c ". /etc/restic/env && restic snapshots"'` lists ≥ 1 snapshot.

- [ ] **V8: CF Access SSH works from off-LAN** — from a phone hotspot or other network, `ssh worker` opens CF Access auth in browser, completes, lands a shell.

- [ ] **V9: ttyd works from a phone browser** — visit `https://claude.chifor.dev`; CF Access auth → ttyd terminal as claude-agent in tmux session `main`.

- [ ] **V10: tmux survives disconnect** — open shell over SSH, `tmux new -s test && sleep 600`. Disconnect. Reconnect. The sleep is still running.

- [ ] **V11: Systemd timer fires** — `sudo systemctl list-timers claude-job@longhorn-health.timer`. Wait for next firing. `sudo journalctl -u "claude-job@longhorn-health.service" -n 50`. `/workspace/agent-jobs/longhorn-health/output/` has a new `.jsonl`.

- [ ] **V12: Idempotency** — `cd platform && tofu plan` reports `No changes`.

- [ ] **Final commit (verification log)**:

If any verification check needs a follow-up code fix, commit that fix with a referenced V# (e.g., "claude-worker: fix CLAUDE_HOME export in cron env (V11)"). When all 12 pass, no commit needed — just close out the implementation.

---

## Self-review of this plan

Done before handing off:

**1. Spec coverage:**
- Architecture (spec §Architecture) → Tasks 1, 4
- VM resource shape (§VM resource shape) → Task 1, 2
- Terraform module structure (§Terraform module) → Task 1, 2, 3, 4
- Users (§Users) → Task 6 (claude-agent creation)
- Software stack — base (§Software stack Layer 1) → Task 6
- Software stack — Docker (Layer 2) → Task 7
- Software stack — Node + Claude Code (Layer 3 + OAuth bootstrap) → Task 8
- Software stack — Python/Go/Rust (Layer 4 / 5) → Task 9
- Software stack — k8s tooling (Layer 5) → Task 10
- Software stack — ttyd + Caddy (Layer 6) → Task 11
- Software stack — cloudflared (Layer 6) → Task 12
- Tmux (mentioned across) → Task 6
- ufw inbound firewall (§Inbound firewall) → Task 13
- claude-grant-write (§Kubeconfig story) → Task 14
- K8s ServiceAccounts + RBAC (§Kubeconfig story) → Task 15
- Kubeconfig delivery (§Kubeconfig story) → Task 16
- Headless framework phase 1 — systemd timers (§Headless extensibility Phase 1) → Task 17
- Snapshots (§Persistence → Snapshots) → Task 18
- Off-host backup (§Persistence → Off-host backup) → Task 19
- README + operator runbook (referenced throughout spec) → Task 20
- Headless framework phase 2 — claude-run (§Headless extensibility Phase 2) → Task 21
- Verification checklist (§Verification) → Task 22

Phase 3 webhook receiver is documented in the spec as deferred, so no task. Correct.

**2. Placeholder scan:**
- All Task code blocks contain the actual content needed.
- No "implement appropriate error handling" or "fill in details" markers.
- Every verification command has expected output.

**3. Type consistency:**
- `claude_worker_*` variable prefix is consistent across Tasks 2, 4, 5, 12, 16, 19.
- `claude-agent` (lowercase, hyphen) as the user name is consistent.
- `claude-agent-ro` / `claude-agent-rw` SA names match in Tasks 15, 16.
- `/workspace/agent-jobs/<name>/{prompt.md, allowed-tools.txt, job.env, output/}` directory layout consistent in Task 17 and Task 21.

**4. Scope:**
- Single deliverable: one VM, one module, one set of supporting resources. Within scope for one plan.
- Out-of-scope (correctly): the Phase 3 webhook receiver, Anthropic Managed Agents, multi-tenant isolation.
