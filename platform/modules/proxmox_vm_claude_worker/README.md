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
