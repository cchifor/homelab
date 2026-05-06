# proxmox_lxc_plex

Privileged Debian-12 LXC running Plex Media Server with Intel iGPU `/dev/dri` bind-mounted for QuickSync hardware transcoding. Mirrors the `proxmox_lxc_minio` pattern + adds GPU device passthrough.

| | |
|---|---|
| Container ID | 102 (next free; assigned by Proxmox) |
| OS | Debian 12 standard LXC template |
| Hostname | `plex` |
| IP | `192.168.0.188` (static) |
| Resources | 4 cores, 4 GiB RAM, 16 GiB rootfs |
| Storage bind | `/nvme-pool/plex` (host) → `/srv/plex` (container) |
| GPU bind | `/dev/dri/card1` + `/dev/dri/renderD128` (Alder Lake-N) via `lxc.mount.entry` + `lxc.cgroup2.devices.allow` |
| Library data | `/var/lib/plexmediaserver` symlinked to `/srv/plex/library` (survives LXC rebuild) |

## Enable

In `terraform.tfvars` (gitignored) or via env var:

```hcl
plex_enabled = true
```

Then `tofu apply`. ~100s end-to-end (LXC creation + bind config + Plex DEB install + service start).

Defaults assume Alder Lake-N iGPU exposing `card1` + `renderD128`. Verify on your host with `ls /dev/dri/`. Older Intel iGPUs typically use `card0`. Override via `plex_igpu_card_name` / `plex_igpu_card_minor` if needed.

## First-launch claim (one-time, manual)

Plex Media Server requires a claim token to bind to your plex.tv account. The token is generated when you're signed in to plex.tv and has a 4-minute TTL.

**Easy path (browser-based):**

1. From a device on your home network (so `192.168.0.188` is reachable), open https://www.plex.tv/claim/ in one tab and copy the displayed token (e.g. `claim-XXXXXX`).
2. Within 4 minutes, browse to **http://192.168.0.188:32400/web** — Plex's setup wizard will detect a sign-in is needed; sign in with your plex.tv account; enter the claim token if prompted.

Plex will then:
- Bind this server to your account
- Walk you through naming the server, adding library folders, etc.

**Library folders to add in the wizard:**
- Movies → `/srv/plex/media/movies`
- TV → `/srv/plex/media/tv`
- Music → `/srv/plex/media/music`

(Pre-create with `pct exec 102 -- mkdir -p /srv/plex/media/{movies,tv,music}` first; or just create them as you go in the UI.)

## Adding media

The `/srv/plex/media` directory inside the container is the same as `/nvme-pool/plex/media` on the host. Three ways to put files there:

```bash
# 1. SCP from your operator machine to the host, then pct push or just access via shared bind:
scp -r ./Movies root@192.168.0.185:/nvme-pool/plex/media/movies/

# 2. SMB / NFS share off the host (set up separately if you want LAN clients to upload directly)

# 3. From inside the container (rsync from somewhere already accessible)
ssh root@192.168.0.185 'pct exec 102 -- rsync -av rsync.sshfs.example/movies/ /srv/plex/media/movies/'
```

After files land, "Scan Library Files" in the Plex UI picks them up.

## Mounting an external SMB / NAS share (e.g., a QNAP `Public/Movies`)

The module's `smb_mounts` variable (list of `{server, share, mount_point, smb_vers, creds_file, read_only}` objects) declares CIFS mounts that the bootstrap installs `cifs-utils` for, lays an `/etc/fstab` line down, and creates a placeholder credentials file at the configured path.

Credentials are deliberately NOT in IaC. After `tofu apply`, populate them once:

```bash
ssh root@<proxmox-host>
pct enter 102

# Replace YOUR_USER / YOUR_PASS with your real values, then paste:
read -p "user: " QU
read -s -p "pass: " QP; echo
printf 'username=%s\npassword=%s\ndomain=WORKGROUP\n' "$QU" "$QP" > /root/.smb-vbox.creds
chmod 600 /root/.smb-vbox.creds

mount /mnt/vbox-movies   # uses fstab, succeeds once creds are valid
ls /mnt/vbox-movies | head
exit; exit
```

After mounting, **add the library in Plex**: web UI → ⚙ Settings → Manage → Libraries → Add Library → Movies → browse to `/mnt/vbox-movies` → Save.

### Why `vers=2.1` on the example QNAP mount

Some QNAP firmwares advertise SMB3 in their share-list response but reject Linux kernel cifs's SMB3 dialect at mount time with `Operation not supported (95)` (kernel logs `Dialect not supported by server`). They negotiate cleanly with Windows because Windows auto-falls-back; Linux cifs needs the explicit pin. `vers=2.1` is a safe default; bump per-mount if your server speaks 3.0+.

### Survival across `tofu destroy`

`fstab` entry + mount point + cifs-utils install: re-laid by the bootstrap on every apply (idempotent).
Credentials file: `tofu destroy` wipes the LXC rootfs; the creds file goes with it. Re-run the `printf` block above after re-applying.

## Verifying QuickSync transcoding

Plex Pass (paid Plex feature, $5/mo or $120 lifetime) is required for **hardware-accelerated transcoding**. Without Plex Pass, the iGPU bind is harmless but unused — Plex falls back to CPU.

If you have Plex Pass:
1. Settings → Transcoder → "Use hardware acceleration when available" ✓
2. Play a video that requires transcoding (e.g. open in browser at low quality on a high-bitrate file)
3. While it's playing: `pct exec 102 -- intel_gpu_top` (install via `apt-get install intel-gpu-tools` in the LXC) — should show busy "Render/3D" engine
4. OR check the live transcode session in the Plex web UI: Settings → Status → Now Playing → click the playback bar → look for "(hw)" tag on the video stream

If you don't see hardware transcoding: `journalctl -u plexmediaserver -f | grep -iE 'qsv|vaapi|hardware'` for diagnostics.

## Remote access from outside your LAN

Two options:

| Option | How |
|---|---|
| **Plex Relay** (default; free) | Plex.tv tunnels through their relay for users away from home. Bandwidth-limited to ~2 Mbps per stream — fine for music or audio, painful for 1080p+ video. Plex enables this automatically. |
| **Direct port-forward via UniFi** | Forward TCP 32400 from your public IP to 192.168.0.188:32400. In Plex Settings → Remote Access, click "Show advanced" → set "Manually specify public port: 32400". Plex now serves direct connections, full bandwidth. |

**Don't use Cloudflare Tunnel** for Plex — Cloudflare's TOS §2.8 prohibits substantial non-HTML video streaming through their network, and Plex specifically may be throttled or have the tunnel disabled.

## Operations

```bash
# Stop / start the LXC
ssh root@192.168.0.185 pct stop 102
ssh root@192.168.0.185 pct start 102

# Tail Plex logs
ssh root@192.168.0.185 pct exec 102 -- journalctl -u plexmediaserver -f

# Check transcoding load
ssh root@192.168.0.185 pct exec 102 -- top -p $(pgrep -f 'Plex Transcoder' | head -1)

# Upgrade Plex: bump var.plex_version in tfvars and re-apply
#   tofu apply -var plex_enabled=true
# The bootstrap script's idempotent — only re-installs if version changed.
```

## Tear down

```bash
# Set plex_enabled = false in tfvars and re-apply, OR:
tofu destroy -target=module.plex_lxc

# Library data on /nvme-pool/plex survives LXC destruction (host bind).
# Re-deploy later and the same library reappears.
```
