# Claude Code Worker — Design Spec

**Date:** 2026-05-11
**Status:** approved, ready for implementation plan

## Goals

Provision a single-host Proxmox VM dedicated to running Claude Code (the CLI). Both interactive (operator SSHes in to drive sessions) and headless (cron / SSH-triggered / future webhook) workloads share the same machine, the same OAuth credential, and the same workspace.

Specifically:

- **Interactive**: SSH from LAN, SSH from anywhere via Cloudflare Access, and a web terminal (ttyd) at `claude.chifor.dev` for browser/mobile access. Long-running tmux session is the default shell so disconnects don't kill work.
- **Headless**: systemd timers under a non-sudo `claude-agent` user trigger `claude -p` runs on a schedule. SSH-triggered runs (phase 2) and HTTP webhooks (phase 3) layer on top without rebuilding.
- **Validate-by-running**: Docker Engine + Compose v2 on the VM so the agent can run `docker compose up` for e2e tests as part of a task.

## Non-goals

- Not a build farm or shared multi-tenant dev environment. Two OS users (you + the agent), nothing else.
- Not a replacement for your laptop. This is a remote workstation that's always on.
- Not a managed-agent platform. We're running Claude Code, not Anthropic's Managed Agents API.
- Not a "lock everything down" appliance. Outbound is unrestricted; inbound is restricted; that's the boundary.

## Architecture

```
        ┌─────────────────────────────────────────────────────────────┐
        │  Proxmox host (192.168.0.185, 32 GB DDR5, local-zfs)        │
        │                                                             │
        │   ┌───────────────────────────────────────────────────┐     │
        │   │ claude-worker (Debian 12, 4 vCPU / 8 GB)          │     │
        │   │  • Docker Engine + Compose v2                     │     │
        │   │  • claude-code CLI (OAuth, shared by both users)  │     │
        │   │  • dev tooling: git, gh, kubectl, helm, node,     │     │
        │   │    python, go, rust, k9s, tmux                    │     │
        │   │  • ttyd (web terminal) + sshd                     │     │
        │   │  • cloudflared (own tunnel, NOT k3s's)            │     │
        │   │  • systemd timers for headless jobs               │     │
        │   │                                                   │     │
        │   │  rootfs: 16 GB  ZFS                               │     │
        │   │  /workspace: 48 GB ZFS dataset (snapshotted)      │     │
        │   └───────────────────────────────────────────────────┘     │
        └─────────────────────────────────────────────────────────────┘
                  ▲                      ▲                    ▲
                  │ SSH (LAN)            │ CF Access SSH      │ HTTPS
                  │ 22/tcp               │ via cloudflared    │ (ttyd)
                  │                      │                    │
        ┌─────────┴──────┐    ┌──────────┴───────────┐  ┌─────┴───────────────────┐
        │ Laptop on LAN  │    │ Any device w/        │  │ Any browser, anywhere   │
        │                │    │ cloudflared client   │  │ claude.chifor.dev       │
        │                │    │ worker-ssh.chifor.dev│  │ + CF Access policy      │
        └────────────────┘    └──────────────────────┘  └──────────────────────────┘

Outbound from VM (no domain allowlist):
   → HTTPS (443) anywhere — Anthropic API, WebFetch, WebSearch, GitHub, package mirrors, docs
   → HTTP  (80)  anywhere — apt repos, plain-HTTP docs
   → DNS    (53) → lan_dns → 1.1.1.1/8.8.8.8
   → gitea.chifor.dev (LAN)
   → k3s API @ 192.168.0.187:6443 (RBAC: view-only by default; edit-level via opt-in)
```

The worker is a **single Proxmox VM**, not a k3s pod. It runs its **own** cloudflared, so it's independent of the cluster. Two service accounts in the k3s cluster (`claude-agent-ro` and `claude-agent-rw`) let the agent inspect (always) and modify (opt-in per shell).

## VM resource shape

| Field | Value |
|---|---|
| Hostname | `claude-worker` (DNS: `claude-worker.lan`) |
| LAN IP | `192.168.0.190` (static, next free after OpenClaw .189) |
| OS | Debian 12 cloud-image, reuses existing template at VMID 9000 |
| vCPU | 4 (`cpu=host`) |
| RAM | 8 GB, balloon disabled |
| Disk 1 (root) | 16 GB on `local-zfs` (OS, apt cache, Docker images) |
| Disk 2 (data) | 48 GB on `local-zfs`, mounted `/workspace` (own dataset for separate snapshots) |
| BIOS | seabios, cloud-init drive on `ide2` |
| Network | `vmbr0`, MTU inherits from host bond (whatever it's currently set to) |
| Guest agent | enabled |

## Terraform module

New module `platform/modules/proxmox_vm_claude_worker/`, mirroring `proxmox_vm_k3s_server/`. Wired into the root from `main.tf` with a `claude_worker_enabled` gate (same pattern as `plex_enabled`).

Variables surfaced in `terraform.tfvars`:

```hcl
claude_worker_enabled    = true
claude_worker_ip         = "192.168.0.190"
claude_worker_cores      = 4
claude_worker_memory_mb  = 8192
claude_worker_root_disk  = "16G"
claude_worker_data_disk  = "48G"
claude_worker_ssh_pubkey = "~/.ssh/id_ed25519.pub"

# Cloudflare tunnel credentials (created out-of-band in the CF dashboard,
# token pasted as TF_VAR_claude_worker_cf_tunnel_token env var)
# Two routes attached to that tunnel by the bootstrap script:
#   worker-ssh.chifor.dev → ssh://localhost:22  (CF Access policy: email == chifor@gmail.com)
#   claude.chifor.dev     → http://localhost:7681 (CF Access policy: same)
```

The CF tunnel itself is created in the dashboard once (it returns a tunnel token); only the token reaches Terraform via env var. The two DNS routes and the Access policy are also dashboard-side configuration documented in the module README.

## Users

| User | Sudo | SSH key | Purpose |
|---|---|---|---|
| `c4` | yes | `${claude_worker_ssh_pubkey}` | primary, interactive |
| `claude-agent` | **no** | inherited from `c4` via `/etc/skel/.ssh/` | owns `~/.claude/`, runs cron jobs |

Both are in the `docker` group. `c4` reads `claude-agent`'s OAuth via `CLAUDE_HOME` env var set in `/etc/profile`, so interactive `claude` invoked from a `c4` shell uses the same credential as the agent's cron jobs (single token, single revocation surface).

## Software stack

Cloud-init installs everything on first boot, idempotently:

| Layer | Packages |
|---|---|
| Base + shell QoL | build-essential, curl, wget, git, gh, jq, yq, ripgrep, fzf, bat, tmux, htop, ncdu, unzip, ca-certificates, gnupg |
| Container runtime | docker-ce, docker-ce-cli, containerd.io, docker-buildx-plugin, docker-compose-plugin (Docker upstream apt repo) |
| Language toolchains | Node.js 20 LTS (NodeSource), Python 3.11 + pipx, Go 1.22 (apt-pin), Rust via rustup → `/opt/rust`, shared |
| K8s tooling | kubectl (matched to k3s 1.30), helm 3.x, k9s |
| Claude Code | `npm install -g @anthropic-ai/claude-code` per user (no `sudo npm`) |
| Web terminal & tunnel | ttyd (upstream binary, not Debian's), cloudflared (Cloudflare apt repo) |

**Tmux as default shell:** `/etc/profile.d/00-tmux-attach.sh` auto-attaches incoming SSH and ttyd sessions to a shared named session (`main`). `Ctrl-b d` to detach explicitly. `~/.tmux.conf` ships with mouse on, history 50k, `Ctrl-b |` / `-` for splits.

**OAuth bootstrap** is the only manual step. After `tofu apply`:

```bash
ssh c4@192.168.0.190
sudo -u claude-agent -i
claude login
# follow the URL, complete OAuth, paste the callback URL back
# ~claude-agent/.claude/.credentials.json now exists; cron jobs and your
# interactive sessions both use it
```

## Network / access detail

### LAN ingress (always available, no internet required)
- `ssh c4@192.168.0.190` — port 22 open on `vmbr0`
- `https://claude-worker.lan` → ttyd at `127.0.0.1:7681`, terminated by Caddy on the VM
  - Caddy's `tls internal` mode: self-signed via Caddy's local CA. Browser trust-on-first-use; no dependency on the k3s cluster's cert-manager (the worker stays standalone). Public access (where browser-trusted certs matter) goes through `claude.chifor.dev` instead.

### Public ingress (Cloudflare Tunnel)
- `worker-ssh.chifor.dev` → `ssh://localhost:22`
- `claude.chifor.dev`     → `http://localhost:7681`

Both routes gated by **Cloudflare Access** (CF Zero Trust). Policy: `email == chifor@gmail.com`. CF Access can use Authentik as the upstream IdP (OIDC) or Google directly; the choice doesn't affect the VM. CF Access is used instead of Authentik forward-auth because (a) it works for raw SSH where forward-auth doesn't, and (b) it keeps the worker independent of the k3s cluster.

### Inbound firewall (ufw, configured by cloud-init)
- `192.168.0.0/24`: SSH (22), Caddy HTTPS (443)
- everywhere else: dropped
- cloudflared connects *outbound* to CF edge, so no public port is open on the VM

### ttyd hardening
- Listens on `127.0.0.1:7681` only
- LAN access via Caddy on `:443`, mTLS or HTTP-basic as second auth layer
- Drops to `claude-agent` on connect (so a compromised browser session can't trivially `sudo`)
- Idle timeout 30 min; tmux session persists

### Client setup (per device, one-time)
```
# Mac/Linux
brew install cloudflared
cat >> ~/.ssh/config <<EOF
Host worker
  HostName worker-ssh.chifor.dev
  ProxyCommand cloudflared access ssh --hostname=%h
  User c4
EOF
ssh worker  # opens CF Access auth in browser on first use
```

iOS clients (Termius, Blink Shell) support the cloudflared "Browser SSH" flow natively.

## Persistence

### Disk layout
```
/                  16 GB  ZFS rootfs    — OS, apt cache, /var/lib/docker (ephemeral)
/workspace         48 GB  ZFS dataset   — owned by claude-agent:c4 mode 2775
  ├── c4/                                 your projects
  ├── agent-jobs/                         cron-job working dirs
  └── shared/                             cross-user staging
/etc/cloudflared   bind-mounted, survives root rollback
~/.claude/         in claude-agent home, survives root rollback
```

### Snapshots (ZFS, Proxmox host-side via `sanoid`)
| Dataset | Schedule | Retention |
|---|---|---|
| root | before each `tofu apply` | last 3 |
| `/workspace` | nightly 03:00 | 7 daily + 4 weekly |

### Off-host backup
- **restic** on the VM (daily cron) → MinIO bucket `claude-worker-backup` on the NAS LXC (`192.168.0.186:9000`)
- Includes: `/workspace`, `/home`, `/etc/cloudflared`, `~claude-agent/.claude/`
- Encryption key in `/etc/restic/repo.key` (chmod 600). Operator stores a copy in Vaultwarden — losing both the VM and Vaultwarden makes the backup unrecoverable; that's the documented trade-off.
- Retention: 7 daily + 4 weekly + 6 monthly

## Kubeconfig story

Two ServiceAccounts in the k3s cluster, both created by Terraform (`kubectl_manifest` resources in the module):

| SA | RBAC | Path on VM | Default? |
|---|---|---|---|
| `claude-agent-ro` | `view` ClusterRoleBinding | `/etc/skel/.kube/config` → `~/.kube/config` for both users | yes |
| `claude-agent-rw` | `edit` ClusterRoleBinding | `/etc/claude-agent/kube-rw-config` (root-readable only) | no |

A helper `claude-grant-write` (`/usr/local/bin/claude-grant-write`):

```bash
# normal session
kubectl get pods -A      # ok
kubectl delete pod foo   # forbidden

# opt-in escalation, this shell only
claude-grant-write       # sudo prompt; exports KUBECONFIG for current shell
kubectl delete pod foo   # ok
```

The RW config never lands in any shell's default env. Even an agent prompt that successfully `bash -c`s a destructive command can't reach edit-level RBAC without the operator's sudo password.

## Headless extensibility

### Phase 1 — ships in the module (systemd timers)

```
/etc/systemd/system/claude-job@.service           parameterised template
/etc/systemd/system/claude-job@<name>.timer       one per job (disabled by default)

/workspace/agent-jobs/<name>/
  ├── prompt.md           # the task description Claude reads
  ├── allowed-tools.txt   # tools whitelisted for this job
  ├── output/             # transcripts + artifacts (auto-rotated)
  └── job.env             # env vars (working dir, repo, optional MCPs)
```

The template runs `claude -p "$(cat prompt.md)" --output-format json` as `claude-agent`, with stdout captured to `output/$(date).jsonl` and logs streamed to journald.

Two example jobs ship commented out:
- `nightly-repo-audit` — diffs since last run, posts findings to Gitea issue
- `longhorn-health` — every 6h, queries cluster, writes Markdown summary

### Phase 2 — already possible, no new infra
```bash
ssh worker claude-run pr-review --pr https://github.com/foo/bar/pull/42
```
`claude-run` (`/usr/local/bin/claude-run`, ~30 lines) reads `/workspace/agent-jobs/<name>/`, sources `job.env`, invokes `claude -p` with the configured allowed tools. No daemon, no public listener.

### Phase 3 — only if we find concrete use cases
A `caddy` reverse proxy + a single-file Python (`flask`/`aiohttp`) receiver at `claude-hooks.chifor.dev` (third CF Tunnel route). Validates HMAC, picks job, runs `systemctl start claude-job@<name>.service`. Out of scope for the initial module; the systemd template is structured so the receiver is purely additive.

## Risks

| # | Risk | Mitigation |
|---|---|---|
| 1 | Runaway agent prompt mutates the cluster | Default RBAC is `view`. RW kubeconfig is opt-in per shell via sudo-gated helper. |
| 2 | OAuth credential leaked from `~claude-agent/.claude/` | File is mode 0600, owned by `claude-agent`. `c4` accesses via `CLAUDE_HOME` env var, not by reading the file. If leaked, `claude logout && claude login` rotates. |
| 3 | restic key + VM both lost | Operator stores key in Vaultwarden (out-of-band). Documented in module README. |
| 4 | Docker iptables rules conflict with ufw | Docker writes to `DOCKER-USER` chain; ufw doesn't manage that chain. Tested pattern in Debian 12. |
| 5 | cloudflared tunnel goes down → no public access | LAN access (SSH + Caddy/ttyd) is unaffected; operator can SSH locally to fix. |
| 6 | npm/Docker fill the rootfs (16 GB) | `/var/lib/docker` on rootfs by design (Docker images are rebuilt, not preserved). `ncdu` available; monthly cron does `docker system prune -af` (logged, not auto-deleted from `/workspace`). |
| 7 | Cloudflare Access free tier (50 users) outgrown | Documented as a "future cost ceiling". Not relevant for single-operator use. |
| 8 | Snapshot churn on `/workspace` during big builds | ZFS snapshots are COW + cheap; tested in the NAS LXC. Retention caps prevent unbounded growth. |

## Verification (post-implementation)

1. **VM exists and is reachable** — `ping 192.168.0.190` + `ssh c4@192.168.0.190 'uname -a'` returns `Linux 6.x ... GNU/Linux`.
2. **Both users exist** — `id c4` shows `docker` group; `id claude-agent` shows `docker` group, no `sudo`.
3. **Docker works** — as `c4`: `docker run --rm hello-world` succeeds.
4. **Claude Code installed** — `claude --version` returns ≥ the version shipped at module-write time.
5. **OAuth flow completes** — after manual `claude login`, `claude -p "say hi"` returns a response without prompting again.
6. **K8s RO works, RW blocked** — `kubectl get nodes` works; `kubectl create ns test` returns `Forbidden`. After `claude-grant-write`, the create succeeds; in a fresh shell, blocked again.
7. **Restic backup runs** — first cron tick completes, `restic snapshots` lists one snapshot in MinIO.
8. **CF Access SSH works from off-LAN** — `ssh worker` from a tethered phone hotspot opens CF Access auth in browser, completes, lands a shell.
9. **ttyd works from a phone browser** — `https://claude.chifor.dev` shows CF Access screen, then the ttyd page, then a tmux shell as `claude-agent`.
10. **tmux session survives disconnect** — open shell, `tmux new -s test`, run `sleep 600`, close laptop lid, reopen, reconnect, session still has the running sleep.
11. **Systemd timer fires** — enable the `longhorn-health` example timer, wait for its first run, verify `journalctl -u claude-job@longhorn-health` shows the run and `/workspace/agent-jobs/longhorn-health/output/` has a transcript.
12. **`tofu plan` after a successful apply** — must report `No changes.` If it doesn't, fix the non-idempotent provisioner.

## Open questions for the operator

None — design decisions ratified during the brainstorm session 2026-05-11:

- Substrate: Proxmox VM (not LXC, not k3s pod)
- Arch: amd64
- Shape: 4 vCPU / 8 GB / 64 GB
- Auth: OAuth for both interactive and headless
- Users: `c4` (sudoer) and `claude-agent` (cron)
- Headless trigger: cron now, SSH-trigger free, webhook later
- Public auth: CF Access (free tier), not Authentik forward-auth
