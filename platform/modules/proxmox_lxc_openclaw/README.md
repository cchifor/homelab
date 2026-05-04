# proxmox_lxc_openclaw

Privileged Debian-12 LXC running [OpenClaw](https://openclaw.ai/) — autonomous AI assistant that uses Docker as its sandbox backend and Playwright for web automation. Mirrors the Plex LXC pattern + adds Docker-in-LXC nesting.

| | |
|---|---|
| Container ID | next free (assigned by Proxmox) |
| OS | Debian 12 standard LXC template |
| Hostname | `openclaw` |
| IP | `192.168.0.189` (static) |
| Resources | 4 cores, 6 GiB RAM, 40 GiB rootfs |
| Storage bind | `/nvme-pool/openclaw` (host) → `/srv/openclaw` (container) |
| LXC features | Privileged + `nesting=1` + `keyctl=1` (required for Docker-in-LXC) |
| Daemon port | 18789 (LAN-only; OpenClaw connects OUT to chat APIs + AI providers) |

## Enable

```hcl
# In terraform.tfvars (gitignored) or via env var:
openclaw_enabled = true
```

Then `tofu apply`. ~10 min end-to-end (LXC create → Docker install → Node 24 install → Playwright Chromium download ~150 MB → OpenClaw npm install).

## What gets installed

| Component | Where |
|---|---|
| Docker CE + Compose plugin | system, via `apt` from the official Docker repo |
| Node.js 24 | system, via NodeSource apt repo |
| OpenClaw (npm package `openclaw@latest`) | `/srv/openclaw/npm-global` (persistent bind mount; survives LXC rebuild) |
| Playwright + Chromium browser | `/srv/openclaw/playwright` (persistent) |
| Playwright system libs (~80 packages) | system, via `apt` |

## First-run setup (manual — needs your API keys)

OpenClaw is installed but the daemon is NOT auto-started. It needs API credentials to function:

```bash
ssh root@192.168.0.189
openclaw onboard --install-daemon
```

The `onboard` command interactively asks for:
- **Model provider key** — Claude (`ANTHROPIC_API_KEY`) or OpenAI (`OPENAI_API_KEY`)
- **Messaging integration tokens** — Telegram bot token, Slack/Discord credentials, etc. (whichever channels you want)
- **Optional**: ElevenLabs API key for voice (TTS fallback to system if absent)

After onboarding, the daemon starts at `http://192.168.0.189:18789`.

```bash
systemctl status openclaw          # check service health
journalctl -u openclaw -f         # tail logs
openclaw agent --message "hi"     # send a one-off message
```

## How OpenClaw uses Docker

The agent spawns Docker containers as **sandboxes** for executing shell commands and code suggested by the LLM (instead of running them directly on the LXC). This is a security feature — even if the LLM goes off-rails, blast radius is bounded by the sandbox container.

This is why we need `nesting=1` + `keyctl=1` on the LXC: Docker daemon needs both to operate inside the container. Without these, `docker run` fails with cgroup errors.

## Resources used (steady state)

| | Idle | Active (browsing + sandbox running) |
|---|---|---|
| RAM | ~700 MB | 3–4 GiB (Chromium + sandbox container + agent state) |
| CPU | <1% | bursty 50–100% during automation |
| Disk | ~3 GiB after install | grows with Docker images + agent skills |

## Security posture

OpenClaw is an **autonomous agent** that can read/write files (within `/srv/openclaw`), execute shell commands (sandboxed in Docker containers it spawns), and access 50+ external integrations. Worth knowing:

1. **API key budget** — a runaway agent can chew through Claude/OpenAI credits. Set a billing alert at the provider.
2. **LXC isolation** — keeps OpenClaw away from the rest of your homelab (Proxmox LXC ≠ host root). The bind mount is the only host-visible path.
3. **Network egress** — outbound only by default. LAN port 18789 is the daemon's local API; no public exposure unless you opt in (e.g., via Cloudflare Tunnel for webhook-based integrations).
4. **API keys in env** — `openclaw onboard` stores them in `/srv/openclaw/state/.env` (persistent bind mount, root-only). Do NOT commit this file to git.

## Operations

```bash
# Stop / start the LXC
ssh root@192.168.0.185 pct stop  103   # CTID may differ
ssh root@192.168.0.185 pct start 103

# Tail OpenClaw logs
ssh root@192.168.0.189 journalctl -u openclaw -f

# Check Docker is working inside
ssh root@192.168.0.189 'docker run --rm hello-world'

# Upgrade OpenClaw to a new npm version: bump var.openclaw_pkg_spec
#   (e.g. openclaw@1.5.0) and re-apply.
#   The bootstrap script's idempotent — only re-installs if spec changed.
```

## Tear down

```bash
# In terraform.tfvars: openclaw_enabled = false, then `tofu apply`
# OR
tofu destroy -target=module.openclaw_lxc

# Bind-mount data on /nvme-pool/openclaw survives LXC destruction.
# Re-deploy later and the same skills + memory are intact.
```
